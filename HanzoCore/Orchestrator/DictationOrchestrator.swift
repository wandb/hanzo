import Foundation
import AppKit
import SwiftUI

@Observable
final class DictationOrchestrator {
    private let appState: AppState
    private var audioService: AudioCaptureProtocol
    private let textInsertion: TextInsertionProtocol
    private let permissionService: PermissionServiceProtocol
    private let localRuntimeManager: LocalASRRuntimeManagerProtocol
    private let localLLMRuntimeManager: LocalLLMRuntimeManagerProtocol
    private let logger: LoggingServiceProtocol
    private let frontmostApplicationProvider: () -> NSRunningApplication?

    private var asrClient: ASRClientProtocol
    private let isASRClientInjected: Bool
    private var sessionId: String?
    private var audioBuffer = Data()
    private let bufferQueue = DispatchQueue(label: "com.hanzo.audiobuffer")
    private var chunkSendTask: Task<Void, Never>?
    private var isChunkSendInFlight = false
    private var isStoppingRecording = false
    private var currentRecordingEpoch = 0
    private var lastCancelledRecordingEpoch = 0
    private var previousApp: NSRunningApplication?
    private var activeSessionTargetBundleIdentifier: String?
    private var pendingRestartAfterForging = false
    private var configuredASRProvider: ASRProvider
    private var configuredLocalLLMContextSize: Int
    private var transcriptPostProcessingMode: TranscriptPostProcessingMode
    private var llmPostProcessingPrompt: String
    private var commonTerms: [String]

    // Auto-submit
    var autoSubmitMode: AutoSubmitMode

    // Silence auto-close
    var silenceTimeout: Double
    private var silenceStartTime: Date?
    private var peakSpeechLevel: Float = 0
    private var ambientNoiseLevel: Float = Constants.silenceAbsoluteFloor
    private var lastSilenceEvaluationAt: Date?
    private var lastObservedPartialTranscript: String = ""
    private var lastPartialTranscriptUpdateAt: Date?

    init(
        appState: AppState,
        asrClient: ASRClientProtocol? = nil,
        audioService: AudioCaptureProtocol = AudioCaptureService(),
        textInsertion: TextInsertionProtocol = TextInsertionService(),
        permissionService: PermissionServiceProtocol = PermissionService.shared,
        localRuntimeManager: LocalASRRuntimeManagerProtocol = LocalASRRuntimeManager(),
        localLLMRuntimeManager: LocalLLMRuntimeManagerProtocol = LocalLLMRuntimeManager.shared,
        logger: LoggingServiceProtocol = LoggingService.shared,
        frontmostApplicationProvider: @escaping () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        }
    ) {
        self.appState = appState
        self.audioService = audioService
        self.textInsertion = textInsertion
        self.permissionService = permissionService
        self.localRuntimeManager = localRuntimeManager
        self.localLLMRuntimeManager = localLLMRuntimeManager
        self.logger = logger
        self.frontmostApplicationProvider = frontmostApplicationProvider

        self.autoSubmitMode = AppBehaviorSettings.globalAutoSubmitMode()
        self.silenceTimeout = AppBehaviorSettings.globalSilenceTimeout()

        if let asrClient = asrClient {
            self.asrClient = asrClient
            self.isASRClientInjected = true
        } else {
            self.asrClient = DictationOrchestrator.makeConfiguredASRClient()
            self.isASRClientInjected = false
        }

        self.configuredASRProvider = DictationOrchestrator.currentASRProvider()
        self.configuredLocalLLMContextSize = Constants.localLLMContextSize()
        self.transcriptPostProcessingMode = AppBehaviorSettings.globalPostProcessingMode()
        self.llmPostProcessingPrompt = AppBehaviorSettings.globalLLMPostProcessingPrompt()
        self.commonTerms = CommonTerms.parse(AppBehaviorSettings.globalCommonTerms())

        appState.autoSubmitMode = self.autoSubmitMode
        appState.silenceTimeout = self.silenceTimeout
        appState.asrProvider = self.configuredASRProvider

        self.audioService.onAudioChunk = { [weak self] data in
            self?.handleAudioChunk(data)
        }

        self.audioService.onAudioLevels = { [weak self] levels in
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.15)) {
                    self?.appState.audioLevels = levels
                }
                self?.evaluateSilence(levels: levels)
            }
        }

        let hasRequiredPermissions = permissionService.hasMicrophonePermission
            && permissionService.hasAccessibilityPermission
        if hasRequiredPermissions {
            prewarmConfiguredRuntimes(
                asrProvider: configuredASRProvider,
                postProcessingMode: transcriptPostProcessingMode
            )
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

        configuredASRProvider = DictationOrchestrator.currentASRProvider()
        configuredLocalLLMContextSize = Constants.localLLMContextSize()
        appState.asrProvider = configuredASRProvider

        if !isASRClientInjected {
            asrClient = DictationOrchestrator.makeConfiguredASRClient()
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
        let shouldWarmLocalLLMRuntime = transcriptPostProcessingMode == .llm
            && (previousPostProcessingMode != .llm || shouldRestartLocalLLMRuntimeForContextChange)

        if shouldRestartLocalRuntime || shouldWarmLocalRuntime
            || shouldStopLocalLLMRuntime || shouldWarmLocalLLMRuntime
            || shouldRestartLocalLLMRuntimeForContextChange {
            Task {
                if shouldRestartLocalRuntime {
                    await localRuntimeManager.stop()
                }

                if shouldStopLocalLLMRuntime || shouldRestartLocalLLMRuntimeForContextChange {
                    await localLLMRuntimeManager.stop()
                }

                if shouldWarmLocalRuntime {
                    do {
                        try await localRuntimeManager.prepareModel()
                        logger.info("Local Whisper runtime warmed after settings change")
                    } catch {
                        logger.warn("Failed to warm local Whisper runtime after settings change: \(error)")
                    }
                }

                if shouldWarmLocalLLMRuntime {
                    do {
                        try await localLLMRuntimeManager.prepareModel()
                        logger.info("Local LLM runtime warmed after settings change")
                    } catch {
                        logger.warn("Failed to warm local LLM runtime after settings change: \(error)")
                    }
                }
            }
        }
    }

    func toggle() {
        switch appState.dictationState {
        case .idle:
            startRecording()
        case .listening:
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
        let sid = sessionId
        chunkSendTask?.cancel()
        audioService.stopCapture()
        bufferQueue.sync {
            audioBuffer.removeAll()
            isChunkSendInFlight = false
            isStoppingRecording = false
            lastCancelledRecordingEpoch = max(lastCancelledRecordingEpoch, currentRecordingEpoch)
        }
        sessionId = nil
        abortLocalSessionIfNeeded(sid)
        previousApp = nil
        activeSessionTargetBundleIdentifier = nil
        pendingRestartAfterForging = false
        silenceStartTime = nil
        peakSpeechLevel = 0
        ambientNoiseLevel = Constants.silenceAbsoluteFloor
        lastSilenceEvaluationAt = nil
        lastObservedPartialTranscript = ""
        lastPartialTranscriptUpdateAt = nil
        applyEffectiveBehavior(for: nil)

        Task { @MainActor in
            appState.dictationState = .idle
            appState.errorMessage = nil
            appState.partialTranscript = ""
            appState.audioLevels = []
            appState.isPopoverPresented = false
        }
    }

    func shutdown() {
        Task {
            await stopRuntimesForShutdown()
        }
    }

    func shutdownAndWait(timeoutSeconds: TimeInterval = 3.0) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await stopRuntimesForShutdown()
            semaphore.signal()
        }

        let didFinishBeforeTimeout = semaphore.wait(timeout: .now() + timeoutSeconds) == .success
        if !didFinishBeforeTimeout {
            logger.warn("Timed out waiting for runtime shutdown during app termination")
        }
    }

    // MARK: - Private

    private func startRecording() {
        guard permissionService.hasMicrophonePermission else {
            logger.error("Microphone permission not granted")
            appState.dictationState = .error
            appState.errorMessage = "Microphone permission required. Check System Settings."
            return
        }

        previousApp = frontmostApplicationProvider()
        activeSessionTargetBundleIdentifier = previousApp?.bundleIdentifier
        if let activeSessionTargetBundleIdentifier,
           AppBehaviorSettings.isSupported(bundleIdentifier: activeSessionTargetBundleIdentifier) {
            applyEffectiveBehavior(for: activeSessionTargetBundleIdentifier)
            logger.info("Resolved app behavior for \(activeSessionTargetBundleIdentifier)")
        } else {
            appState.activeTargetBundleIdentifier = activeSessionTargetBundleIdentifier
        }

        logger.info("Starting recording session")
        appState.dictationState = .listening
        appState.partialTranscript = ""
        appState.isPopoverPresented = true
        bufferQueue.sync {
            audioBuffer.removeAll()
            isChunkSendInFlight = false
            isStoppingRecording = false
            currentRecordingEpoch += 1
        }
        silenceStartTime = nil
        peakSpeechLevel = 0
        ambientNoiseLevel = Constants.silenceAbsoluteFloor
        lastSilenceEvaluationAt = nil
        lastObservedPartialTranscript = ""
        lastPartialTranscriptUpdateAt = nil

        Task {
            do {
                sessionId = try await asrClient.startStream()
                logger.info("ASR session started: \(sessionId ?? "nil")")
                try audioService.startCapture()
            } catch {
                logger.error("Failed to start recording: \(error)")
                await MainActor.run {
                    appState.dictationState = .error
                    appState.errorMessage = error.localizedDescription
                    // Keep HUD visible so the error state is discoverable.
                    appState.isPopoverPresented = true
                }
            }
        }
    }

    private func stopRuntimesForShutdown() async {
        await localRuntimeManager.stop()
        await localLLMRuntimeManager.stop()
    }

    private func stopRecording() {
        logger.info("Stopping recording")
        audioService.stopCapture()
        appState.dictationState = .forging
        var recordingEpoch = 0
        bufferQueue.sync {
            isStoppingRecording = true
            recordingEpoch = currentRecordingEpoch
        }
        let inFlightChunkTask = chunkSendTask

        Task {
            defer {
                bufferQueue.sync {
                    isChunkSendInFlight = false
                    isStoppingRecording = false
                }
            }

            if let inFlightChunkTask {
                await inFlightChunkTask.value
            }

            if cancellationRequested(for: recordingEpoch) {
                logger.info("Stop sequence aborted due to cancellation request")
                return
            }

            let remainingBuffer: Data = bufferQueue.sync {
                let data = audioBuffer
                audioBuffer.removeAll()
                return data
            }

            do {
                // Send any remaining buffered audio
                if !remainingBuffer.isEmpty, let sid = sessionId {
                    let trailingResponse = try await asrClient.sendChunk(sessionId: sid, pcmData: remainingBuffer)
                    await MainActor.run {
                        guard self.sessionId == sid else { return }
                        let now = Date()
                        let previousPartial = appState.partialTranscript
                        let transcriptStaleness = lastPartialTranscriptUpdateAt
                            .map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                        let allowAggressiveRecovery = transcriptStaleness
                            >= Constants.partialTranscriptAggressiveRecoveryAfterSeconds
                        let mergedPartial = PartialTranscriptMerger.merge(
                            previous: previousPartial,
                            incoming: trailingResponse.text,
                            allowAggressiveRecovery: allowAggressiveRecovery
                        )
                        guard mergedPartial != previousPartial else { return }
                        appState.partialTranscript = mergedPartial
                        lastPartialTranscriptUpdateAt = now
                        lastObservedPartialTranscript = mergedPartial
                    }
                }

                // Finish the stream
                if cancellationRequested(for: recordingEpoch) {
                    logger.info("Skipping stream finish due to cancellation request")
                    return
                }

                guard let sid = sessionId else {
                    if cancellationRequested(for: recordingEpoch) {
                        logger.info("No active session during cancellation; stop ignored")
                        return
                    }
                    throw ASRError.sessionNotFound
                }
                let finalResponse = try await asrClient.finishStream(sessionId: sid)

                if cancellationRequested(for: recordingEpoch) {
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
                if !finalText.isEmpty, let targetApp {
                    await MainActor.run {
                        _ = targetApp.activate()
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

                    // Verify target app is frontmost; retry once if not
                    let frontmost = NSWorkspace.shared.frontmostApplication
                    if frontmost?.processIdentifier != targetApp.processIdentifier {
                        logger.warn("Target app not frontmost after activation, retrying")
                        await MainActor.run {
                            _ = targetApp.activate()
                        }
                        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                    }

                    // PHASE 3: Paste
                    await insertTextOnMainActor(finalText)

                    // PHASE 4: Auto-submit
                    await triggerAutoSubmitOnMainActor()
                }

                await MainActor.run {
                    appState.dictationState = .idle
                    appState.partialTranscript = ""
                    appState.audioLevels = []
                }
                await MainActor.run {
                    applyEffectiveBehavior(for: nil)
                }
            } catch {
                if cancellationRequested(for: recordingEpoch) {
                    logger.info("Ignoring transcription failure after cancellation request")
                    return
                }
                logger.error("Transcription failed: \(error)")
                let failedSessionId = sessionId
                abortLocalSessionIfNeeded(failedSessionId)
                await MainActor.run {
                    appState.dictationState = .error
                    appState.errorMessage = error.localizedDescription
                }
                sessionId = nil
                previousApp = nil
                activeSessionTargetBundleIdentifier = nil
                await MainActor.run {
                    applyEffectiveBehavior(for: nil)
                }
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

    private func handleAudioChunk(_ data: Data) {
        bufferQueue.sync {
            audioBuffer.append(data)
        }

        maybeStartChunkSendIfNeeded()
    }

    @MainActor
    private func insertTextOnMainActor(_ text: String) async {
        await textInsertion.insertText(text)
    }

    @MainActor
    private func triggerAutoSubmitOnMainActor() {
        switch autoSubmitMode {
        case .enter:
            textInsertion.simulateReturn()
        case .cmdEnter:
            textInsertion.simulateCmdReturn()
        case .off:
            break
        }
    }

    private func reset() {
        appState.dictationState = .idle
        appState.errorMessage = nil
        appState.partialTranscript = ""
        appState.audioLevels = []
        appState.isPopoverPresented = false
        appState.activeTargetBundleIdentifier = nil
        pendingRestartAfterForging = false
        silenceStartTime = nil
        peakSpeechLevel = 0
        ambientNoiseLevel = Constants.silenceAbsoluteFloor
        lastSilenceEvaluationAt = nil
        lastObservedPartialTranscript = ""
        lastPartialTranscriptUpdateAt = nil
        activeSessionTargetBundleIdentifier = nil
        applyEffectiveBehavior(for: nil)
    }

    private func cancellationRequested(for recordingEpoch: Int) -> Bool {
        bufferQueue.sync { lastCancelledRecordingEpoch >= recordingEpoch }
    }

    private func maybeStartChunkSendIfNeeded() {
        var shouldSend = false
        var chunkToSend = Data()
        var sid: String?

        bufferQueue.sync {
            guard !isStoppingRecording else { return }
            guard !isChunkSendInFlight else { return }
            guard audioBuffer.count >= Constants.chunkAccumulationBytes else { return }
            guard let currentSessionId = sessionId else { return }

            chunkToSend = audioBuffer
            audioBuffer.removeAll()
            sid = currentSessionId
            isChunkSendInFlight = true
            shouldSend = true
        }

        guard shouldSend, let sid else { return }

        chunkSendTask = Task { [weak self] in
            await self?.sendChunkAndContinue(sessionId: sid, pcmData: chunkToSend)
        }
    }

    private func sendChunkAndContinue(sessionId sid: String, pcmData: Data) async {
        do {
            let sentAt = Date()
            let response = try await asrClient.sendChunk(sessionId: sid, pcmData: pcmData)
            let roundTripSeconds = Date().timeIntervalSince(sentAt)
            if roundTripSeconds > 1.0 {
                let bufferedSeconds = Double(pcmData.count) / (Constants.audioSampleRate * Double(MemoryLayout<Float>.size))
                logger.warn(
                    "Chunk round-trip slow (\(String(format: "%.2f", roundTripSeconds))s) " +
                    "for \(String(format: "%.2f", bufferedSeconds))s audio"
                )
            }
            await MainActor.run {
                guard self.sessionId == sid else { return }
                guard appState.dictationState == .listening else { return }
                let now = Date()
                let previousPartial = appState.partialTranscript
                let transcriptStaleness = lastPartialTranscriptUpdateAt
                    .map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                let allowAggressiveRecovery = transcriptStaleness
                    >= Constants.partialTranscriptAggressiveRecoveryAfterSeconds
                let mergedPartial = PartialTranscriptMerger.merge(
                    previous: previousPartial,
                    incoming: response.text,
                    allowAggressiveRecovery: allowAggressiveRecovery
                )
                guard mergedPartial != previousPartial else { return }
                appState.partialTranscript = mergedPartial
                lastPartialTranscriptUpdateAt = now
                lastObservedPartialTranscript = mergedPartial
            }
        } catch {
            if !Task.isCancelled {
                logger.warn("Chunk send failed: \(error)")
            }
        }

        bufferQueue.sync {
            isChunkSendInFlight = false
        }

        if !Task.isCancelled {
            maybeStartChunkSendIfNeeded()
        }
    }

    private func abortLocalSessionIfNeeded(_ sessionId: String?) {
        guard let sessionId,
              let localClient = asrClient as? LocalWhisperASRClient else {
            return
        }

        Task {
            await localClient.abortStream(sessionId: sessionId)
        }
    }

    private static func currentASRProvider() -> ASRProvider {
        if let raw = UserDefaults.standard.string(forKey: Constants.asrProviderKey),
           let provider = ASRProvider(rawValue: raw) {
            return provider
        }
        return Constants.defaultASRProvider
    }

    private static func makeConfiguredASRClient() -> ASRClientProtocol {
        let provider = currentASRProvider()

        switch provider {
        case .server:
            let baseURL = UserDefaults.standard.string(forKey: Constants.serverEndpointKey)
                ?? Constants.defaultServerEndpoint
            let password = UserDefaults.standard.string(forKey: Constants.customServerPasswordKey)
                ?? Constants.defaultCustomServerPassword
            return ASRClient(baseURL: baseURL, apiKey: password, requestTimeout: 15)
        case .local:
            return LocalWhisperASRClient()
        }
    }

    private func applyEffectiveBehavior(for targetBundleIdentifier: String?) {
        let resolved = AppBehaviorSettings.resolvedBehavior(for: targetBundleIdentifier)
        autoSubmitMode = resolved.autoSubmitMode
        silenceTimeout = resolved.silenceTimeout
        transcriptPostProcessingMode = resolved.postProcessingMode
        llmPostProcessingPrompt = resolved.llmPostProcessingPrompt
        commonTerms = resolved.commonTerms
        appState.autoSubmitMode = resolved.autoSubmitMode
        appState.silenceTimeout = resolved.silenceTimeout
        appState.activeTargetBundleIdentifier = targetBundleIdentifier
    }

    private func prewarmConfiguredRuntimes(
        asrProvider: ASRProvider,
        postProcessingMode: TranscriptPostProcessingMode
    ) {
        guard asrProvider == .local || postProcessingMode == .llm else {
            return
        }

        Task {
            if asrProvider == .local {
                do {
                    try await localRuntimeManager.prepareModel()
                    logger.info("Local Whisper runtime prewarmed at launch")
                } catch {
                    logger.warn("Failed to prewarm local Whisper runtime at launch: \(error)")
                }
            }

            if postProcessingMode == .llm {
                do {
                    try await localLLMRuntimeManager.prepareModel()
                    logger.info("Local LLM runtime prewarmed at launch")
                } catch {
                    logger.warn("Failed to prewarm local LLM runtime at launch: \(error)")
                }
            }
        }
    }

    private func postProcessFinalTranscript(
        _ rawFinalText: String,
        targetAppName: String?
    ) async -> String {
        guard !rawFinalText.isEmpty else { return rawFinalText }

        switch transcriptPostProcessingMode {
        case .off:
            return rawFinalText
        case .llm:
            let hasCustomPrompt = !llmPostProcessingPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            logger.info(
                "Starting local LLM post-processing (\(rawFinalText.count) chars, custom prompt: \(hasCustomPrompt ? "yes" : "no"))"
            )
            let start = Date()
            switch await llmPostProcessWithTimeout(
                text: rawFinalText,
                prompt: llmPostProcessingPrompt,
                targetAppName: targetAppName
            ) {
            case .success(let rewritten):
                let duration = Date().timeIntervalSince(start)
                let changed = rewritten != rawFinalText
                logger.info(
                    "Local LLM post-processing finished in \(String(format: "%.2f", duration))s (changed: \(changed))"
                )
                return rewritten
            case .failure(let error):
                let duration = Date().timeIntervalSince(start)
                logger.warn(
                    "Local LLM post-processing failed after \(String(format: "%.2f", duration))s, falling back to raw transcript: \(error)"
                )
                return rawFinalText
            case .timeout:
                let duration = Date().timeIntervalSince(start)
                logger.warn(
                    "Local LLM post-processing timed out after \(String(format: "%.2f", duration))s, falling back to raw transcript"
                )
                return rawFinalText
            }
        }
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
                    let rewritten = try await self.localLLMRuntimeManager.postProcess(
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

    // MARK: - Silence Detection

    private func evaluateSilence(levels: [Float]) {
        guard silenceTimeout > 0 else { return }
        let now = Date()

        guard appState.dictationState == .listening else {
            silenceStartTime = nil
            lastSilenceEvaluationAt = nil
            return
        }

        if appState.partialTranscript != lastObservedPartialTranscript {
            lastObservedPartialTranscript = appState.partialTranscript
            if !appState.partialTranscript.isEmpty {
                lastPartialTranscriptUpdateAt = now
            }
        }

        let averageLevel = levels.isEmpty ? 0 : levels.reduce(0, +) / Float(levels.count)
        let elapsedSinceLastEvaluation: TimeInterval
        if let lastEvaluation = lastSilenceEvaluationAt {
            let elapsed = max(0, now.timeIntervalSince(lastEvaluation))
            elapsedSinceLastEvaluation = elapsed
            let decayBase = Double(Constants.silencePeakDecayPerSecond)
            let decayedPeak = peakSpeechLevel * Float(pow(decayBase, elapsed))
            peakSpeechLevel = max(decayedPeak, averageLevel)
        } else {
            elapsedSinceLastEvaluation = 0
            peakSpeechLevel = max(peakSpeechLevel, averageLevel)
        }
        lastSilenceEvaluationAt = now

        let ambientSampleCap = max(
            Constants.silenceAbsoluteFloor * 2,
            peakSpeechLevel * Constants.silenceAmbientTrackingPeakFraction
        )
        if averageLevel <= ambientSampleCap {
            let riseAlpha = exponentialSmoothingAlpha(
                ratePerSecond: Constants.silenceAmbientTrackingRisePerSecond,
                elapsed: elapsedSinceLastEvaluation
            )
            let fallAlpha = exponentialSmoothingAlpha(
                ratePerSecond: Constants.silenceAmbientTrackingFallPerSecond,
                elapsed: elapsedSinceLastEvaluation
            )
            let alpha = averageLevel > ambientNoiseLevel ? riseAlpha : fallAlpha
            ambientNoiseLevel += (averageLevel - ambientNoiseLevel) * alpha
        }
        ambientNoiseLevel = max(Constants.silenceAbsoluteFloor, ambientNoiseLevel)

        let rawThreshold = max(
            peakSpeechLevel * Constants.silenceRelativeThreshold,
            Constants.silenceAbsoluteFloor
        )
        let ambientThreshold = max(
            ambientNoiseLevel * Constants.silenceAmbientThresholdMultiplier,
            ambientNoiseLevel + Constants.silenceAmbientThresholdOffset
        )
        let threshold = max(
            rawThreshold,
            ambientThreshold
        )
        let speechActivityThreshold = max(
            threshold * Constants.silenceSpeechActivityThresholdMultiplier,
            threshold + Constants.silenceSpeechActivityThresholdOffset
        )

        if averageLevel >= speechActivityThreshold {
            // Raise the speech-detection bar so borderline ambient bumps
            // are more likely treated as silence.
            silenceStartTime = nil
            return
        }

        // Audio is below threshold — only start timer after words have been transcribed
        guard !appState.partialTranscript.isEmpty else { return }

        let transcriptGrace = max(
            Constants.silenceTranscriptActivityGraceMinimumSeconds,
            silenceTimeout * Constants.silenceTranscriptActivityGraceMultiplier
        )
        let clampedTranscriptGrace = min(
            transcriptGrace,
            Constants.silenceTranscriptActivityGraceMaximumSeconds
        )
        if let lastTranscriptUpdateAt = lastPartialTranscriptUpdateAt,
           now.timeIntervalSince(lastTranscriptUpdateAt) < clampedTranscriptGrace,
           silenceStartTime == nil {
            return
        }

        if silenceStartTime == nil {
            silenceStartTime = now
        }

        if let start = silenceStartTime,
           now.timeIntervalSince(start) >= silenceTimeout {
            let transcriptAge = lastPartialTranscriptUpdateAt
                .map { String(format: "%.2f", now.timeIntervalSince($0)) } ?? "n/a"
            logger.info(
                "Silence auto-close after \(silenceTimeout)s " +
                "(avg \(String(format: "%.4f", averageLevel)), " +
                "ambient \(String(format: "%.4f", ambientNoiseLevel)), " +
                "threshold \(String(format: "%.4f", threshold)), " +
                "activityThreshold \(String(format: "%.4f", speechActivityThreshold)), " +
                "transcriptAge \(transcriptAge)s)"
            )
            silenceStartTime = nil
            stopRecording()
        }
    }

    private func exponentialSmoothingAlpha(ratePerSecond: Float, elapsed: TimeInterval) -> Float {
        guard elapsed > 0 else { return 0 }
        let clampedRate = min(max(ratePerSecond, 0), 1)
        guard clampedRate < 1 else { return 1 }
        return 1 - Float(pow(Double(1 - clampedRate), elapsed))
    }
}
