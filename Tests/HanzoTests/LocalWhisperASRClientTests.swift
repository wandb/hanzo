import Testing
import Foundation
@testable import HanzoCore

@Suite("LocalWhisperASRClient")
struct LocalWhisperASRClientTests {
    actor MockRuntime: LocalWhisperRuntimeClientProtocol {
        var startResult: Result<String, Error> = .success("session-1")
        var appendResult: Result<ASRChunkResponse, Error> = .success(
            ASRChunkResponse(text: "partial", language: "en")
        )
        var finishResult: Result<ASRFinishResponse, Error> = .success(
            ASRFinishResponse(text: "final", language: "en")
        )
        var appendCallCount = 0
        var abortedSessionIds: [String] = []

        func startSession() async throws -> String {
            try startResult.get()
        }

        func appendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
            appendCallCount += 1
            return try appendResult.get()
        }

        func finishSession(sessionId: String) async throws -> ASRFinishResponse {
            try finishResult.get()
        }

        func abortSession(sessionId: String) async {
            abortedSessionIds.append(sessionId)
        }

        func setStartResult(_ result: Result<String, Error>) {
            startResult = result
        }

        func setAppendResult(_ result: Result<ASRChunkResponse, Error>) {
            appendResult = result
        }

        func appendCalls() -> Int {
            appendCallCount
        }

        func abortedSessions() -> [String] {
            abortedSessionIds
        }
    }

    @Test("startStream maps non-ASRError failures to localRuntimeUnavailable")
    func startStreamMapsUnknownError() async {
        let runtime = MockRuntime()
        await runtime.setStartResult(.failure(NSError(domain: "test", code: 42)))
        let client = LocalWhisperASRClient(runtime: runtime, logger: MockLogger())

        do {
            _ = try await client.startStream()
            Issue.record("Expected startStream to throw")
        } catch let error as ASRError {
            guard case .localRuntimeUnavailable = error else {
                Issue.record("Expected localRuntimeUnavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }
    }

    @Test("sendChunk preserves ASRError values from runtime")
    func sendChunkPreservesASRError() async {
        let runtime = MockRuntime()
        await runtime.setAppendResult(.failure(ASRError.sessionNotFound))
        let client = LocalWhisperASRClient(runtime: runtime, logger: MockLogger())

        do {
            _ = try await client.sendChunk(sessionId: "session-1", pcmData: Data(repeating: 0, count: 4))
            Issue.record("Expected sendChunk to throw")
        } catch let error as ASRError {
            guard case .sessionNotFound = error else {
                Issue.record("Expected sessionNotFound, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }
    }

    @Test("sendChunk rejects payloads larger than default max chunk bytes")
    func sendChunkRejectsOversizedPayload() async {
        let runtime = MockRuntime()
        let client = LocalWhisperASRClient(runtime: runtime, logger: MockLogger())
        let payload = Data(repeating: 0xFF, count: Constants.defaultMaxChunkBytes + 1)

        do {
            _ = try await client.sendChunk(sessionId: "session-1", pcmData: payload)
            Issue.record("Expected oversized chunk to throw")
        } catch let error as ASRError {
            guard case .chunkExceedsLimit(let maxBytes, let actualBytes) = error else {
                Issue.record("Expected chunkExceedsLimit, got \(error)")
                return
            }
            #expect(maxBytes == Constants.defaultMaxChunkBytes)
            #expect(actualBytes == payload.count)
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }

        let appendCalls = await runtime.appendCalls()
        #expect(appendCalls == 0)
    }

    @Test("abortStream forwards to runtime")
    func abortStreamForwardsToRuntime() async {
        let runtime = MockRuntime()
        let client = LocalWhisperASRClient(runtime: runtime, logger: MockLogger())

        await client.abortStream(sessionId: "session-123")

        let aborted = await runtime.abortedSessions()
        #expect(aborted == ["session-123"])
    }
}
