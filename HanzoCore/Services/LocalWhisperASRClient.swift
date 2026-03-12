import Foundation

final class LocalWhisperASRClient: ASRClientProtocol {
    private let runtime: LocalWhisperRuntime
    private let logger: LoggingServiceProtocol

    init(
        runtime: LocalWhisperRuntime = .shared,
        logger: LoggingServiceProtocol = LoggingService.shared
    ) {
        self.runtime = runtime
        self.logger = logger
    }

    func startStream() async throws -> String {
        do {
            return try await runtime.startSession()
        } catch {
            logger.error("Failed to start local Whisper stream: \(error)")
            throw mapToASRError(error)
        }
    }

    func sendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        do {
            return try await runtime.appendChunk(sessionId: sessionId, pcmData: pcmData)
        } catch {
            logger.warn("Failed local Whisper chunk decode: \(error)")
            throw mapToASRError(error)
        }
    }

    func finishStream(sessionId: String) async throws -> ASRFinishResponse {
        do {
            return try await runtime.finishSession(sessionId: sessionId)
        } catch {
            logger.error("Failed to finish local Whisper stream: \(error)")
            throw mapToASRError(error)
        }
    }

    private func mapToASRError(_ error: Error) -> ASRError {
        if let asrError = error as? ASRError {
            return asrError
        }
        return ASRError.localRuntimeUnavailable(detail: error.localizedDescription)
    }
}
