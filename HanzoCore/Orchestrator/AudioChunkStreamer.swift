import Foundation

protocol AudioChunkStreamerDelegate: AnyObject {
    var currentSessionId: String? { get }
    var currentDictationState: DictationState { get }
    func audioChunkStreamerSendChunk(
        sessionId: String,
        pcmData: Data
    ) async throws -> ASRChunkResponse
    func audioChunkStreamerDidReceivePartialTranscript(_ text: String, at now: Date)
}

/// Owns the audio buffer and the chunk-send state machine:
/// accumulates PCM bytes, flushes once the chunk threshold is reached,
/// serializes send-in-flight, and tracks recording generations so rapid
/// stop/cancel/start sequences can't race with in-flight transcription
/// responses. The bufferQueue is intentionally a plain DispatchQueue — all
/// mutable state is touched only under it, and several call sites need
/// synchronous access from non-main-actor contexts (audio tap callback).
final class AudioChunkStreamer {
    weak var delegate: AudioChunkStreamerDelegate?

    private let logger: LoggingServiceProtocol
    private let clock: ClockProtocol
    private let bufferQueue = DispatchQueue(label: "com.hanzo.audiobuffer")
    private var audioBuffer = Data()
    private var chunkSendTask: Task<Void, Never>?
    private var isChunkSendInFlight = false
    private var isStoppingRecording = false
    private var currentRecordingEpoch = 0
    private var lastCancelledRecordingEpoch = 0

    init(logger: LoggingServiceProtocol, clock: ClockProtocol = SystemClock()) {
        self.logger = logger
        self.clock = clock
    }

    func startNewEpoch() {
        bufferQueue.sync {
            audioBuffer.removeAll()
            isChunkSendInFlight = false
            isStoppingRecording = false
            currentRecordingEpoch += 1
        }
    }

    func enqueueChunk(_ data: Data) {
        bufferQueue.sync {
            audioBuffer.append(data)
        }
        maybeStartChunkSendIfNeeded()
    }

    /// Marks the streamer as stopping and returns the epoch + any in-flight task
    /// so the caller can await chunk completion before sending the trailing buffer.
    func beginStopping() -> (epoch: Int, inFlightTask: Task<Void, Never>?) {
        bufferQueue.sync {
            isStoppingRecording = true
            return (currentRecordingEpoch, chunkSendTask)
        }
    }

    func drainBuffer() -> Data {
        bufferQueue.sync {
            let data = audioBuffer
            audioBuffer.removeAll()
            return data
        }
    }

    func completeStopping() {
        bufferQueue.sync {
            isChunkSendInFlight = false
            isStoppingRecording = false
        }
    }

    func cancelCurrentEpoch() {
        let taskToCancel: Task<Void, Never>? = bufferQueue.sync {
            let task = chunkSendTask
            chunkSendTask = nil
            audioBuffer.removeAll()
            isChunkSendInFlight = false
            isStoppingRecording = false
            lastCancelledRecordingEpoch = max(lastCancelledRecordingEpoch, currentRecordingEpoch)
            return task
        }
        taskToCancel?.cancel()
    }

    func cancellationRequested(for recordingEpoch: Int) -> Bool {
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
            guard let delegate, let currentSessionId = delegate.currentSessionId else { return }

            chunkToSend = audioBuffer
            audioBuffer.removeAll()
            sid = currentSessionId
            isChunkSendInFlight = true
            shouldSend = true
        }

        guard shouldSend, let sid else { return }

        let task: Task<Void, Never> = Task { [weak self] in
            await self?.sendChunkAndContinue(sessionId: sid, pcmData: chunkToSend)
        }
        bufferQueue.sync {
            chunkSendTask = task
        }
    }

    private func sendChunkAndContinue(sessionId sid: String, pcmData: Data) async {
        guard let delegate else { return }
        do {
            let sentAt = clock.now()
            let response = try await delegate.audioChunkStreamerSendChunk(
                sessionId: sid,
                pcmData: pcmData
            )
            let roundTripSeconds = clock.now().timeIntervalSince(sentAt)
            if roundTripSeconds > 1.0 {
                let bufferedSeconds = Double(pcmData.count)
                    / (Constants.audioSampleRate * Double(MemoryLayout<Float>.size))
                logger.warn(
                    "Chunk round-trip slow (\(String(format: "%.2f", roundTripSeconds))s) " +
                    "for \(String(format: "%.2f", bufferedSeconds))s audio"
                )
            }
            let receivedAt = clock.now()
            await MainActor.run {
                guard delegate.currentSessionId == sid else { return }
                guard delegate.currentDictationState == .listening else { return }
                delegate.audioChunkStreamerDidReceivePartialTranscript(response.text, at: receivedAt)
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
}
