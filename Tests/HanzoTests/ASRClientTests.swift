import Testing
import Foundation
@testable import HanzoCore

@Suite("ASRClient", .serialized)
struct ASRClientTests {

    // MARK: - Helpers

    func makeSUT(baseURL: String = "https://example.com", apiKey: String = "test-key") -> ASRClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ASRClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    // MARK: - startStream

    @Test("startStream sends POST to /v1/stream/start")
    func startStreamURL() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"session_id":"abc123"}"#.utf8))
        }

        let sut = makeSUT()
        _ = try await sut.startStream()

        #expect(capturedRequest?.url?.path == "/v1/stream/start")
        #expect(capturedRequest?.httpMethod == "POST")
    }

    @Test("startStream sends X-API-Key header")
    func startStreamAPIKey() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"session_id":"s1"}"#.utf8))
        }

        let sut = makeSUT(apiKey: "my-secret")
        _ = try await sut.startStream()
        #expect(capturedRequest?.value(forHTTPHeaderField: "X-API-Key") == "my-secret")
    }

    @Test("startStream returns session_id from response")
    func startStreamReturnsSessionId() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"session_id":"xyz-789"}"#.utf8))
        }

        let sut = makeSUT()
        let sessionId = try await sut.startStream()
        #expect(sessionId == "xyz-789")
    }

    @Test("startStream throws authenticationFailed on 401")
    func startStream401() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let sut = makeSUT()
        do {
            _ = try await sut.startStream()
            Issue.record("Expected authenticationFailed error")
        } catch let error as ASRError {
            if case .authenticationFailed = error { /* pass */ }
            else { Issue.record("Expected .authenticationFailed, got \(error)") }
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }
    }

    @Test("startStream throws sessionNotFound on 404")
    func startStream404() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let sut = makeSUT()
        do {
            _ = try await sut.startStream()
            Issue.record("Expected sessionNotFound error")
        } catch let error as ASRError {
            if case .sessionNotFound = error { /* pass */ }
            else { Issue.record("Expected .sessionNotFound, got \(error)") }
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }
    }

    @Test("startStream throws serverError on 500")
    func startStream500() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let sut = makeSUT()
        do {
            _ = try await sut.startStream()
            Issue.record("Expected serverError")
        } catch let error as ASRError {
            if case .serverError(let code, _) = error {
                #expect(code == 500)
            } else {
                Issue.record("Expected .serverError, got \(error)")
            }
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }
    }

    @Test("startStream throws networkError when request fails")
    func startStreamNetworkFailure() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let sut = makeSUT()
        do {
            _ = try await sut.startStream()
            Issue.record("Expected networkError")
        } catch let error as ASRError {
            if case .networkError = error { /* pass */ }
            else { Issue.record("Expected .networkError, got \(error)") }
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }
    }

    @Test("startStream throws invalidURL for malformed baseURL")
    func startStreamInvalidURL() async {
        let sut = makeSUT(baseURL: "not a url://[invalid")
        do {
            _ = try await sut.startStream()
            Issue.record("Expected invalidURL error")
        } catch let error as ASRError {
            if case .invalidURL = error { /* pass */ }
            else { Issue.record("Expected .invalidURL, got \(error)") }
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }
    }

    // MARK: - sendChunk

    @Test("sendChunk sends session_id as query parameter")
    func sendChunkQueryParam() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"hello","language":"en"}"#.utf8))
        }

        let sut = makeSUT()
        _ = try await sut.sendChunk(sessionId: "sess-1", pcmData: Data([0x01]))
        let components = URLComponents(url: capturedRequest!.url!, resolvingAgainstBaseURL: false)
        let sessionParam = components?.queryItems?.first(where: { $0.name == "session_id" })
        #expect(sessionParam?.value == "sess-1")
    }

    @Test("sendChunk sends PCM data as body")
    func sendChunkBody() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"t","language":"en"}"#.utf8))
        }

        let pcmData = Data([0xAB, 0xCD, 0xEF])
        let sut = makeSUT()
        _ = try await sut.sendChunk(sessionId: "s", pcmData: pcmData)
        #expect(capturedRequest?.httpBody == pcmData)
    }

    @Test("sendChunk sets Content-Type to application/octet-stream")
    func sendChunkContentType() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"t","language":"en"}"#.utf8))
        }

        let sut = makeSUT()
        _ = try await sut.sendChunk(sessionId: "s", pcmData: Data([0x00]))
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    }

    @Test("sendChunk decodes ASRChunkResponse")
    func sendChunkDecoding() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"partial transcript","language":"fr"}"#.utf8))
        }

        let sut = makeSUT()
        let result = try await sut.sendChunk(sessionId: "s", pcmData: Data())
        #expect(result.text == "partial transcript")
        #expect(result.language == "fr")
    }

    // MARK: - finishStream

    @Test("finishStream sends POST to /v1/stream/finish")
    func finishStreamURL() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"done","language":"en"}"#.utf8))
        }

        let sut = makeSUT()
        _ = try await sut.finishStream(sessionId: "s")
        #expect(capturedRequest?.url?.path == "/v1/stream/finish")
    }

    @Test("finishStream sends session_id as query parameter")
    func finishStreamQueryParam() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"final","language":"en"}"#.utf8))
        }

        let sut = makeSUT()
        _ = try await sut.finishStream(sessionId: "fin-42")
        let components = URLComponents(url: capturedRequest!.url!, resolvingAgainstBaseURL: false)
        let sessionParam = components?.queryItems?.first(where: { $0.name == "session_id" })
        #expect(sessionParam?.value == "fin-42")
    }

    @Test("finishStream decodes ASRFinishResponse")
    func finishStreamDecoding() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"text":"the full text","language":"de"}"#.utf8))
        }

        let sut = makeSUT()
        let result = try await sut.finishStream(sessionId: "s")
        #expect(result.text == "the full text")
        #expect(result.language == "de")
    }
}
