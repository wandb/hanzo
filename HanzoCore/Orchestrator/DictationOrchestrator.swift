import Foundation
import AppKit
import SwiftUI

@Observable
final class DictationOrchestrator {
    private let appState: AppState
    private var audioService: AudioCaptureProtocol
    private let textInsertion: TextInsertionProtocol
    private let permissionService: PermissionServiceProtocol
    private let logger: LoggingServiceProtocol

    private var asrClient: ASRClientProtocol
    private let isASRClientInjected: Bool
    private var sessionId: String?
    private var audioBuffer = Data()
    private let bufferQueue = DispatchQueue(label: "com.hanzo.audiobuffer")
    private var chunkSendTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?

    // Auto-submit
    var autoSubmit: Bool

    // Silence auto-close
    var silenceTimeout: Double
    private var silenceStartTime: Date?
    private var hasSpeechBeenDetected: Bool = false
    private var peakSpeechLevel: Float = 0

    init(
        appState: AppState,
        asrClient: ASRClientProtocol? = nil,
        audioService: AudioCaptureProtocol = AudioCaptureService(),
        textInsertion: TextInsertionProtocol = TextInsertionService(),
        permissionService: PermissionServiceProtocol = PermissionService.shared,
        logger: LoggingServiceProtocol = LoggingService.shared
    ) {
        self.appState = appState
        self.audioService = audioService
        self.textInsertion = textInsertion
        self.permissionService = permissionService
        self.logger = logger

        self.autoSubmit = UserDefaults.standard.object(forKey: Constants.autoSubmitKey) != nil
            ? UserDefaults.standard.bool(forKey: Constants.autoSubmitKey)
            : Constants.defaultAutoSubmit

        let storedTimeout = UserDefaults.standard.object(forKey: Constants.silenceTimeoutKey)
        self.silenceTimeout = storedTimeout != nil
            ? UserDefaults.standard.double(forKey: Constants.silenceTimeoutKey)
            : Constants.defaultSilenceTimeout

        if let asrClient = asrClient {
            self.asrClient = asrClient
            self.isASRClientInjected = true
        } else {
            let baseURL = UserDefaults.standard.string(forKey: Constants.serverEndpointKey)
                ?? Constants.defaultServerEndpoint
            let apiKey = UserDefaults.standard.string(forKey: Constants.apiKeyKey) ?? Constants.defaultAPIKey
            self.asrClient = ASRClient(baseURL: baseURL, apiKey: apiKey)
            self.isASRClientInjected = false
        }

        appState.autoSubmit = self.autoSubmit
        appState.silenceTimeout = self.silenceTimeout

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
        autoSubmit = UserDefaults.standard.object(forKey: Constants.autoSubmitKey) != nil
            ? UserDefaults.standard.bool(forKey: Constants.autoSubmitKey)
            : Constants.defaultAutoSubmit

        let storedTimeout = UserDefaults.standard.object(forKey: Constants.silenceTimeoutKey)
        silenceTimeout = storedTimeout != nil
            ? UserDefaults.standard.double(forKey: Constants.silenceTimeoutKey)
            : Constants.defaultSilenceTimeout

        appState.autoSubmit = autoSubmit
        appState.silenceTimeout = silenceTimeout

        guard !isASRClientInjected else { return }
        let baseURL = UserDefaults.standard.string(forKey: Constants.serverEndpointKey)
            ?? Constants.defaultServerEndpoint
        let apiKey = UserDefaults.standard.string(forKey: Constants.apiKeyKey) ?? Constants.defaultAPIKey
        asrClient = ASRClient(baseURL: baseURL, apiKey: apiKey)
    }

    func toggle() {
        switch appState.dictationState {
        case .idle:
            startRecording()
        case .listening:
            stopRecording()
        case .forging:
            break // ignore toggle while forging
        case .error:
            reset()
        }
    }

    func cancel() {
        logger.info("Recording cancelled")
        chunkSendTask?.cancel()
        audioService.stopCapture()
        bufferQueue.sync { audioBuffer.removeAll() }
        sessionId = nil
        previousApp = nil
        silenceStartTime = nil
        hasSpeechBeenDetected = false
        peakSpeechLevel = 0

        Task { @MainActor in
            appState.dictationState = .idle
            appState.partialTranscript = ""
            appState.audioLevels = []
            appState.isPopoverPresented = false
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

        previousApp = NSWorkspace.shared.frontmostApplication
        logger.info("Starting recording session")
        appState.dictationState = .listening
        appState.partialTranscript = ""
        appState.isPopoverPresented = true
        bufferQueue.sync { audioBuffer.removeAll() }
        silenceStartTime = nil
        hasSpeechBeenDetected = false
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
                    appState.isPopoverPresented = false
                }
            }
        }
    }

    private func stopRecording() {
        logger.info("Stopping recording")
        audioService.stopCapture()
        appState.audioLevels = []
        appState.dictationState = .forging

        let remainingBuffer: Data = bufferQueue.sync {
            let data = audioBuffer
            audioBuffer.removeAll()
            return data
        }

        Task {
            do {
                // Send any remaining buffered audio
                if !remainingBuffer.isEmpty, let sid = sessionId {
                    let response = try await asrClient.sendChunk(sessionId: sid, pcmData: remainingBuffer)
                    await MainActor.run {
                        appState.partialTranscript = response.text
                    }
                }

                // Finish the stream
                guard let sid = sessionId else {
                    throw ASRError.sessionNotFound
                }
                let finalResponse = try await asrClient.finishStream(sessionId: sid)
                let finalText = finalResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)

                logger.info("Final transcription (\(finalText.count) chars): \(finalText.prefix(100))")

                // PHASE 1: Dismiss UI now that we have the final transcript
                // Must happen BEFORE activating the target app, otherwise
                // the transient popover auto-closes on focus loss and the
                // 100ms timer in AppDelegate re-shows it, stealing focus back.
                await MainActor.run {
                    appState.isPopoverPresented = false
                    appState.partialTranscript = ""
                    appState.dictationState = .idle
                }

                // Let popover fully dismiss
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

                // PHASE 2: Activate target app and paste
                if !finalText.isEmpty, let targetApp = previousApp {
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

                    // PHASE 4: Auto-submit (press Return)
                    if autoSubmit {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for paste to complete
                        await MainActor.run {
                            textInsertion.simulateReturn()
                        }
                    }
                }
            } catch {
                logger.error("Transcription failed: \(error)")
                await MainActor.run {
                    appState.dictationState = .error
                    appState.errorMessage = error.localizedDescription
                }
            }

            sessionId = nil
            previousApp = nil
        }
    }

    private func handleAudioChunk(_ data: Data) {
        var shouldSend = false
        var chunkToSend = Data()

        bufferQueue.sync {
            audioBuffer.append(data)
            if audioBuffer.count >= Constants.chunkAccumulationBytes {
                chunkToSend = audioBuffer
                audioBuffer.removeAll()
                shouldSend = true
            }
        }

        guard shouldSend, let sid = sessionId else { return }

        chunkSendTask = Task {
            do {
                let response = try await asrClient.sendChunk(sessionId: sid, pcmData: chunkToSend)
                await MainActor.run {
                    appState.partialTranscript = response.text
                }
            } catch {
                logger.warn("Chunk send failed: \(error)")
            }
        }
    }

    private func reset() {
        appState.dictationState = .idle
        appState.errorMessage = nil
        appState.partialTranscript = ""
        appState.audioLevels = []
        appState.isPopoverPresented = false
        silenceStartTime = nil
        hasSpeechBeenDetected = false
        peakSpeechLevel = 0
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
            hasSpeechBeenDetected = true
            silenceStartTime = nil
            return
        }

        // Audio is below threshold — only care if speech was previously detected
        guard hasSpeechBeenDetected else { return }

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
