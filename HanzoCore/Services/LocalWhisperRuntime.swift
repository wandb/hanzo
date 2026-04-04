import Foundation
import WhisperKit

actor LocalWhisperRuntime: LocalWhisperRuntimeClientProtocol {
    static let shared = LocalWhisperRuntime()

    private struct Session {
        var audioSamples: [Float] = []
        var partialText = ""
        var language = "unknown"
        var partialWindowSeconds = Constants.localWhisperPartialWindowSeconds
        var lastSeenAt = Date()
        var lastPartialDecodeAt = Date.distantPast
        var lastDecodedSampleCount = 0
    }

    private let logger: LoggingServiceProtocol
    private var whisperKit: WhisperKit?
    private var sessions: [String: Session] = [:]
    private var isPreparing = false
    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []
    private var prepareProgressHandlers: [UUID: (Double) -> Void] = [:]
    private var lastPrepareProgress: Double = 0.0

    private init(logger: LoggingServiceProtocol = LoggingService.shared) {
        self.logger = logger
    }

    func prepare() async throws {
        try await prepare(progressHandler: nil)
    }

    func prepare(progressHandler: ((Double) -> Void)?) async throws {
        let progressToken = registerPrepareProgressHandler(progressHandler)
        defer { unregisterPrepareProgressHandler(progressToken) }

        if whisperKit != nil {
            reportPrepareProgress(1.0)
            return
        }

        await waitForInFlightPrepareIfNeeded()
        if whisperKit != nil {
            reportPrepareProgress(1.0)
            return
        }

        isPreparing = true
        defer {
            isPreparing = false
            resumePrepareWaiters()
        }

        let modelsDirectory = modelsDirectoryURL()
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var modelFolder = findExistingModelFolder(
            under: modelsDirectory,
            matchingVariant: Constants.localWhisperModel
        )

        if modelFolder == nil {
            reportPrepareProgress(0.0)
            modelFolder = try await downloadModel(into: modelsDirectory)
        } else {
            reportPrepareProgress(0.9)
        }

        guard var resolvedModelFolder = modelFolder else {
            throw ASRError.localRuntimeUnavailable(detail: "Unable to resolve local Whisper model folder")
        }

        do {
            whisperKit = try await loadRuntimeWithProgress(
                modelFolder: resolvedModelFolder,
                modelsDirectory: modelsDirectory
            )
        } catch {
            logger.warn(
                "Failed to load local Whisper model at \(resolvedModelFolder); " +
                "clearing cache and re-downloading: \(error)"
            )
            purgeCachedModelArtifacts(
                modelFolderPath: resolvedModelFolder,
                under: modelsDirectory
            )

            reportPrepareProgress(0.0)
            resolvedModelFolder = try await downloadModel(into: modelsDirectory)
            whisperKit = try await loadRuntimeWithProgress(
                modelFolder: resolvedModelFolder,
                modelsDirectory: modelsDirectory
            )
        }
    }

    func startSession() async throws -> String {
        cleanupStaleSessions()
        try await prepare()
        let sessionId = UUID().uuidString
        sessions[sessionId] = Session(lastSeenAt: Date())
        return sessionId
    }

    func appendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        cleanupStaleSessions()

        guard var session = sessions[sessionId] else {
            throw ASRError.sessionNotFound
        }
        session.lastSeenAt = Date()

        let chunkSamples = try decodePCMFloat32(pcmData)
        session.audioSamples.append(contentsOf: chunkSamples)

        if shouldDecodePartial(session: session) {
            let decodeWindowSeconds = session.partialWindowSeconds
            let partialInput = partialDecodeInput(
                session.audioSamples,
                windowSeconds: decodeWindowSeconds
            )
            let decodeStartedAt = Date()
            let partial = try await transcribe(
                audioSamples: partialInput,
                isFinal: false
            )
            let decodeDuration = Date().timeIntervalSince(decodeStartedAt)

            session.partialText = partial.text
            session.language = partial.language
            session.lastPartialDecodeAt = Date()
            session.lastDecodedSampleCount = session.audioSamples.count

            let adjustedWindowSeconds = adjustedPartialWindowSeconds(
                currentWindowSeconds: decodeWindowSeconds,
                decodeDuration: decodeDuration
            )
            if adjustedWindowSeconds != decodeWindowSeconds {
                session.partialWindowSeconds = adjustedWindowSeconds
                let bufferedAudioSeconds = Double(session.audioSamples.count) / Constants.audioSampleRate
                let partialInputSeconds = Double(partialInput.count) / Constants.audioSampleRate
                logger.info(
                    "Adjusted local partial decode window to \(String(format: "%.1f", adjustedWindowSeconds))s " +
                    "(decode \(String(format: "%.2f", decodeDuration))s, " +
                    "input \(String(format: "%.1f", partialInputSeconds))s, " +
                    "buffered \(String(format: "%.1f", bufferedAudioSeconds))s)"
                )
            } else if decodeDuration > Constants.localWhisperPartialTargetDecodeSeconds * 2 {
                let bufferedAudioSeconds = Double(session.audioSamples.count) / Constants.audioSampleRate
                let partialInputSeconds = Double(partialInput.count) / Constants.audioSampleRate
                logger.warn(
                    "Local partial decode is slow (\(String(format: "%.2f", decodeDuration))s) " +
                    "at \(String(format: "%.1f", decodeWindowSeconds))s window " +
                    "(input \(String(format: "%.1f", partialInputSeconds))s, " +
                    "buffered \(String(format: "%.1f", bufferedAudioSeconds))s)"
                )
            }
        }

        sessions[sessionId] = session
        return ASRChunkResponse(text: session.partialText, language: session.language)
    }

    func finishSession(sessionId: String) async throws -> ASRFinishResponse {
        cleanupStaleSessions()

        guard let session = sessions.removeValue(forKey: sessionId) else {
            throw ASRError.sessionNotFound
        }

        let final = try await transcribe(audioSamples: session.audioSamples, isFinal: true)
        return ASRFinishResponse(text: final.text, language: final.language)
    }

    func abortSession(sessionId: String) async {
        sessions.removeValue(forKey: sessionId)
    }

    func stop() async {
        sessions.removeAll()
        guard let whisperKit else { return }
        await whisperKit.unloadModels()
        self.whisperKit = nil
        lastPrepareProgress = 0.0
    }

    // MARK: - Private

    private func waitForInFlightPrepareIfNeeded() async {
        while isPreparing {
            await withCheckedContinuation { continuation in
                prepareWaiters.append(continuation)
            }
        }
    }

    private func resumePrepareWaiters() {
        let waiters = prepareWaiters
        prepareWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func registerPrepareProgressHandler(_ handler: ((Double) -> Void)?) -> UUID? {
        guard let handler else { return nil }
        let token = UUID()
        prepareProgressHandlers[token] = handler
        if isPreparing || whisperKit != nil {
            handler(lastPrepareProgress)
        }
        return token
    }

    private func unregisterPrepareProgressHandler(_ token: UUID?) {
        guard let token else { return }
        prepareProgressHandlers.removeValue(forKey: token)
    }

    private func reportPrepareProgress(_ value: Double) {
        let clamped = Self.clamp(value)
        lastPrepareProgress = clamped
        for handler in prepareProgressHandlers.values {
            handler(clamped)
        }
    }

    private func shouldDecodePartial(session: Session) -> Bool {
        let newSampleCount = session.audioSamples.count - session.lastDecodedSampleCount
        let minNewSamples = Int(
            Constants.localWhisperPartialMinSeconds * Constants.audioSampleRate
        )

        guard newSampleCount >= minNewSamples else {
            return false
        }

        let elapsed = Date().timeIntervalSince(session.lastPartialDecodeAt)
        return elapsed >= Constants.localWhisperPartialMinIntervalSeconds
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private func partialDecodeInput(_ audioSamples: [Float], windowSeconds: Double) -> [Float] {
        let windowSamples = Int(windowSeconds * Constants.audioSampleRate)
        guard windowSamples > 0, audioSamples.count > windowSamples else {
            return audioSamples
        }
        return Array(audioSamples.suffix(windowSamples))
    }

    private func adjustedPartialWindowSeconds(
        currentWindowSeconds: Double,
        decodeDuration: TimeInterval
    ) -> Double {
        let targetDecodeSeconds = Constants.localWhisperPartialTargetDecodeSeconds

        if decodeDuration > targetDecodeSeconds * 1.35 {
            return normalizedPartialWindowSeconds(currentWindowSeconds * 0.8)
        }

        if decodeDuration < targetDecodeSeconds * 0.65 {
            return normalizedPartialWindowSeconds(currentWindowSeconds * 1.1)
        }

        return normalizedPartialWindowSeconds(currentWindowSeconds)
    }

    private func normalizedPartialWindowSeconds(_ seconds: Double) -> Double {
        let clamped = min(
            max(seconds, Constants.localWhisperPartialMinWindowSeconds),
            Constants.localWhisperPartialWindowSeconds
        )
        return (clamped * 2).rounded() / 2
    }

    private func transcribe(
        audioSamples: [Float],
        isFinal: Bool
    ) async throws -> (text: String, language: String) {
        guard !audioSamples.isEmpty else {
            return ("", "unknown")
        }

        try await prepare()
        guard let whisperKit else {
            throw ASRError.localRuntimeUnavailable(detail: "Whisper runtime unavailable")
        }

        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            temperature: 0.0,
            withoutTimestamps: true,
            wordTimestamps: false,
            concurrentWorkerCount: 1
        )

        if !isFinal {
            options.usePrefillCache = false
        }

        let results = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: options
        )
        let text = results
            .map { $0.text }
            .joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let language = results.first?.language ?? "unknown"
        return (text, language)
    }

    private func decodePCMFloat32(_ data: Data) throws -> [Float] {
        let sampleSize = MemoryLayout<Float>.size
        guard data.count.isMultiple(of: sampleSize) else {
            throw ASRError.localRuntimeUnavailable(
                detail: "Invalid PCM payload size: \(data.count) bytes"
            )
        }

        let count = data.count / sampleSize
        var samples = Array(repeating: Float.zero, count: count)
        _ = samples.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return samples
    }

    private func cleanupStaleSessions(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Constants.localWhisperSessionTTLSeconds)
        sessions = sessions.filter { _, session in
            session.lastSeenAt >= cutoff
        }
    }

    /// Searches directories under `downloadBase` for a fully-downloaded model folder
    /// for the configured variant (contains AudioEncoder.mlmodelc). Traversal is
    /// directory-only and depth-limited
    /// to avoid scanning every file in large model trees.
    private func findExistingModelFolder(
        under base: URL,
        matchingVariant variant: String
    ) -> String? {
        let fm = FileManager.default
        let maxDepth = 6
        var queue: [(url: URL, depth: Int)] = [(base, 0)]

        while !queue.isEmpty {
            let (url, depth) = queue.removeFirst()
            let audioEncoder = url.appendingPathComponent("AudioEncoder.mlmodelc")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: audioEncoder.path, isDirectory: &isDir), isDir.boolValue {
                if modelFolder(url, matchesVariant: variant) {
                    return url.path
                }
            }

            guard depth < maxDepth else {
                continue
            }

            let children = directoryChildren(of: url, fileManager: fm)
            for child in children {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private func modelFolder(_ url: URL, matchesVariant variant: String) -> Bool {
        let folderName = url.lastPathComponent.lowercased()
        let normalizedVariant = variant.lowercased()
        let hyphenatedVariant = normalizedVariant.replacingOccurrences(of: ".", with: "-")

        return folderName.contains(normalizedVariant) || folderName.contains(hyphenatedVariant)
    }

    private func downloadModel(into modelsDirectory: URL) async throws -> String {
        let maxAttempts = 2

        for attempt in 1...maxAttempts {
            do {
                let downloadedFolder = try await WhisperKit.download(
                    variant: Constants.localWhisperModel,
                    downloadBase: modelsDirectory,
                    from: Constants.localWhisperModelRepository,
                    progressCallback: { [weak self] progress in
                        guard let self else { return }
                        let clamped = Self.clamp(progress.fractionCompleted) * 0.9
                        Task {
                            await self.reportPrepareProgress(clamped)
                        }
                    }
                )
                reportPrepareProgress(0.9)
                return downloadedFolder.path
            } catch {
                logger.warn(
                    "Local Whisper download attempt \(attempt)/\(maxAttempts) failed: \(error)"
                )
                purgeCachedModelArtifacts(
                    modelFolderPath: modelsDirectory
                        .appendingPathComponent(Constants.localWhisperModelRepository)
                        .appendingPathComponent("openai_whisper-\(Constants.localWhisperModel)")
                        .path,
                    under: modelsDirectory
                )

                guard attempt < maxAttempts else {
                    throw error
                }

                reportPrepareProgress(0.0)
            }
        }

        throw ASRError.localRuntimeUnavailable(detail: "Whisper download attempts exhausted")
    }

    private func loadRuntimeWithProgress(
        modelFolder: String,
        modelsDirectory: URL
    ) async throws -> WhisperKit {
        let initialProgress = max(lastPrepareProgress, 0.9)
        reportPrepareProgress(initialProgress)

        let ticker = Task { [weak self] in
            var progress = initialProgress
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                progress = min(progress + 0.004, 0.99)
                guard let self else { continue }
                await self.reportPrepareProgress(progress)
            }
        }

        defer { ticker.cancel() }

        let runtime = try await makeRuntime(
            modelFolder: modelFolder,
            modelsDirectory: modelsDirectory
        )
        reportPrepareProgress(1.0)
        return runtime
    }

    private func makeRuntime(
        modelFolder: String,
        modelsDirectory: URL
    ) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: Constants.localWhisperModel,
            downloadBase: modelsDirectory,
            modelRepo: Constants.localWhisperModelRepository,
            modelFolder: modelFolder,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    private func purgeCachedModelArtifacts(
        modelFolderPath: String,
        under modelsDirectory: URL
    ) {
        let fm = FileManager.default
        let configuredFolderName = "openai_whisper-\(Constants.localWhisperModel)"
        let mirrorFolderName = "whisper-\(Constants.localWhisperModel)"
        let repoRoot = modelsDirectory.appendingPathComponent(Constants.localWhisperModelRepository)

        let cleanupTargets: [URL] = [
            URL(fileURLWithPath: modelFolderPath),
            repoRoot.appendingPathComponent(configuredFolderName),
            repoRoot.appendingPathComponent(".cache/huggingface/download/\(configuredFolderName)"),
            modelsDirectory.appendingPathComponent("openai/\(mirrorFolderName)")
        ]

        for target in cleanupTargets where fm.fileExists(atPath: target.path) {
            do {
                try fm.removeItem(at: target)
            } catch {
                logger.warn("Failed to remove stale Whisper artifact at \(target.path): \(error)")
            }
        }
    }

    private func directoryChildren(of base: URL, fileManager: FileManager) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var directories: [URL] = []
        for child in children {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                continue
            }
            directories.append(child)
        }
        return directories
    }

    private func modelsDirectoryURL() -> URL {
        LocalModelPaths.modelsRoot()
    }
}
