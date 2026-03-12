import Foundation

actor LocalASRRuntimeManager: LocalASRRuntimeManagerProtocol {
    private let logger: LoggingServiceProtocol
    private let runtime: LocalWhisperRuntime

    init(
        logger: LoggingServiceProtocol = LoggingService.shared,
        runtime: LocalWhisperRuntime = .shared
    ) {
        self.logger = logger
        self.runtime = runtime
    }

    func ensureRunning(baseURL: String) async throws {
        _ = baseURL // Local runtime is in-process; endpoint is no longer used.
        do {
            try await runtime.prepare()
            logger.info("Local Whisper runtime is ready")
        } catch {
            logger.error("Failed to prepare local Whisper runtime: \(error)")
            if let asrError = error as? ASRError {
                throw asrError
            }
            throw ASRError.localRuntimeUnavailable(detail: error.localizedDescription)
        }
    }

    func prepareModel(baseURL: String) async throws {
        try await ensureRunning(baseURL: baseURL)
    }

    func stop() async {
        await runtime.stop()
        logger.info("Local Whisper runtime stopped")
    }
}
