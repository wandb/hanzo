import Foundation

protocol LocalWhisperRuntimeClientProtocol {
    func startSession() async throws -> String
    func appendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse
    func finishSession(sessionId: String) async throws -> ASRFinishResponse
    func abortSession(sessionId: String) async
}

final class LocalWhisperASRClient: ASRClientProtocol {
    private let runtime: LocalWhisperRuntimeClientProtocol
    private let logger: LoggingServiceProtocol

    init(
        runtime: LocalWhisperRuntimeClientProtocol = LocalWhisperRuntime.shared,
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
        guard pcmData.count <= Constants.defaultMaxChunkBytes else {
            throw ASRError.chunkExceedsLimit(
                maxBytes: Constants.defaultMaxChunkBytes,
                actualBytes: pcmData.count
            )
        }

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

    func abortStream(sessionId: String) async {
        await runtime.abortSession(sessionId: sessionId)
    }

    private func mapToASRError(_ error: Error) -> ASRError {
        if let asrError = error as? ASRError {
            return asrError
        }
        return ASRError.localRuntimeUnavailable(detail: error.localizedDescription)
    }
}
