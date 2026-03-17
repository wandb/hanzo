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
    private var previousApp: NSRunningApplication?
    private var activeSessionTargetBundleIdentifier: String?
    private var pendingRestartAfterForging = false
    private var configuredASRProvider: ASRProvider
    private var transcriptPostProcessingMode: TranscriptPostProcessingMode
    private var llmPostProcessingPrompt: String

    // Auto-submit
    var autoSubmitMode: AutoSubmitMode

    // Silence auto-close
    var silenceTimeout: Double
    private var silenceStartTime: Date?
    private var peakSpeechLevel: Float = 0

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
        self.transcriptPostProcessingMode = AppBehaviorSettings.globalPostProcessingMode()
        self.llmPostProcessingPrompt = AppBehaviorSettings.globalLLMPostProcessingPrompt()

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

        if let activeSessionTargetBundleIdentifier {
            applyEffectiveBehavior(for: activeSessionTargetBundleIdentifier)
        } else {
            applyEffectiveBehavior(for: nil)
        }

        configuredASRProvider = DictationOrchestrator.currentASRProvider()
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
        let shouldWarmLocalLLMRuntime = transcriptPostProcessingMode == .llm
            && previousPostProcessingMode != .llm

        if shouldRestartLocalRuntime || shouldWarmLocalRuntime
            || shouldStopLocalLLMRuntime || shouldWarmLocalLLMRuntime {
            Task {
                if shouldRestartLocalRuntime {
                    await localRuntimeManager.stop()
                }

                if shouldStopLocalLLMRuntime {
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
        }
        sessionId = nil
        abortLocalSessionIfNeeded(sid)
        previousApp = nil
        activeSessionTargetBundleIdentifier = nil
        pendingRestartAfterForging = false
        silenceStartTime = nil
        peakSpeechLevel = 0
        applyEffectiveBehavior(for: nil)

        Task { @MainActor in
            appState.dictationState = .idle
            appState.partialTranscript = ""
            appState.audioLevels = []
            appState.isPopoverPresented = false
        }
    }

    func shutdown() {
        Task {
            await localRuntimeManager.stop()
            await localLLMRuntimeManager.stop()
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
        }
        silenceStartTime = nil
        peakSpeechLevel = 0

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

    private func stopRecording() {
        logger.info("Stopping recording")
        audioService.stopCapture()
        appState.dictationState = .forging
        bufferQueue.sync {
            isStoppingRecording = true
        }
        let inFlightChunkTask = chunkSendTask

        Task {
            if let inFlightChunkTask {
                await inFlightChunkTask.value
            }

            let remainingBuffer: Data = bufferQueue.sync {
                let data = audioBuffer
                audioBuffer.removeAll()
                return data
            }

            do {
                // Send any remaining buffered audio
                if !remainingBuffer.isEmpty, let sid = sessionId {
                    _ = try await asrClient.sendChunk(sessionId: sid, pcmData: remainingBuffer)
                }

                // Finish the stream
                guard let sid = sessionId else {
                    throw ASRError.sessionNotFound
                }
                let finalResponse = try await asrClient.finishStream(sessionId: sid)
                let rawFinalText = finalResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalText = await postProcessFinalTranscript(rawFinalText)
                let targetApp = previousApp
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

                await MainActor.run {
                    appState.dictationState = .idle
                }

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
                    await MainActor.run {
                        textInsertion.insertText(finalText)
                    }

                    // PHASE 4: Auto-submit
                    switch autoSubmitMode {
                    case .enter:
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for paste to complete
                        await MainActor.run {
                            textInsertion.simulateReturn()
                        }
                    case .cmdEnter:
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for paste to complete
                        await MainActor.run {
                            textInsertion.simulateCmdReturn()
                        }
                    case .off:
                        break
                    }
                }

                await MainActor.run {
                    appState.partialTranscript = ""
                    appState.audioLevels = []
                }
                await MainActor.run {
                    applyEffectiveBehavior(for: nil)
                }
            } catch {
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

            bufferQueue.sync {
                isChunkSendInFlight = false
                isStoppingRecording = false
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
        activeSessionTargetBundleIdentifier = nil
        applyEffectiveBehavior(for: nil)
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
            let response = try await asrClient.sendChunk(sessionId: sid, pcmData: pcmData)
            await MainActor.run {
                guard self.sessionId == sid else { return }
                guard appState.dictationState == .listening else { return }
                appState.partialTranscript = PartialTranscriptMerger.merge(
                    previous: appState.partialTranscript,
                    incoming: response.text
                )
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

    private func postProcessFinalTranscript(_ rawFinalText: String) async -> String {
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
                prompt: llmPostProcessingPrompt
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

    private func llmPostProcessWithTimeout(text: String, prompt: String) async -> LLMPostProcessResult {
        let timeoutNanoseconds = UInt64(Constants.localLLMPostProcessingTimeoutSeconds * 1_000_000_000)

        return await withTaskGroup(of: LLMPostProcessResult.self) { group in
            group.addTask { [self] in
                do {
                    let rewritten = try await self.localLLMRuntimeManager.postProcess(
                        text: text,
                        prompt: prompt
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

    // MARK: - Silence Detection

    private func evaluateSilence(levels: [Float]) {
        guard silenceTimeout > 0 else { return }
        guard appState.dictationState == .listening else {
            silenceStartTime = nil
            return
        }

        let averageLevel = levels.isEmpty ? 0 : levels.reduce(0, +) / Float(levels.count)
        let threshold = max(
            peakSpeechLevel * Constants.silenceRelativeThreshold,
            Constants.silenceAbsoluteFloor
        )

        if averageLevel >= threshold {
            // Speech detected — update peak and reset silence timer
            if averageLevel > peakSpeechLevel {
                peakSpeechLevel = averageLevel
            }
            silenceStartTime = nil
            return
        }

        // Audio is below threshold — only start timer after words have been transcribed
        guard !appState.partialTranscript.isEmpty else { return }

        if silenceStartTime == nil {
            silenceStartTime = Date()
        }

        if let start = silenceStartTime,
           Date().timeIntervalSince(start) >= silenceTimeout {
            logger.info("Silence auto-close after \(silenceTimeout)s")
            silenceStartTime = nil
            stopRecording()
        }
    }
}
