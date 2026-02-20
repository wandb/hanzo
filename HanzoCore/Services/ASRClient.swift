import Foundation

struct ASRStreamStartResponse: Decodable {
    let session_id: String
}

struct ASRChunkResponse: Decodable {
    let text: String
    let language: String
}

struct ASRFinishResponse: Decodable {
    let text: String
    let language: String
}

enum ASRError: Error, LocalizedError {
    case serverError(statusCode: Int, detail: String?)
    case authenticationFailed
    case sessionNotFound
    case networkError(underlying: Error)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .serverError(let code, let detail):
            return "Server error (HTTP \(code))\(detail.map { ": \($0)" } ?? "")"
        case .authenticationFailed:
            return "Invalid API key"
        case .sessionNotFound:
            return "Streaming session not found"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .invalidURL:
            return "Invalid server URL"
        }
    }
}

final class ASRClient: ASRClientProtocol {
    private let session: URLSession
    var baseURL: String
    var apiKey: String

    init(baseURL: String, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    func startStream() async throws -> String {
        let request = try makeRequest(path: "/v1/stream/start")
        let (data, response) = try await performRequest(request)
        try checkResponse(response)
        let decoded = try JSONDecoder().decode(ASRStreamStartResponse.self, from: data)
        return decoded.session_id
    }

    func sendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        var request = try makeRequest(
            path: "/v1/stream/chunk",
            queryItems: [URLQueryItem(name: "session_id", value: sessionId)]
        )
        request.httpBody = pcmData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await performRequest(request)
        try checkResponse(response)
        return try JSONDecoder().decode(ASRChunkResponse.self, from: data)
    }

    func finishStream(sessionId: String) async throws -> ASRFinishResponse {
        let request = try makeRequest(
            path: "/v1/stream/finish",
            queryItems: [URLQueryItem(name: "session_id", value: sessionId)]
        )
        let (data, response) = try await performRequest(request)
        try checkResponse(response)
        return try JSONDecoder().decode(ASRFinishResponse.self, from: data)
    }

    // MARK: - Private

    private func makeRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
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
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 15
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ASRError.networkError(underlying: error)
        }
    }

    private func checkResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw ASRError.authenticationFailed
        case 404:
            throw ASRError.sessionNotFound
        default:
            throw ASRError.serverError(statusCode: httpResponse.statusCode, detail: nil)
        }
    }
}
