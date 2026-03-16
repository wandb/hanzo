import Foundation
import WhisperKit

actor LocalWhisperRuntime: LocalWhisperRuntimeClientProtocol {
    static let shared = LocalWhisperRuntime()

    private struct Session {
        var audioSamples: [Float] = []
        var partialText = ""
        var language = "unknown"
        var lastSeenAt = Date()
        var lastPartialDecodeAt = Date.distantPast
        var lastDecodedSampleCount = 0
    }

    private var whisperKit: WhisperKit?
    private var sessions: [String: Session] = [:]

    func prepare() async throws {
        try await prepare(progressHandler: nil)
    }

    func prepare(progressHandler: ((Double) -> Void)?) async throws {
        if whisperKit != nil {
            progressHandler?(1.0)
            return
        }

        let modelsDirectory = modelsDirectoryURL()
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let existingModelFolder = findExistingModelFolder(under: modelsDirectory)
        let resolvedModelFolder: String

        if let existingModelFolder {
            resolvedModelFolder = existingModelFolder
            progressHandler?(1.0)
        } else {
            progressHandler?(0.0)
            let downloadedFolder = try await WhisperKit.download(
                variant: Constants.localWhisperModel,
                downloadBase: modelsDirectory,
                from: Constants.localWhisperModelRepository,
                progressCallback: { progress in
                    progressHandler?(Self.clamp(progress.fractionCompleted))
                }
            )
            resolvedModelFolder = downloadedFolder.path
            progressHandler?(1.0)
        }

        let config = WhisperKitConfig(
            model: Constants.localWhisperModel,
            downloadBase: modelsDirectory,
            modelRepo: Constants.localWhisperModelRepository,
            modelFolder: resolvedModelFolder,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        progressHandler?(1.0)
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
            let partial = try await transcribe(
                audioSamples: partialDecodeInput(session.audioSamples),
                isFinal: false
            )
            session.partialText = partial.text
            session.language = partial.language
            session.lastPartialDecodeAt = Date()
            session.lastDecodedSampleCount = session.audioSamples.count
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
    }

    // MARK: - Private

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

    private func partialDecodeInput(_ audioSamples: [Float]) -> [Float] {
        let windowSamples = Int(
            Constants.localWhisperPartialWindowSeconds * Constants.audioSampleRate
        )
        guard windowSamples > 0, audioSamples.count > windowSamples else {
            return audioSamples
        }
        return Array(audioSamples.suffix(windowSamples))
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
    /// (contains AudioEncoder.mlmodelc). Traversal is directory-only and depth-limited
    /// to avoid scanning every file in large model trees.
    private func findExistingModelFolder(under base: URL) -> String? {
        let fm = FileManager.default
        let maxDepth = 6
        var queue: [(url: URL, depth: Int)] = [(base, 0)]

        while !queue.isEmpty {
            let (url, depth) = queue.removeFirst()
            let audioEncoder = url.appendingPathComponent("AudioEncoder.mlmodelc")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: audioEncoder.path, isDirectory: &isDir), isDir.boolValue {
                return url.path
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
