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

    func httpResponse(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func capabilitiesJSON(
        apiVersion: Int = ASRClient.supportedAPIVersion,
        maxChunkBytes: Int = Constants.defaultMaxChunkBytes
    ) -> Data {
        Data(
            """
            {"api_version":\(apiVersion),"limits":{"max_chunk_bytes":\(maxChunkBytes)}}
            """.utf8
        )
    }

    // MARK: - startStream

    @Test("startStream probes capabilities and then starts stream")
    func startStreamCallsCapabilitiesThenStart() async throws {
        var seenPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            seenPaths.append(request.url?.path ?? "")
            if request.url?.path == "/v1/capabilities" {
                return (httpResponse(for: request, statusCode: 200), capabilitiesJSON())
            }
            return (
                httpResponse(for: request, statusCode: 200),
                Data(#"{"session_id":"abc123"}"#.utf8)
            )
        }

        let sut = makeSUT()
        _ = try await sut.startStream()

        #expect(seenPaths == ["/v1/capabilities", "/v1/stream/start"])
    }

    @Test("startStream sends X-API-Key on capabilities and start requests")
    func startStreamAPIKey() async throws {
        var capturedHeaders: [String?] = []
        MockURLProtocol.requestHandler = { request in
            capturedHeaders.append(request.value(forHTTPHeaderField: "X-API-Key"))
            if request.url?.path == "/v1/capabilities" {
                return (httpResponse(for: request, statusCode: 200), capabilitiesJSON())
            }
            return (httpResponse(for: request, statusCode: 200), Data(#"{"session_id":"s1"}"#.utf8))
        }

        let sut = makeSUT(apiKey: "my-secret")
        _ = try await sut.startStream()
        #expect(capturedHeaders == ["my-secret", "my-secret"])
    }

    @Test("startStream sends required audio contract payload")
    func startStreamBodyContainsAudioContract() async throws {
        var capturedStartBody: Data?
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/v1/capabilities" {
                return (httpResponse(for: request, statusCode: 200), capabilitiesJSON())
            }
            capturedStartBody = request.httpBody
            return (httpResponse(for: request, statusCode: 200), Data(#"{"session_id":"s1"}"#.utf8))
        }

        let sut = makeSUT()
        _ = try await sut.startStream()

        let json = try #require(capturedStartBody)
        let payload = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let audio = try #require(payload["audio"] as? [String: Any])
        #expect(audio["encoding"] as? String == "pcm_f32le")
        #expect(audio["sample_rate_hz"] as? Int == 16000)
        #expect(audio["channels"] as? Int == 1)
    }

    @Test("startStream returns session_id from response")
    func startStreamReturnsSessionId() async throws {
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/v1/capabilities" {
                return (httpResponse(for: request, statusCode: 200), capabilitiesJSON())
            }
            return (httpResponse(for: request, statusCode: 200), Data(#"{"session_id":"xyz-789"}"#.utf8))
        }

        let sut = makeSUT()
        let sessionId = try await sut.startStream()
        #expect(sessionId == "xyz-789")
    }

    @Test("startStream throws authenticationFailed on 401")
    func startStream401() async {
        MockURLProtocol.requestHandler = { request in
            (httpResponse(for: request, statusCode: 401), Data())
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

    @Test("startStream throws unsupportedAPIVersion when capabilities mismatch")
    func startStreamUnsupportedVersion() async {
        MockURLProtocol.requestHandler = { request in
            (
                httpResponse(for: request, statusCode: 200),
                capabilitiesJSON(apiVersion: ASRClient.supportedAPIVersion + 1)
            )
        }

        let sut = makeSUT()
        do {
            _ = try await sut.startStream()
            Issue.record("Expected unsupportedAPIVersion")
        } catch let error as ASRError {
            if case .unsupportedAPIVersion(let received) = error {
                #expect(received == ASRClient.supportedAPIVersion + 1)
            } else {
                Issue.record("Expected .unsupportedAPIVersion, got \(error)")
            }
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }
    }

    @Test("startStream throws serverError on 500 with parsed contract detail")
    func startStream500() async {
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/v1/capabilities" {
                return (httpResponse(for: request, statusCode: 200), capabilitiesJSON())
            }
            return (
                httpResponse(for: request, statusCode: 500),
                Data(#"{"error":{"code":"runtime_failure","message":"decoder crashed","retryable":false}}"#.utf8)
            )
        }

        let sut = makeSUT()
        do {
            _ = try await sut.startStream()
            Issue.record("Expected serverError")
        } catch let error as ASRError {
            if case .serverError(let code, let detail) = error {
                #expect(code == 500)
                #expect(detail?.contains("runtime_failure") == true)
                #expect(detail?.contains("decoder crashed") == true)
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

    @Test("startStream reuses cached capabilities across sessions")
    func startStreamCachesCapabilities() async throws {
        var capabilitiesCalls = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/v1/capabilities" {
                capabilitiesCalls += 1
                return (httpResponse(for: request, statusCode: 200), capabilitiesJSON())
            }
            return (httpResponse(for: request, statusCode: 200), Data(#"{"session_id":"s"}"#.utf8))
        }

        let sut = makeSUT()
        _ = try await sut.startStream()
        _ = try await sut.startStream()
        #expect(capabilitiesCalls == 1)
    }

    // MARK: - sendChunk

    @Test("sendChunk sends session_id as query parameter")
    func sendChunkQueryParam() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (httpResponse(for: request, statusCode: 200), Data(#"{"text":"hello","language":"en"}"#.utf8))
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
            return (httpResponse(for: request, statusCode: 200), Data(#"{"text":"t","language":"en"}"#.utf8))
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
            return (httpResponse(for: request, statusCode: 200), Data(#"{"text":"t","language":"en"}"#.utf8))
        }

        let sut = makeSUT()
        _ = try await sut.sendChunk(sessionId: "s", pcmData: Data([0x00]))
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    }

    @Test("sendChunk decodes ASRChunkResponse")
    func sendChunkDecoding() async throws {
        MockURLProtocol.requestHandler = { request in
            (httpResponse(for: request, statusCode: 200), Data(#"{"text":"partial transcript","language":"fr"}"#.utf8))
        }

        let sut = makeSUT()
        let result = try await sut.sendChunk(sessionId: "s", pcmData: Data())
        #expect(result.text == "partial transcript")
        #expect(result.language == "fr")
    }

    @Test("sendChunk maps 404 to sessionNotFound")
    func sendChunk404() async {
        MockURLProtocol.requestHandler = { request in
            (httpResponse(for: request, statusCode: 404), Data())
        }

        let sut = makeSUT()
        do {
            _ = try await sut.sendChunk(sessionId: "s", pcmData: Data([0x01]))
            Issue.record("Expected sessionNotFound")
        } catch let error as ASRError {
            if case .sessionNotFound = error { /* pass */ }
            else { Issue.record("Expected .sessionNotFound, got \(error)") }
        } catch {
            Issue.record("Expected ASRError, got \(error)")
        }
    }

    @Test("sendChunk enforces max_chunk_bytes from capabilities")
    func sendChunkRespectsCapabilitiesLimit() async throws {
        var seenPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            seenPaths.append(request.url?.path ?? "")
            if request.url?.path == "/v1/capabilities" {
                return (httpResponse(for: request, statusCode: 200), capabilitiesJSON(maxChunkBytes: 2))
            }
            return (httpResponse(for: request, statusCode: 200), Data(#"{"session_id":"s"}"#.utf8))
        }

        let sut = makeSUT()
        _ = try await sut.startStream()

        do {
            _ = try await sut.sendChunk(sessionId: "s", pcmData: Data([0x01, 0x02, 0x03]))
            Issue.record("Expected chunkExceedsLimit")
        } catch let error as ASRError {
            if case .chunkExceedsLimit(let maxBytes, let actualBytes) = error {
                #expect(maxBytes == 2)
                #expect(actualBytes == 3)
            } else {
                Issue.record("Expected .chunkExceedsLimit, got \(error)")
            }
        }

        // No /chunk request should be sent when client-side limit check fails.
        #expect(seenPaths == ["/v1/capabilities", "/v1/stream/start"])
    }

    // MARK: - finishStream

    @Test("finishStream sends POST to /v1/stream/finish")
    func finishStreamURL() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (httpResponse(for: request, statusCode: 200), Data(#"{"text":"done","language":"en"}"#.utf8))
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
            return (httpResponse(for: request, statusCode: 200), Data(#"{"text":"final","language":"en"}"#.utf8))
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
            (httpResponse(for: request, statusCode: 200), Data(#"{"text":"the full text","language":"de"}"#.utf8))
        }

        let sut = makeSUT()
        let result = try await sut.finishStream(sessionId: "s")
        #expect(result.text == "the full text")
        #expect(result.language == "de")
    }
}
