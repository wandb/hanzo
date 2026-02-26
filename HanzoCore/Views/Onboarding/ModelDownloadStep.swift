import SwiftUI

struct ModelDownloadStep: View {
    var onDownloaded: () -> Void

    @State private var progress: Double = 0
    @State private var statusText: String = "Preparing local runtime..."
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    private let runtimeManager = LocalASRRuntimeManager()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.primary)

            Text("Downloading local model")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text("Hanzo is setting up all on-device ASR models. This may take a while depending on your connection.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            VStack(spacing: 8) {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)

                Text("\(Int(progress * 100))%")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(errorText ?? statusText)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(errorText == nil ? .secondary : .red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if errorText != nil {
                Button("Retry download") {
                    startFlow()
                }
                .buttonStyle(HUDButtonStyle())
            }
        }
        .onAppear {
            startFlow()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func startFlow() {
        pollTask?.cancel()
        errorText = nil
        progress = max(progress, 0.01)
        statusText = "Preparing local runtime..."

        pollTask = Task {
            do {
                let baseURL = UserDefaults.standard.string(forKey: Constants.localServerEndpointKey)
                    ?? Constants.defaultLocalServerEndpoint
                try await downloadAllModelPresets(baseURL: baseURL)
            } catch {
                if error is CancellationError {
                    return
                }
                await MainActor.run {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func downloadAllModelPresets(baseURL: String) async throws {
        let presets = LocalASRModelPreset.allCases
        let total = presets.count
        let originalPresetRaw = UserDefaults.standard.string(forKey: Constants.localASRModelPresetKey)
        let originalPreset = LocalASRModelPreset(rawValue: originalPresetRaw ?? "")
            ?? Constants.defaultLocalASRModelPreset

        defer {
            UserDefaults.standard.set(originalPreset.rawValue, forKey: Constants.localASRModelPresetKey)
        }

        for (index, preset) in presets.enumerated() {
            try Task.checkCancellation()

            UserDefaults.standard.set(preset.rawValue, forKey: Constants.localASRModelPresetKey)
            await MainActor.run {
                let completed = Double(index) / Double(total)
                progress = max(progress, completed)
                statusText = "Preparing \(preset.displayName) (\(index + 1)/\(total))..."
            }

            try await runtimeManager.ensureRunning(baseURL: baseURL)
            try await startModelDownload(baseURL: baseURL)
            try await pollModelStatus(
                baseURL: baseURL,
                preset: preset,
                presetIndex: index,
                totalPresets: total
            )
        }

        await MainActor.run {
            progress = 1.0
            statusText = "All local models downloaded"
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        await MainActor.run {
            onDownloaded()
        }
    }

    private func startModelDownload(baseURL: String) async throws {
        guard let endpoint = URL(string: baseURL + Constants.localModelDownloadPath) else {
            throw ASRError.invalidURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ASRError.localRuntimeUnavailable(detail: "Failed to start model download")
        }
    }

    private func pollModelStatus(
        baseURL: String,
        preset: LocalASRModelPreset,
        presetIndex: Int,
        totalPresets: Int
    ) async throws {
        while !Task.isCancelled {
            let status = try await fetchModelStatus(baseURL: baseURL)
            let baseProgress = Double(presetIndex) / Double(totalPresets)
            let weightedProgress = (Double(presetIndex) + status.download.progress) / Double(totalPresets)

            await MainActor.run {
                progress = max(progress, max(baseProgress, weightedProgress))
                statusText = statusMessage(
                    for: status,
                    preset: preset,
                    presetIndex: presetIndex,
                    totalPresets: totalPresets
                )
            }

            if status.downloaded {
                await MainActor.run {
                    progress = max(
                        progress,
                        Double(presetIndex + 1) / Double(totalPresets)
                    )
                    statusText = "Downloaded \(preset.displayName) (\(presetIndex + 1)/\(totalPresets))"
                }
                return
            }

            if status.download.phase == "error" {
                throw ASRError.localRuntimeUnavailable(
                    detail: status.download.error ?? "Model download failed"
                )
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func fetchModelStatus(baseURL: String) async throws -> LocalModelStatusResponse {
        guard let endpoint = URL(string: baseURL + Constants.localModelStatusPath) else {
            throw ASRError.invalidURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ASRError.localRuntimeUnavailable(detail: "Failed to fetch model status")
        }
        return try JSONDecoder().decode(LocalModelStatusResponse.self, from: data)
    }

    private func statusMessage(
        for status: LocalModelStatusResponse,
        preset: LocalASRModelPreset,
        presetIndex: Int,
        totalPresets: Int
    ) -> String {
        let prefix = "\(preset.displayName) (\(presetIndex + 1)/\(totalPresets))"
        switch status.download.phase {
        case "downloading":
            return "Downloading \(prefix)..."
        case "loading":
            return "Loading \(prefix)..."
        case "ready":
            return "Ready: \(prefix)"
        case "idle":
            if status.downloaded {
                return "Downloaded \(prefix)"
            }
            return "Starting \(prefix)..."
        case "error":
            return status.download.error ?? "Download failed"
        default:
            return "Preparing \(prefix)..."
        }
    }
}

private struct LocalModelStatusResponse: Decodable {
    let ready: Bool
    let downloaded: Bool
    let download: DownloadInfo
}

private struct DownloadInfo: Decodable {
    let phase: String
    let progress: Double
    let error: String?
}
