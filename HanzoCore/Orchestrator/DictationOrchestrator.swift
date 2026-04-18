import Foundation
import AppKit
import SwiftUI

@Observable
final class DictationOrchestrator {
    private let appState: AppState
    private let settings: AppSettingsProtocol
    private var audioService: AudioCaptureProtocol
    private let textInsertion: TextInsertionProtocol
    private let recentDictationStore: RecentDictationStoreProtocol
    private let permissionService: PermissionServiceProtocol
    private let runtimeCoordinator: RuntimeCoordinator
    private let logger: LoggingServiceProtocol
    private let frontmostApplicationProvider: () -> NSRunningApplication?
    private let workspaceFrontmostApplicationProvider: () -> NSRunningApplication?

    private var asrClient: ASRClientProtocol
    private let isASRClientInjected: Bool
    private var sessionId: String?
    private let audioStreamer: AudioChunkStreamer
    private var previousApp: NSRunningApplication?
    private var activeSessionTargetBundleIdentifier: String?
    private var recordingStartTime: Date?
    private var pendingRestartAfterForging = false
    private var configuredASRProvider: ASRProvider
    private var configuredLocalLLMContextSize: Int
    private var transcriptPostProcessingMode: TranscriptPostProcessingMode
    private var llmPostProcessingPrompt: String
    private var commonTerms: [String]

    // Auto-submit
    var autoSubmitMode: AutoSubmitMode

    // Silence auto-close — delegates state and timing to SilenceDetector.
    var silenceTimeout: Double {
        get { silenceDetector.silenceTimeout }
        set { silenceDetector.silenceTimeout = newValue }
    }
    private let silenceDetector: SilenceDetector
    private let hotkeyController: HotkeySessionController
    private let clock: ClockProtocol

    init(
        appState: AppState,
        asrClient: ASRClientProtocol? = nil,
        audioService: AudioCaptureProtocol = AudioCaptureService(),
        textInsertion: TextInsertionProtocol = TextInsertionService(),
        recentDictationStore: RecentDictationStoreProtocol = RecentDictationStore(),
        permissionService: PermissionServiceProtocol,
        localRuntimeManager: LocalASRRuntimeManagerProtocol = LocalASRRuntimeManager(),
        localLLMRuntimeManager: LocalLLMRuntimeManagerProtocol,
        logger: LoggingServiceProtocol,
        settings: AppSettingsProtocol,
        clock: ClockProtocol = SystemClock(),
        frontmostApplicationProvider: @escaping () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        },
        workspaceFrontmostApplicationProvider: @escaping () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        }
    ) {
        self.appState = appState
        self.settings = settings
        self.audioService = audioService
        self.textInsertion = textInsertion
        self.recentDictationStore = recentDictationStore
        self.permissionService = permissionService
        self.runtimeCoordinator = RuntimeCoordinator(
            localASRRuntimeManager: localRuntimeManager,
            localLLMRuntimeManager: localLLMRuntimeManager,
            logger: logger
        )
        self.logger = logger
        self.frontmostApplicationProvider = frontmostApplicationProvider
        self.workspaceFrontmostApplicationProvider = workspaceFrontmostApplicationProvider
        self.clock = clock
        self.hotkeyController = HotkeySessionController(logger: logger)
        self.audioStreamer = AudioChunkStreamer(logger: logger, clock: clock)
        self.silenceDetector = SilenceDetector(logger: logger, clock: clock)

        self.autoSubmitMode = AppBehaviorSettings.globalAutoSubmitMode(settings: settings)
        self.silenceDetector.silenceTimeout = AppBehaviorSettings.globalSilenceTimeout(settings: settings)
        let initialASRProvider = DictationOrchestrator.currentASRProvider(settings: settings)

        if let asrClient = asrClient {
            self.asrClient = asrClient
            self.isASRClientInjected = true
        } else {
            self.asrClient = DictationOrchestrator.makeConfiguredASRClient(settings: settings)
            self.isASRClientInjected = false
        }

        self.configuredASRProvider = initialASRProvider
        self.configuredLocalLLMContextSize = settings.localLLMContextSize
        self.transcriptPostProcessingMode = AppBehaviorSettings.globalPostProcessingMode(settings: settings)
        self.llmPostProcessingPrompt = AppBehaviorSettings.globalLLMPostProcessingPrompt(settings: settings)
        self.commonTerms = CommonTerms.parse(AppBehaviorSettings.globalCommonTerms(settings: settings))

        appState.autoSubmitMode = self.autoSubmitMode
        appState.silenceTimeout = self.silenceDetector.silenceTimeout
        appState.asrProvider = self.configuredASRProvider
        appState.recentDictations = recentDictationStore.load()

        self.audioService.onAudioChunk = { [weak self] data in
            self?.audioStreamer.enqueueChunk(data)
        }

        self.audioService.onAudioLevels = { [weak self] levels in
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.15)) {
                    self?.appState.audioLevels = levels
                }
                self?.silenceDetector.evaluate(levels: levels)
            }
        }

        self.hotkeyController.delegate = self
        self.audioStreamer.delegate = self
        self.silenceDetector.delegate = self

        let hasRequiredPermissions = permissionService.hasMicrophonePermission
            && permissionService.hasAccessibilityPermission
        if hasRequiredPermissions {
            runtimeCoordinator.prewarmLocalASRIfNeeded(provider: configuredASRProvider)
        }
    }

    func reloadSettings() {
        let previousProvider = configuredASRProvider
        let previousPostProcessingMode = transcriptPostProcessingMode
        let previousLocalLLMContextSize = configuredLocalLLMContextSize

        if let activeSessionTargetBundleIdentifier {
            applyEffectiveBehavior(for: activeSessionTargetBundleIdentifier)
        } else {
            applyEffectiveBehavior(for: nil)
        }

        configuredASRProvider = DictationOrchestrator.currentASRProvider(settings: settings)
        configuredLocalLLMContextSize = settings.localLLMContextSize
        appState.asrProvider = configuredASRProvider

        if !isASRClientInjected {
            asrClient = DictationOrchestrator.makeConfiguredASRClient(settings: settings)
        }

        let shouldRestartLocalRuntime = previousProvider == .local
            && configuredASRProvider != .local
        let shouldWarmLocalRuntime = configuredASRProvider == .local
            && previousProvider != .local
        let shouldStopLocalLLMRuntime = previousPostProcessingMode == .llm
            && transcriptPostProcessingMode != .llm
        let shouldRestartLocalLLMRuntimeForContextChange = previousPostProcessingMode == .llm
            && transcriptPostProcessingMode == .llm
            && previousLocalLLMContextSize != configuredLocalLLMContextSize

        if shouldRestartLocalRuntime || shouldWarmLocalRuntime
            || shouldStopLocalLLMRuntime
            || shouldRestartLocalLLMRuntimeForContextChange {
            Task {
                if shouldRestartLocalRuntime {
                    await runtimeCoordinator.stopLocalASRRuntime()
                }

                if shouldStopLocalLLMRuntime || shouldRestartLocalLLMRuntimeForContextChange {
                    runtimeCoordinator.coolLLMRuntime(reason: "settings change")
                }

                if shouldWarmLocalRuntime {
                    do {
                        try await runtimeCoordinator.prepareLocalASRModel()
                        logger.info("Local Whisper runtime warmed after settings change")
                    } catch {
                        logger.warn("Failed to warm local Whisper runtime after settings change: \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    func handleHotkeyDown() {
        hotkeyController.handleKeyDown()
    }

    @MainActor
    func handleHotkeyUp() {
        hotkeyController.handleKeyUp()
    }

    func toggle() {
        switch appState.dictationState {
        case .idle:
            _ = startRecordingIfAllowed()
        case .listening:
            hotkeyController.clear()
            stopRecording()
        case .forging:
            // Queue a restart so rapid double-taps don't get dropped.
            pendingRestartAfterForging = true
            logger.info("Toggle received during forging; queued restart")
        case .error:
            reset()
        }
    }

    func cancel() {
        logger.info("Recording cancelled")
        hotkeyController.clear()
        let sid = sessionId
        audioService.stopCapture()
        audioStreamer.cancelCurrentEpoch()
        sessionId = nil
        runtimeCoordinator.abortLocalASRSessionIfNeeded(sessionId: sid, asrClient: asrClient)
        previousApp = nil
        activeSessionTargetBundleIdentifier = nil
        pendingRestartAfterForging = false
        silenceDetector.resetForNewSession()
        recordingStartTime = nil
        applyEffectiveBehavior(for: nil)
        runtimeCoordinator.coolLLMRuntime(reason: "recording cancellation")

        Task { @MainActor in
            appState.dictationState = .idle
            appState.errorMessage = nil
            appState.partialTranscript = ""
            appState.audioLevels = []
            appState.isPopoverPresented = false
        }
    }

    @MainActor
    func copyRecentDictation(id: UUID) {
        guard let entry = appState.recentDictations.first(where: { $0.id == id }) else { return }
        textInsertion.copyToClipboard(entry.text)
        logger.info("Copied recent dictation from history (\(entry.text.count) chars)")
    }

    @MainActor
    func clearRecentDictations() {
        recentDictationStore.clear()
        appState.recentDictations = []
        logger.info("Cleared recent dictation history")
    }

    func shutdown() {
        Task {
            await runtimeCoordinator.stopAllRuntimesForShutdown()
        }
    }

    func shutdownAndWait(timeoutSeconds: TimeInterval = 3.0) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await runtimeCoordinator.stopAllRuntimesForShutdown()
            semaphore.signal()
        }

        let didFinishBeforeTimeout = semaphore.wait(timeout: .now() + timeoutSeconds) == .success
        if !didFinishBeforeTimeout {
            logger.warn("Timed out waiting for runtime shutdown during app termination")
        }
    }

    // MARK: - Private

    @discardableResult
    private func startRecordingIfAllowed() -> Bool {
        guard appState.allowsDictationStart else {
            logger.info("Ignoring dictation start while onboarding setup is active")
            return false
        }
        startRecording()
        return appState.dictationState == .listening
    }

    private func startRecording() {
        guard permissionService.hasMicrophonePermission else {
            logger.error("Microphone permission not granted")
            appState.dictationState = .error
            appState.errorMessage = "Microphone permission required. Check System Settings."
            return
        }

        previousApp = frontmostApplicationProvider()
        activeSessionTargetBundleIdentifier = previousApp?.bundleIdentifier
        applyEffectiveBehavior(for: activeSessionTargetBundleIdentifier)
        if let activeSessionTargetBundleIdentifier,
           AppBehaviorSettings.isSupported(
               bundleIdentifier: activeSessionTargetBundleIdentifier,
               settings: settings
           ) {
            logger.info("Resolved app behavior for \(activeSessionTargetBundleIdentifier)")
        } else {
            if let activeSessionTargetBundleIdentifier {
                logger.info("Resolved global behavior for unsupported app \(activeSessionTargetBundleIdentifier)")
            } else {
                logger.info("Resolved global behavior for unknown target app")
            }
        }

        logger.info("Starting recording session")
        appState.dictationState = .listening
        appState.partialTranscript = ""
        appState.isPopoverPresented = true
        recordingStartTime = Date()
        audioStreamer.startNewEpoch()
        silenceDetector.resetForNewSession()
        if transcriptPostProcessingMode == .llm {
            runtimeCoordinator.warmLLMRuntime(reason: "active session")
        }

        Task {
            do {
                sessionId = try await asrClient.startStream()
                logger.info("ASR session started: \(sessionId ?? "nil")")
                try audioService.startCapture()
            } catch {
                logger.error("Failed to start recording: \(error)")
                await MainActor.run {
                    hotkeyController.clear()
                    appState.dictationState = .error
                    appState.errorMessage = error.localizedDescription
                    // Keep HUD visible so the error state is discoverable.
                    appState.isPopoverPresented = true
                }
                recordingStartTime = nil
                runtimeCoordinator.coolLLMRuntime(reason: "recording start failure")
            }
        }
    }

    private func stopRecording() {
        logger.info("Stopping recording")
        let recordingEndedAt = Date()
        audioService.stopCapture()
        appState.dictationState = .forging
        let (recordingEpoch, inFlightChunkTask) = audioStreamer.beginStopping()

        Task {
            defer { audioStreamer.completeStopping() }

            if let inFlightChunkTask {
                await inFlightChunkTask.value
            }

            if audioStreamer.cancellationRequested(for: recordingEpoch) {
                logger.info("Stop sequence aborted due to cancellation request")
                return
            }

            let remainingBuffer: Data = audioStreamer.drainBuffer()

            do {
                // Send any remaining buffered audio
                if !remainingBuffer.isEmpty, let sid = sessionId {
                    let trailingResponse = try await asrClient.sendChunk(sessionId: sid, pcmData: remainingBuffer)
                    await MainActor.run {
                        guard self.sessionId == sid else { return }
                        applyIncomingPartialTranscript(trailingResponse.text, at: clock.now())
                    }
                }

                // Finish the stream
                if audioStreamer.cancellationRequested(for: recordingEpoch) {
                    logger.info("Skipping stream finish due to cancellation request")
                    return
                }

                guard let sid = sessionId else {
                    if audioStreamer.cancellationRequested(for: recordingEpoch) {
                        logger.info("No active session during cancellation; stop ignored")
                        return
                    }
                    throw ASRError.sessionNotFound
                }
                let finalResponse = try await asrClient.finishStream(sessionId: sid)

                if audioStreamer.cancellationRequested(for: recordingEpoch) {
                    logger.info("Discarding final transcript due to cancellation request")
                    return
                }

                let targetApp = previousApp
                let targetAppName = resolvedTargetAppDisplayName(for: targetApp)
                let rawFinalText = finalResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalText = await postProcessFinalTranscript(
                    rawFinalText,
                    targetAppName: targetAppName
                )
                if finalText.isEmpty, !rawFinalText.isEmpty {
                    logger.info("Final transcription empty after post-processing; skipping insertion")
                }
                sessionId = nil
                previousApp = nil
                activeSessionTargetBundleIdentifier = nil

                logger.info("Final transcription ready (\(finalText.count) chars)")

                // PHASE 1: Dismiss UI now that we have the final transcript
                // Must happen BEFORE activating the target app, otherwise
                // the transient popover auto-closes on focus loss and the
                // 100ms timer in AppDelegate re-shows it, stealing focus back.
                await MainActor.run {
                    appState.isPopoverPresented = false
                }

                // Let popover fully dismiss before mutating visible HUD content/state.
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

                // PHASE 2: Activate target app and paste
                var autoSubmitTriggered = false
                var insertionResult: TextInsertionResult = .inserted
                if !finalText.isEmpty {
                    if let targetApp {
                        await MainActor.run {
                            _ = targetApp.activate()
                        }
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

                        // Verify target app is frontmost; retry once if not
                        var frontmost = await MainActor.run {
                            workspaceFrontmostApplicationProvider()
                        }
                        if frontmost?.processIdentifier != targetApp.processIdentifier {
                            logger.warn("Target app not frontmost after activation, retrying")
                            await MainActor.run {
                                _ = targetApp.activate()
                            }
                            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                            frontmost = await MainActor.run {
                                workspaceFrontmostApplicationProvider()
                            }
                        }

                        if frontmost?.processIdentifier != targetApp.processIdentifier {
                            logger.warn("Text insertion failed: target app activation failed")
                            insertionResult = .failed(.targetAppActivationFailed)
                        } else {
                            // PHASE 3: Paste
                            insertionResult = await insertTextOnMainActor(finalText)

                            // PHASE 4: Auto-submit
                            if insertionResult == .inserted {
                                autoSubmitTriggered = await triggerAutoSubmitOnMainActor()
                            }
                        }
                    } else {
                        logger.warn("Text insertion failed: no target app available")
                        insertionResult = .failed(.noTargetAppAvailable)
                    }

                    await recordRecentDictation(
                        text: finalText,
                        sourceApp: targetApp,
                        sourceAppName: targetAppName,
                        insertionResult: insertionResult
                    )

                    if case let .failed(reason) = insertionResult {
                        await MainActor.run {
                            textInsertion.copyToClipboard(finalText)
                            appState.menuBarToast = MenuBarToast(
                                message: "Couldn’t insert text. It’s in your clipboard."
                            )
                        }
                        logger.warn(
                            "Text insertion failed (\(reason.rawValue)); copied forged text to clipboard"
                        )
                    }
                }

                recordUsageStats(
                    finalText: finalText,
                    recordingEndedAt: recordingEndedAt,
                    autoSubmitTriggered: autoSubmitTriggered
                )

                await MainActor.run {
                    hotkeyController.clear()
                    appState.dictationState = .idle
                    appState.partialTranscript = ""
                    appState.audioLevels = []
                }
                await MainActor.run {
                    applyEffectiveBehavior(for: nil)
                }
                if !pendingRestartAfterForging {
                    runtimeCoordinator.coolLLMRuntime(reason: "recording completion")
                }
            } catch {
                if audioStreamer.cancellationRequested(for: recordingEpoch) {
                    logger.info("Ignoring transcription failure after cancellation request")
                    return
                }
                logger.error("Transcription failed: \(error)")
                let failedSessionId = sessionId
                runtimeCoordinator.abortLocalASRSessionIfNeeded(sessionId: failedSessionId, asrClient: asrClient)
                await MainActor.run {
                    hotkeyController.clear()
                    appState.dictationState = .error
                    appState.errorMessage = error.localizedDescription
                }
                sessionId = nil
                previousApp = nil
                activeSessionTargetBundleIdentifier = nil
                recordingStartTime = nil
                await MainActor.run {
                    applyEffectiveBehavior(for: nil)
                }
                runtimeCoordinator.coolLLMRuntime(reason: "recording failure")
            }

            if pendingRestartAfterForging {
                pendingRestartAfterForging = false
                await MainActor.run {
                    if appState.dictationState == .idle {
                        startRecording()
                    }
                }
            }
        }
    }

    @MainActor
    private func insertTextOnMainActor(_ text: String) async -> TextInsertionResult {
        await textInsertion.insertText(text)
    }

    @MainActor
    private func triggerAutoSubmitOnMainActor() -> Bool {
        switch autoSubmitMode {
        case .enter:
            textInsertion.simulateReturn()
            return true
        case .cmdEnter:
            textInsertion.simulateCmdReturn()
            return true
        case .off:
            return false
        }
    }

    private func recordRecentDictation(
        text: String,
        sourceApp: NSRunningApplication?,
        sourceAppName: String?,
        insertionResult: TextInsertionResult
    ) async {
        let entry = RecentDictationEntry(
            id: UUID(),
            text: text,
            createdAt: Date(),
            sourceBundleIdentifier: sourceApp?.bundleIdentifier,
            sourceAppName: sourceAppName,
            insertOutcome: recentDictationInsertOutcome(for: insertionResult)
        )
        recentDictationStore.append(entry)

        await MainActor.run {
            appState.recentDictations.insert(entry, at: 0)
            if appState.recentDictations.count > Constants.recentDictationsMaxCount {
                appState.recentDictations.removeLast(
                    appState.recentDictations.count - Constants.recentDictationsMaxCount
                )
            }
        }
    }

    private func recentDictationInsertOutcome(
        for insertionResult: TextInsertionResult
    ) -> RecentDictationInsertOutcome {
        switch insertionResult {
        case .inserted:
            return .inserted
        case .failed:
            return .failed
        }
    }

    private func reset() {
        hotkeyController.clear()
        appState.dictationState = .idle
        appState.errorMessage = nil
        appState.partialTranscript = ""
        appState.audioLevels = []
        appState.isPopoverPresented = false
        appState.activeTargetBundleIdentifier = nil
        pendingRestartAfterForging = false
        silenceDetector.resetForNewSession()
        activeSessionTargetBundleIdentifier = nil
        recordingStartTime = nil
        applyEffectiveBehavior(for: nil)
        runtimeCoordinator.coolLLMRuntime(reason: "reset")
    }

    private static func currentASRProvider(settings: AppSettingsProtocol) -> ASRProvider {
        settings.asrProvider
    }

    private static func makeConfiguredASRClient(settings: AppSettingsProtocol) -> ASRClientProtocol {
        let provider = currentASRProvider(settings: settings)

        switch provider {
        case .server:
            let baseURL = settings.serverEndpoint
            let password = settings.customServerPassword
            return ASRClient(baseURL: baseURL, apiKey: password, requestTimeout: 15)
        case .local:
            return LocalWhisperASRClient()
        }
    }

    private func applyEffectiveBehavior(for targetBundleIdentifier: String?) {
        let resolved = AppBehaviorSettings.resolvedBehavior(
            for: targetBundleIdentifier,
            settings: settings
        )
        autoSubmitMode = resolved.autoSubmitMode
        silenceTimeout = resolved.silenceTimeout
        transcriptPostProcessingMode = resolved.postProcessingMode
        llmPostProcessingPrompt = resolved.llmPostProcessingPrompt
        commonTerms = resolved.commonTerms
        appState.autoSubmitMode = resolved.autoSubmitMode
        appState.silenceTimeout = resolved.silenceTimeout
        appState.activeTargetBundleIdentifier = targetBundleIdentifier
    }

    private func postProcessFinalTranscript(
        _ rawFinalText: String,
        targetAppName: String?
    ) async -> String {
        let sanitizedRawText = filterTranscriptText(
            rawFinalText,
            sourceLabel: "final transcript",
            emptyTextReason: "skipping insertion"
        )
        guard !sanitizedRawText.isEmpty else { return "" }

        switch transcriptPostProcessingMode {
        case .off:
            return sanitizedRawText
        case .llm:
            let hasCustomPrompt = !llmPostProcessingPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            logger.info(
                "Starting local LLM post-processing (\(sanitizedRawText.count) chars, custom prompt: \(hasCustomPrompt ? "yes" : "no"))"
            )
            let start = Date()
            switch await llmPostProcessWithTimeout(
                text: sanitizedRawText,
                prompt: llmPostProcessingPrompt,
                targetAppName: targetAppName
            ) {
            case .success(let rewritten):
                let rewrittenSanitized = filterTranscriptText(
                    rewritten,
                    sourceLabel: "local LLM output",
                    emptyTextReason: "suppressing final text"
                )
                let duration = Date().timeIntervalSince(start)
                let changed = rewrittenSanitized != sanitizedRawText
                logger.info(
                    "Local LLM post-processing finished in \(String(format: "%.2f", duration))s (changed: \(changed))"
                )
                if rewriteDiverged(input: sanitizedRawText, output: rewrittenSanitized) {
                    logger.warn(
                        "Rewrite diverged from transcript; falling back to filtered transcript"
                    )
                    return sanitizedRawText
                }
                return rewrittenSanitized
            case .failure(let error):
                let duration = Date().timeIntervalSince(start)
                logger.warn(
                    "Local LLM post-processing failed after \(String(format: "%.2f", duration))s, falling back to filtered transcript: \(error)"
                )
                return sanitizedRawText
            case .timeout:
                let duration = Date().timeIntervalSince(start)
                logger.warn(
                    "Local LLM post-processing timed out after \(String(format: "%.2f", duration))s, falling back to filtered transcript"
                )
                return sanitizedRawText
            }
        }
    }

    private static let rewriteDivergenceThreshold = 0.2
    private static let rewriteDivergenceMinWords = 5

    private func rewriteDiverged(input: String, output: String) -> Bool {
        let inputWords = Self.normalizedWords(input)
        guard inputWords.count >= Self.rewriteDivergenceMinWords else { return false }
        let outputWords = Self.normalizedWords(output)
        let overlap = Double(inputWords.intersection(outputWords).count) / Double(inputWords.count)
        return overlap < Self.rewriteDivergenceThreshold
    }

    private static func normalizedWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
        )
    }

    private func filterTranscriptText(
        _ text: String,
        sourceLabel: String,
        emptyTextReason: String
    ) -> String {
        let sanitizedResult = TranscriptArtifactFilter.sanitize(text)
        if sanitizedResult.removedMarkerCount > 0 {
            logger.info(
                "Filtered \(sanitizedResult.removedMarkerCount) non-speech marker(s) from \(sourceLabel)"
            )
        }

        let trailingStripResult = TranscriptArtifactFilter.stripTrailingStandaloneAnnotations(
            sanitizedResult.text
        )
        if trailingStripResult.removedAnnotationCount > 0 {
            logger.info(
                "Stripped \(trailingStripResult.removedAnnotationCount) trailing non-speech annotation(s) from \(sourceLabel)"
            )
        }

        let filteredText = trailingStripResult.text
        if TranscriptArtifactFilter.isOnlyStandaloneAnnotations(filteredText)
            || TranscriptArtifactFilter.isOnlyStandaloneBracketedAnnotations(filteredText) {
            logger.info("\(sourceLabel.capitalized) contained only non-speech annotations; \(emptyTextReason)")
            return ""
        }

        return filteredText
    }

    private enum LLMPostProcessResult {
        case success(String)
        case failure(Error)
        case timeout
    }

    private func llmPostProcessWithTimeout(
        text: String,
        prompt: String,
        targetAppName: String?
    ) async -> LLMPostProcessResult {
        let timeoutNanoseconds = UInt64(Constants.localLLMPostProcessingTimeoutSeconds * 1_000_000_000)

        return await withTaskGroup(of: LLMPostProcessResult.self) { group in
            group.addTask { [self] in
                do {
                    let rewritten = try await self.runtimeCoordinator.localLLMPostProcess(
                        text: text,
                        prompt: prompt,
                        targetApp: targetAppName,
                        commonTerms: commonTerms
                    )
                    return .success(rewritten)
                } catch {
                    return .failure(error)
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timeout
            }

            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
    }

    private func resolvedTargetAppDisplayName(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }

        if let localizedName = app.localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !localizedName.isEmpty {
            return localizedName
        }

        if let bundleIdentifier = app.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return nil
    }

    private func recordUsageStats(
        finalText: String,
        recordingEndedAt: Date,
        autoSubmitTriggered: Bool
    ) {
        let startTime = recordingStartTime ?? recordingEndedAt
        let sessionSeconds = max(0, recordingEndedAt.timeIntervalSince(startTime))
        let words = TextMetrics.wordCount(finalText)
        let dictatedSeconds: TimeInterval
        if words == 0 {
            dictatedSeconds = 0
        } else if !silenceDetector.hasSeenTranscriptPacket {
            // Fallback for providers/environments where only final text is emitted.
            dictatedSeconds = sessionSeconds
        } else {
            let transcriptDrivenSeconds = silenceDetector.estimatedTranscriptActiveSeconds(until: recordingEndedAt)
            dictatedSeconds = min(sessionSeconds, max(0, transcriptDrivenSeconds))
        }
        let autoSubmitCount = autoSubmitTriggered ? 1 : 0

        UsageStatsStore.recordSession(
            words: words,
            dictatedSeconds: dictatedSeconds,
            autoSubmitCount: autoSubmitCount
        )
        recordingStartTime = nil
    }

    private func applyIncomingPartialTranscript(_ incomingText: String, at now: Date) {
        if let merged = silenceDetector.applyIncomingPartialTranscript(
            incomingText,
            at: now,
            previousPartial: appState.partialTranscript
        ) {
            appState.partialTranscript = merged
        }
    }

    static func isLeadingNonSpeechMarker(_ text: String) -> Bool {
        TranscriptArtifactFilter.containsOnlyKnownMarkers(text)
    }

}

// MARK: - AudioChunkStreamerDelegate

extension DictationOrchestrator: AudioChunkStreamerDelegate {
    var currentSessionId: String? { sessionId }

    func audioChunkStreamerSendChunk(
        sessionId: String,
        pcmData: Data
    ) async throws -> ASRChunkResponse {
        try await asrClient.sendChunk(sessionId: sessionId, pcmData: pcmData)
    }

    func audioChunkStreamerDidReceivePartialTranscript(_ text: String, at now: Date) {
        applyIncomingPartialTranscript(text, at: now)
    }
}

// MARK: - HotkeySessionControllerDelegate

extension DictationOrchestrator: HotkeySessionControllerDelegate {
    var currentDictationState: DictationState { appState.dictationState }

    func hotkeyControllerStartRecording() -> Bool {
        startRecordingIfAllowed()
    }

    func hotkeyControllerStopRecording() {
        stopRecording()
    }

    func hotkeyControllerResetSilenceWindow() {
        silenceDetector.resetEvaluationWindow()
    }

    func hotkeyControllerQueueRestartAfterForging() {
        pendingRestartAfterForging = true
    }

    func hotkeyControllerResetFromError() {
        reset()
    }

    func hotkeyControllerSetShowsHoldIndicator(_ visible: Bool) {
        appState.showsHoldIndicator = visible
    }
}

// MARK: - SilenceDetectorDelegate

extension DictationOrchestrator: SilenceDetectorDelegate {
    var currentShowsHoldIndicator: Bool { appState.showsHoldIndicator }
    var currentPartialTranscript: String { appState.partialTranscript }

    func silenceDetectorDidRequestStopRecording(_ detector: SilenceDetector) {
        stopRecording()
    }
}
