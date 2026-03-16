import Foundation

private final class DownloadTaskState: @unchecked Sendable {
    var task: URLSessionDownloadTask?
    var progressTask: Task<Void, Never>?
}

enum LocalLLMRuntimeError: Error, LocalizedError {
    case executableNotFound
    case modelDownloadFailed(detail: String)
    case processLaunchFailed(detail: String)
    case requestFailed(detail: String)
    case serverNotReady
    case invalidServerResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Could not find llama-server executable."
        case .modelDownloadFailed(let detail):
            return "Failed to download local LLM model: \(detail)"
        case .processLaunchFailed(let detail):
            return "Failed to launch local LLM runtime: \(detail)"
        case .requestFailed(let detail):
            return "Local LLM request failed: \(detail)"
        case .serverNotReady:
            return "Local LLM runtime did not become ready in time."
        case .invalidServerResponse:
            return "Local LLM runtime returned an invalid response."
        }
    }
}

actor LocalLLMRuntimeManager: LocalLLMRuntimeManagerProtocol {
    static let shared = LocalLLMRuntimeManager()

    private let logger: LoggingServiceProtocol
    private let fileManager: FileManager
    private let inferenceSession: URLSession
    private let modelDownloadSession: URLSession

    private var serverProcess: Process?
    private var isStartingRuntime = false
    private var isDownloadingModel = false
    private var isPrimingInference = false
    private var hasPrimedInference = false

    init(
        logger: LoggingServiceProtocol = LoggingService.shared,
        fileManager: FileManager = .default
    ) {
        self.logger = logger
        self.fileManager = fileManager

        let inferenceConfig = URLSessionConfiguration.default
        inferenceConfig.timeoutIntervalForRequest = Constants.localLLMRequestTimeoutSeconds
        inferenceConfig.timeoutIntervalForResource = Constants.localLLMRequestTimeoutSeconds
        self.inferenceSession = URLSession(configuration: inferenceConfig)

        let downloadConfig = URLSessionConfiguration.default
        downloadConfig.timeoutIntervalForRequest = 60
        downloadConfig.timeoutIntervalForResource = 60 * 60 * 24
        self.modelDownloadSession = URLSession(configuration: downloadConfig)
    }

    func ensureRunning() async throws {
        try await ensureRunning(progressHandler: nil)
    }

    func ensureRunning(progressHandler: ((Double) -> Void)?) async throws {
        if let serverProcess, serverProcess.isRunning {
            if await isServerReady() {
                progressHandler?(1.0)
                await ensureInferencePrimed()
                return
            }
            await stop()
        }

        if isStartingRuntime {
            try await waitForRuntimeStartup()
            if let serverProcess, serverProcess.isRunning, await isServerReady() {
                progressHandler?(1.0)
                await ensureInferencePrimed()
                return
            }
        }

        isStartingRuntime = true
        defer { isStartingRuntime = false }

        let executableURL = try resolveLlamaServerExecutableURL()
        let modelURL = try await ensureModelIsAvailable(progressHandler: progressHandler)
        try launchServer(executableURL: executableURL, modelURL: modelURL)
        try await waitForServerReady()
        progressHandler?(1.0)
        logger.info("Local LLM runtime is ready")
        await ensureInferencePrimed()
    }

    func prepareModel() async throws {
        try await prepareModel(progressHandler: nil)
    }

    func prepareModel(progressHandler: ((Double) -> Void)?) async throws {
        try await ensureRunning(progressHandler: progressHandler)
    }

    func downloadModelIfNeeded(progressHandler: ((Double) -> Void)? = nil) async throws {
        _ = try await ensureModelIsAvailable(progressHandler: progressHandler)
    }

    func postProcess(text: String, prompt: String) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }

        try await ensureRunning()

        let rewritten = try await requestRewrite(transcript: trimmedText, userPrompt: prompt)
        let cleaned = sanitizeModelResponse(rewritten)
        return cleaned.isEmpty ? trimmedText : cleaned
    }

    func stop() async {
        guard let serverProcess else { return }

        if serverProcess.isRunning {
            serverProcess.terminate()
            for _ in 0..<20 {
                if !serverProcess.isRunning {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        if serverProcess.isRunning {
            serverProcess.interrupt()
        }

        self.serverProcess = nil
        self.isPrimingInference = false
        self.hasPrimedInference = false
        logger.info("Local LLM runtime stopped")
    }

    // MARK: - Runtime Launch

    private func resolveLlamaServerExecutableURL() throws -> URL {
        var candidates: [String] = []

        let defaults = UserDefaults.standard
        if let overridePath = defaults.string(forKey: Constants.localLLMServerExecutableOverrideKey),
           !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(overridePath)
        }

        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append((executableDir as NSString).appendingPathComponent(Constants.localLLMServerExecutableName))
            candidates.append(
                URL(fileURLWithPath: executableDir)
                    .appendingPathComponent("llama-runtime")
                    .appendingPathComponent(Constants.localLLMServerExecutableName)
                    .path
            )
        }
        if let resourceDir = Bundle.main.resourceURL?.path {
            candidates.append((resourceDir as NSString).appendingPathComponent(Constants.localLLMServerExecutableName))
            candidates.append(
                URL(fileURLWithPath: resourceDir)
                    .appendingPathComponent("llama-runtime")
                    .appendingPathComponent(Constants.localLLMServerExecutableName)
                    .path
            )
        }

        candidates.append("/opt/homebrew/bin/\(Constants.localLLMServerExecutableName)")
        candidates.append("/usr/local/bin/\(Constants.localLLMServerExecutableName)")

        for candidate in candidates {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw LocalLLMRuntimeError.executableNotFound
    }

    private func launchServer(executableURL: URL, modelURL: URL) throws {
        let threadCount = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-m", modelURL.path,
            "--host", Constants.localLLMServerHost,
            "--port", String(Constants.localLLMServerPort),
            "-c", String(Constants.localLLMModelContextSize),
            "-ngl", String(Constants.localLLMServerGPULayers),
            "--threads", String(threadCount),
            "--threads-batch", String(threadCount)
        ]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [logger] terminatedProcess in
            logger.warn("Local LLM runtime exited with code \(terminatedProcess.terminationStatus)")
        }

        do {
            try process.run()
        } catch {
            throw LocalLLMRuntimeError.processLaunchFailed(detail: error.localizedDescription)
        }

        self.serverProcess = process
    }

    private func waitForServerReady() async throws {
        for _ in 0..<60 {
            if Task.isCancelled {
                throw CancellationError()
            }

            if await isServerReady() {
                return
            }

            if let serverProcess, !serverProcess.isRunning {
                throw LocalLLMRuntimeError.processLaunchFailed(detail: "llama-server exited before becoming ready")
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        throw LocalLLMRuntimeError.serverNotReady
    }

    private func isServerReady() async -> Bool {
        let endpoints = ["/health", "/v1/models"]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint, relativeTo: serverBaseURL()) else {
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 0.5

            do {
                let (_, response) = try await inferenceSession.data(for: request)
                if let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }

    // MARK: - Model Management

    private func ensureModelIsAvailable(
        progressHandler: ((Double) -> Void)?
    ) async throws -> URL {
        let modelDir = modelsDirectoryURL()
        try fileManager.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let modelURL = modelDir.appendingPathComponent(Constants.localLLMModelFileName)
        if fileManager.fileExists(atPath: modelURL.path) {
            progressHandler?(1.0)
            return modelURL
        }

        if isDownloadingModel {
            try await waitForModelDownload(modelURL: modelURL)
            progressHandler?(1.0)
            return modelURL
        }

        isDownloadingModel = true
        defer { isDownloadingModel = false }

        guard let remoteURL = URL(string: remoteModelURLString()) else {
            throw LocalLLMRuntimeError.modelDownloadFailed(detail: "Invalid model URL")
        }

        logger.info("Downloading local LLM model: \(Constants.localLLMModelFileName)")

        do {
            progressHandler?(0.0)
            let fallbackExpectedBytes = await resolveExpectedDownloadBytes(for: remoteURL)
            let (tempURL, response) = try await downloadModelFile(
                from: remoteURL,
                fallbackExpectedBytes: fallbackExpectedBytes,
                progressHandler: progressHandler
            )
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw LocalLLMRuntimeError.modelDownloadFailed(detail: "HTTP \(http.statusCode)")
            }

            let partialURL = modelURL.appendingPathExtension("part")
            if fileManager.fileExists(atPath: partialURL.path) {
                try fileManager.removeItem(at: partialURL)
            }
            if fileManager.fileExists(atPath: modelURL.path) {
                try fileManager.removeItem(at: modelURL)
            }

            try fileManager.moveItem(at: tempURL, to: partialURL)
            try fileManager.moveItem(at: partialURL, to: modelURL)
            progressHandler?(1.0)
            logger.info("Local LLM model download complete")
            return modelURL
        } catch {
            if let localError = error as? LocalLLMRuntimeError {
                throw localError
            }
            throw LocalLLMRuntimeError.modelDownloadFailed(detail: error.localizedDescription)
        }
    }

    private func waitForRuntimeStartup() async throws {
        while isStartingRuntime {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitForModelDownload(modelURL: URL) async throws {
        while isDownloadingModel {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw LocalLLMRuntimeError.modelDownloadFailed(detail: "Model download did not complete")
        }
    }

    private func remoteModelURLString() -> String {
        let repo = Constants.localLLMModelRepository
        let file = Constants.localLLMModelFileName
        return "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true"
    }

    private func resolveExpectedDownloadBytes(for remoteURL: URL) async -> Int64 {
        if let remoteSize = await fetchRemoteDownloadSize(from: remoteURL), remoteSize > 0 {
            return remoteSize
        }
        return Constants.localLLMModelExpectedDownloadBytes
    }

    private func fetchRemoteDownloadSize(from remoteURL: URL) async -> Int64? {
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "HEAD"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        do {
            let (_, response) = try await modelDownloadSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return nil
            }

            if let linkedSize = Self.int64HeaderValue("x-linked-size", in: http), linkedSize > 0 {
                return linkedSize
            }
            if let contentLength = Self.int64HeaderValue("content-length", in: http), contentLength > 0 {
                return contentLength
            }
        } catch {
            logger.warn("Could not resolve local LLM model size: \(error)")
        }

        return nil
    }

    private func downloadModelFile(
        from remoteURL: URL,
        fallbackExpectedBytes: Int64,
        progressHandler: ((Double) -> Void)?
    ) async throws -> (URL, URLResponse) {
        let state = DownloadTaskState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = modelDownloadSession.downloadTask(with: remoteURL) { tempURL, response, error in
                    state.progressTask?.cancel()

                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let tempURL, let response else {
                        continuation.resume(
                            throwing: LocalLLMRuntimeError.modelDownloadFailed(
                                detail: "Download did not return a model file"
                            )
                        )
                        return
                    }

                    continuation.resume(returning: (tempURL, response))
                }

                state.task = task
                state.progressTask = Task { [weak task] in
                    while !Task.isCancelled {
                        guard let task else { return }

                        let receivedBytes = max(task.countOfBytesReceived, 0)
                        let expectedBytes = task.countOfBytesExpectedToReceive > 0
                            ? task.countOfBytesExpectedToReceive
                            : fallbackExpectedBytes

                        if expectedBytes > 0 {
                            let fraction = Self.clamp(Double(receivedBytes) / Double(expectedBytes))
                            progressHandler?(fraction)
                        }

                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                }

                task.resume()
            }
        } onCancel: {
            state.progressTask?.cancel()
            state.task?.cancel()
        }
    }

    private static func int64HeaderValue(_ header: String, in response: HTTPURLResponse) -> Int64? {
        for (key, value) in response.allHeaderFields {
            guard let keyString = key as? String,
                  keyString.caseInsensitiveCompare(header) == .orderedSame else {
                continue
            }

            if let stringValue = value as? String, let intValue = Int64(stringValue) {
                return intValue
            }
            if let numberValue = value as? NSNumber {
                return numberValue.int64Value
            }
        }

        return nil
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private func modelsDirectoryURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(Constants.bundleIdentifier)
            .appendingPathComponent(Constants.localModelsFolderName)
            .appendingPathComponent(Constants.localLLMModelsSubfolderName)
    }

    // MARK: - Inference

    private struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let maxTokens: Int
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
            case stream
        }
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private func requestRewrite(transcript: String, userPrompt: String) async throws -> String {
        guard let url = URL(string: "/v1/chat/completions", relativeTo: serverBaseURL()) else {
            throw LocalLLMRuntimeError.invalidServerResponse
        }

        let prompt = TranscriptRewritePrompt.render(
            transcript: transcript,
            userPrompt: userPrompt
        )

        let maxTokens = rewriteMaxTokens(for: transcript)

        let requestBody = ChatCompletionRequest(
            model: "qwen3-4b",
            messages: [
                ChatMessage(role: "system", content: prompt.system),
                ChatMessage(role: "user", content: "/no_think\n" + prompt.user)
            ],
            temperature: 0.2,
            maxTokens: maxTokens,
            stream: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await inferenceSession.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw LocalLLMRuntimeError.requestFailed(detail: detail)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw LocalLLMRuntimeError.invalidServerResponse
        }
        return content
    }

    private func sanitizeModelResponse(_ response: String) -> String {
        let withoutThinkTags = response.replacingOccurrences(
            of: #"(?s)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )

        let withoutControlTokens = withoutThinkTags
            .replacingOccurrences(of: "/no_think", with: "")
            .replacingOccurrences(of: "/think", with: "")

        return withoutControlTokens.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rewriteMaxTokens(for transcript: String) -> Int {
        let estimatedInputTokens = max(16, transcript.count / 4)
        let budget = estimatedInputTokens + 64
        return min(256, max(96, budget))
    }

    private func ensureInferencePrimed() async {
        if hasPrimedInference {
            return
        }

        if isPrimingInference {
            await waitForInferencePriming()
            return
        }

        isPrimingInference = true
        defer { isPrimingInference = false }

        let start = Date()

        do {
            _ = try await requestRewrite(
                transcript: "Test transcript.",
                userPrompt: "Return this transcript unchanged."
            )
            hasPrimedInference = true
            let duration = Date().timeIntervalSince(start)
            logger.info("Local LLM inference primed (\(String(format: "%.2f", duration))s)")
        } catch {
            logger.warn("Failed to prime local LLM inference: \(error)")
        }
    }

    private func waitForInferencePriming() async {
        while isPrimingInference {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func serverBaseURL() -> URL {
        URL(string: "http://\(Constants.localLLMServerHost):\(Constants.localLLMServerPort)")!
    }
}
