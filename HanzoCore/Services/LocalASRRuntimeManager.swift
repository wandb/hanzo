import Foundation

actor LocalASRRuntimeManager: LocalASRRuntimeManagerProtocol {
    private let logger: LoggingServiceProtocol
    private let session: URLSession
    private var helperProcess: Process?
    private var helperStdErrPipe: Pipe?
    private var launchedPreset: LocalASRModelPreset?

    init(
        logger: LoggingServiceProtocol = LoggingService.shared,
        session: URLSession = .shared
    ) {
        self.logger = logger
        self.session = session
    }

    func ensureRunning(baseURL: String) async throws {
        guard let endpoint = URL(string: baseURL) else {
            throw ASRError.invalidURL
        }

        let healthURL = endpoint
            .appending(path: Constants.localRuntimeHealthPath)

        let preset = currentPreset()
        if launchedPreset != preset {
            await stop()
        }

        if await isHealthy(healthURL) {
            return
        }

        try startBundledHelperIfNeeded(endpoint: endpoint, preset: preset)

        let deadline = Date().addingTimeInterval(Constants.localRuntimeStartupTimeout)
        while Date() < deadline {
            if await isHealthy(healthURL) {
                logger.info("Local ASR runtime healthy: \(healthURL.absoluteString)")
                return
            }
            try? await Task.sleep(nanoseconds: Constants.localRuntimeHealthPollNanoseconds)
        }

        throw ASRError.localRuntimeUnavailable(
            detail: unavailableDetail(healthURL: healthURL)
        )
    }

    func stop() async {
        guard let helperProcess else { return }
        if helperProcess.isRunning {
            helperProcess.terminate()
            logger.info("Stopped local ASR runtime helper")
        }
        self.helperProcess = nil
        helperStdErrPipe = nil
        launchedPreset = nil
    }

    func prepareModel(baseURL: String) async throws {
        guard let endpoint = URL(string: baseURL + Constants.localModelPreparePath) else {
            throw ASRError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ASRError.localRuntimeUnavailable(
                    detail: "Invalid response while preparing local model"
                )
            }
            guard (200...299).contains(http.statusCode) else {
                throw ASRError.localRuntimeUnavailable(
                    detail: "Failed to prepare local model (HTTP \(http.statusCode))"
                )
            }
        } catch {
            if let asrError = error as? ASRError {
                throw asrError
            }
            throw ASRError.networkError(underlying: error)
        }
    }

    // MARK: - Private

    private func isHealthy(_ healthURL: URL) async -> Bool {
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func startBundledHelperIfNeeded(endpoint: URL, preset: LocalASRModelPreset) throws {
        if helperProcess?.isRunning == true {
            return
        }
        helperProcess = nil

        let helperURL = Bundle.main.bundleURL
            .appending(path: "Contents")
            .appending(path: "Helpers")
            .appending(path: Constants.localRuntimeHelperExecutableName)

        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ASRError.localRuntimeUnavailable(
                detail: "Bundled helper missing at \(helperURL.path)"
            )
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--host", endpoint.host ?? "127.0.0.1",
            "--port", String(endpoint.port ?? 8765),
            "--preset", preset.rawValue,
            "--models-dir", modelsDirectoryURL().path,
        ]
        process.standardOutput = Pipe()
        let stdErrPipe = Pipe()
        process.standardError = stdErrPipe

        do {
            try process.run()
            helperProcess = process
            helperStdErrPipe = stdErrPipe
            launchedPreset = preset
            logger.info("Started local ASR runtime helper: \(helperURL.path)")
        } catch {
            throw ASRError.localRuntimeUnavailable(
                detail: "Failed to start bundled helper (\(error.localizedDescription))"
            )
        }
    }

    private func currentPreset() -> LocalASRModelPreset {
        if let raw = UserDefaults.standard.string(forKey: Constants.localASRModelPresetKey),
           let preset = LocalASRModelPreset(rawValue: raw) {
            return preset
        }
        return Constants.defaultLocalASRModelPreset
    }

    private func modelsDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(Constants.bundleIdentifier)
            .appendingPathComponent(Constants.localModelsFolderName)
    }

    private func unavailableDetail(healthURL: URL) -> String {
        if let helperProcess, !helperProcess.isRunning,
           let helperStdErrPipe {
            let data = helperStdErrPipe.fileHandleForReading.availableData
            if let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return "Local runtime failed to start: \(output)"
            }
        }
        return "No healthy runtime at \(healthURL.absoluteString)"
    }
}
