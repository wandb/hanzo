import Foundation
@testable import HanzoCore

actor SlowFinishingASRClient: ASRClientProtocol {
    func startStream() async throws -> String {
        "slow-finish-session"
    }

    func sendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        ASRChunkResponse(text: "streaming transcript", language: "en")
    }

    func finishStream(sessionId: String) async throws -> ASRFinishResponse {
        try? await Task.sleep(nanoseconds: 400_000_000)
        return ASRFinishResponse(text: "final transcript", language: "en")
    }
}
