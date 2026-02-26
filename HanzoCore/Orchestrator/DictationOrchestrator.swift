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
    private let logger: LoggingServiceProtocol

    private var asrClient: ASRClientProtocol
    private let isASRClientInjected: Bool
    private var sessionId: String?
    private var audioBuffer = Data()
    private let bufferQueue = DispatchQueue(label: "com.hanzo.audiobuffer")
    private var chunkSendTask: Task<Void, Never>?
    private var isChunkSendInFlight = false
    private var isStoppingRecording = false
    private var previousApp: NSRunningApplication?
    private var pendingRestartAfterForging = false
    private var configuredASRProvider: ASRProvider
    private var configuredLocalBaseURL: String
    private var configuredLocalModelPreset: LocalASRModelPreset

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
        logger: LoggingServiceProtocol = LoggingService.shared
    ) {
        self.appState = appState
        self.audioService = audioService
        self.textInsertion = textInsertion
        self.permissionService = permissionService
        self.localRuntimeManager = localRuntimeManager
        self.logger = logger

        if let raw = UserDefaults.standard.string(forKey: Constants.autoSubmitKey) {
            self.autoSubmitMode = AutoSubmitMode(rawValue: raw) ?? Constants.defaultAutoSubmitMode
        } else {
            self.autoSubmitMode = Constants.defaultAutoSubmitMode
        }

        let storedTimeout = UserDefaults.standard.object(forKey: Constants.silenceTimeoutKey)
        self.silenceTimeout = storedTimeout != nil
            ? UserDefaults.standard.double(forKey: Constants.silenceTimeoutKey)
            : Constants.defaultSilenceTimeout

        if let asrClient = asrClient {
            self.asrClient = asrClient
            self.isASRClientInjected = true
        } else {
            self.asrClient = DictationOrchestrator.makeConfiguredASRClient()
            self.isASRClientInjected = false
        }

        self.configuredASRProvider = DictationOrchestrator.currentASRProvider()
        self.configuredLocalBaseURL = DictationOrchestrator.currentLocalBaseURL()
        self.configuredLocalModelPreset = DictationOrchestrator.currentLocalASRModelPreset()

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
    }

    func reloadSettings() {
        let previousProvider = configuredASRProvider
        let previousLocalBaseURL = configuredLocalBaseURL
        let previousLocalModelPreset = configuredLocalModelPreset

        if let raw = UserDefaults.standard.string(forKey: Constants.autoSubmitKey) {
            autoSubmitMode = AutoSubmitMode(rawValue: raw) ?? Constants.defaultAutoSubmitMode
        } else {
            autoSubmitMode = Constants.defaultAutoSubmitMode
        }

        let storedTimeout = UserDefaults.standard.object(forKey: Constants.silenceTimeoutKey)
        silenceTimeout = storedTimeout != nil
            ? UserDefaults.standard.double(forKey: Constants.silenceTimeoutKey)
            : Constants.defaultSilenceTimeout

        appState.autoSubmitMode = autoSubmitMode
        appState.silenceTimeout = silenceTimeout
        configuredASRProvider = DictationOrchestrator.currentASRProvider()
        configuredLocalBaseURL = DictationOrchestrator.currentLocalBaseURL()
        configuredLocalModelPreset = DictationOrchestrator.currentLocalASRModelPreset()
        appState.asrProvider = configuredASRProvider

        if !isASRClientInjected {
            asrClient = DictationOrchestrator.makeConfiguredASRClient()
        }

        let localConfigChanged = previousLocalBaseURL != configuredLocalBaseURL
            || previousLocalModelPreset != configuredLocalModelPreset
        let shouldRestartLocalRuntime = previousProvider == .local
            && (configuredASRProvider != .local || localConfigChanged)
        let shouldWarmLocalRuntime = configuredASRProvider == .local
            && (previousProvider != .local || localConfigChanged)

        if shouldRestartLocalRuntime || shouldWarmLocalRuntime {
            let baseURL = configuredLocalBaseURL
            Task {
                if shouldRestartLocalRuntime {
                    await localRuntimeManager.stop()
                }

                guard shouldWarmLocalRuntime else { return }

                do {
                    try await localRuntimeManager.ensureRunning(baseURL: baseURL)
                    try await localRuntimeManager.prepareModel(baseURL: baseURL)
                    logger.info("Local ASR helper warmed after settings change")
                } catch {
                    logger.warn("Failed to warm local ASR helper after settings change: \(error)")
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
        chunkSendTask?.cancel()
        audioService.stopCapture()
        bufferQueue.sync {
            audioBuffer.removeAll()
            isChunkSendInFlight = false
            isStoppingRecording = false
        }
        sessionId = nil
        previousApp = nil
        pendingRestartAfterForging = false
        silenceStartTime = nil
        peakSpeechLevel = 0

        Task { @MainActor in
            appState.dictationState = .idle
            appState.partialTranscript = ""
            appState.audioLevels = []
            appState.isPopoverPresented = false
        }
    }

    func shutdown() {
        Task { await localRuntimeManager.stop() }
    }

    // MARK: - Private

    private func startRecording() {
        guard permissionService.hasMicrophonePermission else {
            logger.error("Microphone permission not granted")
            appState.dictationState = .error
            appState.errorMessage = "Microphone permission required. Check System Settings."
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication
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
                if !isASRClientInjected, DictationOrchestrator.currentASRProvider() == .local {
                    let localBaseURL = UserDefaults.standard.string(forKey: Constants.localServerEndpointKey)
                        ?? Constants.defaultLocalServerEndpoint
                    try await localRuntimeManager.ensureRunning(baseURL: localBaseURL)
                }

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
                let finalText = finalResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let targetApp = previousApp
                sessionId = nil
                previousApp = nil

                logger.info("Final transcription (\(finalText.count) chars): \(finalText.prefix(100))")

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
            } catch {
                logger.error("Transcription failed: \(error)")
                await MainActor.run {
                    appState.dictationState = .error
                    appState.errorMessage = error.localizedDescription
                }
                sessionId = nil
                previousApp = nil
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
        pendingRestartAfterForging = false
        silenceStartTime = nil
        peakSpeechLevel = 0
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

    private static func currentASRProvider() -> ASRProvider {
        if let raw = UserDefaults.standard.string(forKey: Constants.asrProviderKey),
           let provider = ASRProvider(rawValue: raw) {
            return provider
        }
        return Constants.defaultASRProvider
    }

    private static func currentLocalBaseURL() -> String {
        UserDefaults.standard.string(forKey: Constants.localServerEndpointKey)
            ?? Constants.defaultLocalServerEndpoint
    }

    private static func currentLocalASRModelPreset() -> LocalASRModelPreset {
        if let raw = UserDefaults.standard.string(forKey: Constants.localASRModelPresetKey),
           let preset = LocalASRModelPreset(rawValue: raw) {
            return preset
        }
        return Constants.defaultLocalASRModelPreset
    }

    private static func makeConfiguredASRClient() -> ASRClient {
        let provider = currentASRProvider()

        switch provider {
        case .hosted:
            return ASRClient(
                baseURL: Constants.hostedServerEndpoint,
                apiKey: Constants.hostedServerPassword,
                requestTimeout: 15
            )
        case .server:
            let baseURL = UserDefaults.standard.string(forKey: Constants.serverEndpointKey)
                ?? Constants.defaultServerEndpoint
            let password = UserDefaults.standard.string(forKey: Constants.customServerPasswordKey)
                ?? Constants.defaultCustomServerPassword
            return ASRClient(baseURL: baseURL, apiKey: password, requestTimeout: 15)
        case .local:
            let baseURL = UserDefaults.standard.string(forKey: Constants.localServerEndpointKey)
                ?? Constants.defaultLocalServerEndpoint
            return ASRClient(baseURL: baseURL, apiKey: "", requestTimeout: 300)
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
