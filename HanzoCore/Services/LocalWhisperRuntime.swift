import Foundation
import WhisperKit

actor LocalWhisperRuntime {
    static let shared = LocalWhisperRuntime()

    private struct Session {
        var audioSamples: [Float] = []
        var partialText = ""
        var language = "unknown"
        var lastPartialDecodeAt = Date.distantPast
        var lastDecodedSampleCount = 0
    }

    private var whisperKit: WhisperKit?
    private var sessions: [String: Session] = [:]

    func prepare() async throws {
        if whisperKit != nil {
            return
        }

        let modelsDirectory = modelsDirectoryURL()
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let config = WhisperKitConfig(
            model: Constants.localWhisperModel,
            downloadBase: modelsDirectory,
            modelRepo: Constants.localWhisperModelRepository,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
    }

    func startSession() async throws -> String {
        try await prepare()
        let sessionId = UUID().uuidString
        sessions[sessionId] = Session()
        return sessionId
    }

    func appendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        guard var session = sessions[sessionId] else {
            throw ASRError.sessionNotFound
        }

        let chunkSamples = try decodePCMFloat32(pcmData)
        session.audioSamples.append(contentsOf: chunkSamples)

        if shouldDecodePartial(session: session) {
            let partial = try await transcribe(audioSamples: session.audioSamples, isFinal: false)
            session.partialText = partial.text
            session.language = partial.language
            session.lastPartialDecodeAt = Date()
            session.lastDecodedSampleCount = session.audioSamples.count
        }

        sessions[sessionId] = session
        return ASRChunkResponse(text: session.partialText, language: session.language)
    }

    func finishSession(sessionId: String) async throws -> ASRFinishResponse {
        guard let session = sessions.removeValue(forKey: sessionId) else {
            throw ASRError.sessionNotFound
        }

        let final = try await transcribe(audioSamples: session.audioSamples, isFinal: true)
        return ASRFinishResponse(text: final.text, language: final.language)
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

    private func modelsDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(Constants.bundleIdentifier)
            .appendingPathComponent(Constants.localModelsFolderName)
    }
}
