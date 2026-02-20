import Foundation

protocol ASRClientProtocol {
    func startStream() async throws -> String
    func sendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse
    func finishStream(sessionId: String) async throws -> ASRFinishResponse
}
