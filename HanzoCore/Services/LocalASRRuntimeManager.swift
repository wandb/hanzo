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
        try await ensureRunning(baseURL: baseURL, preset: nil)
    }

    func ensureRunning(baseURL: String, preset requestedPreset: LocalASRModelPreset?) async throws {
        guard let endpoint = URL(string: baseURL) else {
            throw ASRError.invalidURL
        }

        let healthURL = endpoint
            .appending(path: Constants.localRuntimeHealthPath)

        let preset = requestedPreset ?? currentPreset()

        if let health = await healthStatus(healthURL),
           health.matchesPreset(preset) {
            return
        }

        if let health = await healthStatus(healthURL),
           !health.matchesPreset(preset) {
            await stop()
            try terminateStaleHelperIfNeeded(endpoint: endpoint)
        } else if launchedPreset != preset {
            await stop()
        }

        if let health = await healthStatus(healthURL),
           health.matchesPreset(preset) {
            return
        }

        try startBundledHelperIfNeeded(endpoint: endpoint, preset: preset)

        let deadline = Date().addingTimeInterval(Constants.localRuntimeStartupTimeout)
        while Date() < deadline {
            if let health = await healthStatus(healthURL),
               health.matchesPreset(preset) {
                logger.info("Local ASR runtime healthy: \(healthURL.absoluteString)")
                return
            }
            try? await Task.sleep(nanoseconds: Constants.localRuntimeHealthPollNanoseconds)
        }

        if let health = await healthStatus(healthURL),
           let runningPreset = health.preset,
           runningPreset != preset.rawValue {
            throw ASRError.localRuntimeUnavailable(
                detail: "Runtime preset mismatch at \(healthURL.absoluteString): expected \(preset.rawValue), got \(runningPreset)"
            )
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

    private func healthStatus(_ healthURL: URL) async -> RuntimeHealthResponse? {
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }
            return try? JSONDecoder().decode(RuntimeHealthResponse.self, from: data)
        } catch {
            return nil
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

    private func terminateStaleHelperIfNeeded(endpoint: URL) throws {
        guard isLocalHost(endpoint.host) else { return }
        let port = endpoint.port ?? 8765
        let pids = try listeningPIDs(on: port)
        if pids.isEmpty { return }

        for pid in pids {
            guard isHanzoHelperProcess(pid: pid) else { continue }
            try terminateProcess(pid: pid)
            logger.info("Terminated stale HanzoLocalASR process pid=\(pid) on port \(port)")
        }
    }

    private func listeningPIDs(on port: Int) throws -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        return raw
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func isHanzoHelperProcess(pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let command = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return false
        }

        return command.contains(Constants.localRuntimeHelperExecutableName)
            || command.contains("HanzoLocalASR.py")
    }

    private func terminateProcess(pid: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-TERM", String(pid)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    private func isLocalHost(_ host: String?) -> Bool {
        guard let normalized = host?.lowercased() else { return false }
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }
}

private struct RuntimeHealthResponse: Decodable {
    let preset: String?

    func matchesPreset(_ expected: LocalASRModelPreset) -> Bool {
        guard let preset else { return true }
        return preset == expected.rawValue
    }
}
