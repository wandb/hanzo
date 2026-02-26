import Foundation
@testable import HanzoCore

actor DelayedSessionASRClient: ASRClientProtocol {
    private var startCounter = 0

    func startStream() async throws -> String {
        startCounter += 1
        return startCounter == 1 ? "session-1" : "session-2"
    }

    func sendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        if sessionId == "session-1" {
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return ASRChunkResponse(text: "stale from session one", language: "en")
        }

        return ASRChunkResponse(text: "fresh from session two", language: "en")
    }

    func finishStream(sessionId: String) async throws -> ASRFinishResponse {
        ASRFinishResponse(text: "", language: "en")
    }
}
