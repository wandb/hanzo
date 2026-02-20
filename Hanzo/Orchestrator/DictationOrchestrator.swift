import Foundation
import AppKit

@Observable
final class DictationOrchestrator {
    private let appState: AppState
    private let audioService = AudioCaptureService()
    private let textInsertion = TextInsertionService()
    private let logger = LoggingService.shared

    private var asrClient: ASRClient
    private var sessionId: String?
    private var audioBuffer = Data()
    private let bufferQueue = DispatchQueue(label: "com.hanzo.audiobuffer")
    private var chunkSendTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?

    init(appState: AppState) {
        self.appState = appState
        let baseURL = UserDefaults.standard.string(forKey: Constants.serverEndpointKey)
            ?? Constants.defaultServerEndpoint
        let apiKey = KeychainService.shared.loadAPIKey() ?? Constants.defaultAPIKey
        self.asrClient = ASRClient(baseURL: baseURL, apiKey: apiKey)

        audioService.onAudioChunk = { [weak self] data in
            self?.handleAudioChunk(data)
        }
    }

    func reloadSettings() {
        let baseURL = UserDefaults.standard.string(forKey: Constants.serverEndpointKey)
            ?? Constants.defaultServerEndpoint
        let apiKey = KeychainService.shared.loadAPIKey() ?? Constants.defaultAPIKey
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

        Task { @MainActor in
            appState.dictationState = .idle
            appState.partialTranscript = ""
            appState.isPopoverPresented = false
        }
    }

    // MARK: - Private

    private func startRecording() {
        guard PermissionService.shared.hasMicrophonePermission else {
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

                // Re-activate the previous app and insert text
                await MainActor.run {
                    if !finalText.isEmpty {
                        previousApp?.activate()
                    }
                }

                // Small delay for app activation to complete
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

                await MainActor.run {
                    if !finalText.isEmpty {
                        textInsertion.insertText(finalText)
                    }
                    appState.dictationState = .idle
                    appState.partialTranscript = ""
                    appState.isPopoverPresented = false
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
        appState.isPopoverPresented = false
    }
}
