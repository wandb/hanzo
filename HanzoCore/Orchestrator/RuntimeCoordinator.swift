import Foundation

/// Coordinates the lifecycle of the local ASR (Whisper) and local LLM runtimes:
/// prewarm at launch, warm while a session is active, cool when idle, and abort
/// in-flight local ASR sessions on cancel. Keeps the generation-counter
/// bookkeeping that lets rapid warm/cool toggles collapse into a single action.
final class RuntimeCoordinator {
    private let localASRRuntimeManager: LocalASRRuntimeManagerProtocol
    private let localLLMRuntimeManager: LocalLLMRuntimeManagerProtocol
    private let logger: LoggingServiceProtocol

    private let llmRuntimeControlQueue = DispatchQueue(label: "com.hanzo.llm-runtime-control")
    private var llmRuntimeDesired = false
    private var llmRuntimeGeneration = 0

    init(
        localASRRuntimeManager: LocalASRRuntimeManagerProtocol,
        localLLMRuntimeManager: LocalLLMRuntimeManagerProtocol,
        logger: LoggingServiceProtocol
    ) {
        self.localASRRuntimeManager = localASRRuntimeManager
        self.localLLMRuntimeManager = localLLMRuntimeManager
        self.logger = logger
    }

    func prewarmLocalASRIfNeeded(provider: ASRProvider) {
        guard provider == .local else { return }
        let runtimeManager = localASRRuntimeManager
        let logger = logger
        Task.launched(name: "prewarm-local-whisper", logger: logger) {
            try await runtimeManager.prepareModel()
            logger.info("Local Whisper runtime prewarmed at launch")
        }
    }

    func warmLLMRuntime(reason: String) {
        updateLLMRuntime(desiredRunning: true, reason: reason)
    }

    func coolLLMRuntime(reason: String) {
        updateLLMRuntime(desiredRunning: false, reason: reason)
    }

    func abortLocalASRSessionIfNeeded(sessionId: String?, asrClient: ASRClientProtocol) {
        guard let sessionId,
              let localClient = asrClient as? LocalWhisperASRClient else {
            return
        }
        Task {
            await localClient.abortStream(sessionId: sessionId)
        }
    }

    func stopAllRuntimesForShutdown() async {
        await localASRRuntimeManager.stop()
        await localLLMRuntimeManager.stop()
    }

    func stopLocalASRRuntime() async {
        await localASRRuntimeManager.stop()
    }

    func prepareLocalASRModel() async throws {
        try await localASRRuntimeManager.prepareModel()
    }

    func localLLMPostProcess(
        text: String,
        prompt: String,
        targetApp: String?,
        commonTerms: [String]
    ) async throws -> String {
        try await localLLMRuntimeManager.postProcess(
            text: text,
            prompt: prompt,
            targetApp: targetApp,
            commonTerms: commonTerms
        )
    }

    private func updateLLMRuntime(desiredRunning: Bool, reason: String) {
        logger.info(
            desiredRunning
                ? "Requesting local LLM runtime warmup for \(reason)"
                : "Requesting local LLM runtime cooldown for \(reason)"
        )

        let generation = llmRuntimeControlQueue.sync {
            llmRuntimeDesired = desiredRunning
            llmRuntimeGeneration += 1
            return llmRuntimeGeneration
        }

        Task { [weak self] in
            await self?.syncLLMRuntime(
                desiredRunning: desiredRunning,
                generation: generation,
                reason: reason
            )
        }
    }

    private func syncLLMRuntime(
        desiredRunning: Bool,
        generation: Int,
        reason: String
    ) async {
        guard isCurrentLLMRuntimeRequest(
            generation: generation,
            desiredRunning: desiredRunning
        ) else {
            return
        }

        if desiredRunning {
            do {
                try await localLLMRuntimeManager.prepareModel()
                if isCurrentLLMRuntimeRequest(
                    generation: generation,
                    desiredRunning: desiredRunning
                ) {
                    logger.info("Local LLM runtime warmed for \(reason)")
                    return
                }

                if !isLLMRuntimeDesired() {
                    await localLLMRuntimeManager.stop()
                }
            } catch {
                if isCurrentLLMRuntimeRequest(
                    generation: generation,
                    desiredRunning: desiredRunning
                ) {
                    logger.warn("Failed to warm local LLM runtime for \(reason): \(error)")
                }
            }
            return
        }

        logger.info("Cooling local LLM runtime after \(reason)")
        await localLLMRuntimeManager.stop()
    }

    private func isCurrentLLMRuntimeRequest(
        generation: Int,
        desiredRunning: Bool
    ) -> Bool {
        llmRuntimeControlQueue.sync {
            llmRuntimeGeneration == generation && llmRuntimeDesired == desiredRunning
        }
    }

    private func isLLMRuntimeDesired() -> Bool {
        llmRuntimeControlQueue.sync { llmRuntimeDesired }
    }
}
