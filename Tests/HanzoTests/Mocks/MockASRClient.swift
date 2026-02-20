import Foundation
@testable import HanzoCore

final class MockASRClient: ASRClientProtocol {
    var startStreamResult: Result<String, Error> = .success("test-session-id")
    var sendChunkResult: Result<ASRChunkResponse, Error> = .success(
        ASRChunkResponse(text: "partial", language: "en")
    )
    var finishStreamResult: Result<ASRFinishResponse, Error> = .success(
        ASRFinishResponse(text: "final text", language: "en")
    )

    var startStreamCallCount = 0
    var sendChunkCalls: [(sessionId: String, pcmData: Data)] = []
    var finishStreamCalls: [String] = []

    func startStream() async throws -> String {
        startStreamCallCount += 1
        return try startStreamResult.get()
    }

    func sendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        sendChunkCalls.append((sessionId: sessionId, pcmData: pcmData))
        return try sendChunkResult.get()
    }

    func finishStream(sessionId: String) async throws -> ASRFinishResponse {
        finishStreamCalls.append(sessionId)
        return try finishStreamResult.get()
    }
}
