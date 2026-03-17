import Foundation

struct ASRCapabilitiesLimits: Decodable {
    let max_chunk_bytes: Int
}

struct ASRCapabilitiesResponse: Decodable {
    let api_version: Int
    let limits: ASRCapabilitiesLimits
}

struct ASRStreamStartResponse: Decodable {
    let session_id: String
}

struct ASRStreamStartAudioRequest: Encodable {
    let encoding: String
    let sample_rate_hz: Int
    let channels: Int
}

struct ASRStreamStartRequest: Encodable {
    let audio: ASRStreamStartAudioRequest
}

struct ASRChunkResponse: Decodable {
    let text: String
    let language: String
}

struct ASRFinishResponse: Decodable {
    let text: String
    let language: String
}

struct ASRServerErrorPayload: Decodable {
    let code: String
    let message: String
    let retryable: Bool
}

struct ASRServerErrorResponse: Decodable {
    let error: ASRServerErrorPayload
}

enum ASRError: Error, LocalizedError {
    case serverError(statusCode: Int, detail: String?)
    case authenticationFailed
    case sessionNotFound
    case networkError(underlying: Error)
    case invalidURL
    case unsupportedAPIVersion(received: Int)
    case invalidCapabilities(detail: String?)
    case chunkExceedsLimit(maxBytes: Int, actualBytes: Int)
    case localRuntimeUnavailable(detail: String?)

    var errorDescription: String? {
        switch self {
        case .serverError(let code, let detail):
            return "Server error (HTTP \(code))\(detail.map { ": \($0)" } ?? "")"
        case .authenticationFailed:
            return "Authentication failed. Check custom server password."
        case .sessionNotFound:
            return "Streaming session not found"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .invalidURL:
            return "Invalid server URL"
        case .unsupportedAPIVersion(let received):
            return "Unsupported ASR API version \(received). Hanzo requires version \(ASRClient.supportedAPIVersion). Update server settings."
        case .invalidCapabilities(let detail):
            return detail ?? "Invalid ASR capabilities response"
        case .chunkExceedsLimit(let maxBytes, let actualBytes):
            return "Audio chunk too large (\(actualBytes) bytes). Server limit is \(maxBytes) bytes."
        case .localRuntimeUnavailable(let detail):
            return detail ?? "Local ASR runtime is unavailable"
        }
    }
}

final class ASRClient: ASRClientProtocol {
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let requiresCapabilitiesHandshake: Bool
    var baseURL: String {
        didSet {
            if oldValue != baseURL {
                capabilities = nil
            }
        }
    }
    var apiKey: String {
        didSet {
            if oldValue != apiKey {
                capabilities = nil
            }
        }
    }
    private var capabilities: ASRCapabilitiesResponse?

    static let supportedAPIVersion = 1

    init(
        baseURL: String,
        apiKey: String,
        requestTimeout: TimeInterval = 15,
        requiresCapabilitiesHandshake: Bool = true,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.requiresCapabilitiesHandshake = requiresCapabilitiesHandshake
        self.session = session
    }

    func startStream() async throws -> String {
        if requiresCapabilitiesHandshake {
            try await ensureSupportedCapabilities()
        }

        var request = try makeRequest(path: "/v1/stream/start")
        let startPayload = ASRStreamStartRequest(
            audio: ASRStreamStartAudioRequest(
                encoding: "pcm_f32le",
                sample_rate_hz: Int(Constants.audioSampleRate),
                channels: Int(Constants.audioChannels)
            )
        )
        request.httpBody = try JSONEncoder().encode(startPayload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await performRequest(request)
        try checkResponse(data: data, response: response, map404ToSessionNotFound: false)
        let decoded = try JSONDecoder().decode(ASRStreamStartResponse.self, from: data)
        return decoded.session_id
    }

    func sendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        let maxChunkBytes = capabilities?.limits.max_chunk_bytes ?? Constants.defaultMaxChunkBytes
        guard pcmData.count <= maxChunkBytes else {
            throw ASRError.chunkExceedsLimit(maxBytes: maxChunkBytes, actualBytes: pcmData.count)
        }

        var request = try makeRequest(
            path: "/v1/stream/chunk",
            queryItems: [URLQueryItem(name: "session_id", value: sessionId)]
        )
        request.httpBody = pcmData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await performRequest(request)
        try checkResponse(data: data, response: response, map404ToSessionNotFound: true)
        return try JSONDecoder().decode(ASRChunkResponse.self, from: data)
    }

    func finishStream(sessionId: String) async throws -> ASRFinishResponse {
        let request = try makeRequest(
            path: "/v1/stream/finish",
            queryItems: [URLQueryItem(name: "session_id", value: sessionId)]
        )
        let (data, response) = try await performRequest(request)
        try checkResponse(data: data, response: response, map404ToSessionNotFound: true)
        return try JSONDecoder().decode(ASRFinishResponse.self, from: data)
    }

    // MARK: - Private

    private func makeRequest(
        path: String,
        method: String = "POST",
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL + path) else {
            throw ASRError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw ASRError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = requestTimeout
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ASRError.networkError(underlying: error)
        }
    }

    private func checkResponse(
        data: Data,
        response: URLResponse,
        map404ToSessionNotFound: Bool
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw ASRError.authenticationFailed
        case 404 where map404ToSessionNotFound:
            throw ASRError.sessionNotFound
        default:
            let detail = serverErrorDetail(from: data)
            throw ASRError.serverError(statusCode: httpResponse.statusCode, detail: detail)
        }
    }

    private func ensureSupportedCapabilities() async throws {
        if let capabilities {
            try validateCapabilities(capabilities)
            return
        }

        let request = try makeRequest(path: "/v1/capabilities", method: "GET")
        let (data, response) = try await performRequest(request)
        try checkResponse(data: data, response: response, map404ToSessionNotFound: false)

        let decoded: ASRCapabilitiesResponse
        do {
            decoded = try JSONDecoder().decode(ASRCapabilitiesResponse.self, from: data)
        } catch {
            throw ASRError.invalidCapabilities(detail: "Could not decode capabilities response")
        }

        try validateCapabilities(decoded)
        capabilities = decoded
    }

    private func validateCapabilities(_ capabilities: ASRCapabilitiesResponse) throws {
        guard capabilities.api_version == Self.supportedAPIVersion else {
            throw ASRError.unsupportedAPIVersion(received: capabilities.api_version)
        }

        guard capabilities.limits.max_chunk_bytes > 0 else {
            throw ASRError.invalidCapabilities(detail: "Capabilities `limits.max_chunk_bytes` must be positive")
        }
    }

    private func serverErrorDetail(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(ASRServerErrorResponse.self, from: data) {
            return "[\(decoded.error.code)] \(decoded.error.message)"
        }

        if let stringBody = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stringBody.isEmpty {
            return stringBody
        }

        return nil
    }
}
