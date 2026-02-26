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

            Text("Hanzo is setting up the on-device ASR model. This may take a while depending on your connection.")
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
                try await runtimeManager.ensureRunning(baseURL: baseURL)

                try await startModelDownload(baseURL: baseURL)
                try await pollModelStatus(baseURL: baseURL)
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                }
            }
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

    private func pollModelStatus(baseURL: String) async throws {
        var hasAdvanced = false
        while !Task.isCancelled {
            let status = try await fetchModelStatus(baseURL: baseURL)

            await MainActor.run {
                progress = max(progress, status.download.progress)
                statusText = statusMessage(for: status)
            }

            if status.downloaded {
                await MainActor.run {
                    progress = 1.0
                    statusText = "Model downloaded"
                }
                if !hasAdvanced {
                    hasAdvanced = true
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await MainActor.run {
                        onDownloaded()
                    }
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

    private func statusMessage(for status: LocalModelStatusResponse) -> String {
        switch status.download.phase {
        case "downloading":
            return "Downloading model files..."
        case "loading":
            return "Loading model..."
        case "ready":
            return "Model ready"
        case "idle":
            if status.downloaded {
                return "Model downloaded"
            }
            return "Starting download..."
        case "error":
            return status.download.error ?? "Download failed"
        default:
            return "Preparing..."
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
