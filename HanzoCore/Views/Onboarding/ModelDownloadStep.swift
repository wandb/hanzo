import SwiftUI

struct ModelDownloadStep: View {
    var onDownloaded: () -> Void

    @State private var errorText: String?
    @State private var prepareTask: Task<Void, Never>?
    @State private var statusText = "Preparing speech model..."
    @State private var overallProgress = 0.0
    @State private var whisperModelProgress = 0.0
    @State private var llmModelProgress = 0.0

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.primary)

            Text("Preparing local models")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text("Hanzo is setting up on-device models for low-latency dictation and post-processing. This can take a few minutes the first time.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            ProgressView(value: overallProgress, total: 1.0)
                .progressViewStyle(.linear)
                .controlSize(.large)
                .frame(maxWidth: 360)

            Text("\(statusText) \(progressPercentText)")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if let errorText {
                Text(errorText)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if errorText != nil {
                Button("Retry setup") {
                    startFlow()
                }
                .buttonStyle(HUDButtonStyle())
            }
        }
        .onAppear {
            startFlow()
        }
        .onDisappear {
            prepareTask?.cancel()
            prepareTask = nil
        }
    }

    private func startFlow() {
        prepareTask?.cancel()
        errorText = nil
        statusText = "Preparing speech model..."
        whisperModelProgress = 0.0
        llmModelProgress = 0.0
        overallProgress = 0.0

        prepareTask = Task {
            do {
                let asrManager = LocalASRRuntimeManager()
                try await asrManager.prepareModel(progressHandler: { progress in
                    Task { @MainActor in
                        whisperModelProgress = Self.clamp(progress)
                        overallProgress = combinedProgress()
                        statusText = whisperModelProgress < 1.0
                            ? "Downloading speech model..."
                            : "Optimizing speech model..."
                    }
                })

                await MainActor.run {
                    statusText = "Preparing rewrite model..."
                }
                let llmManager = LocalLLMRuntimeManager.shared
                try await llmManager.prepareModel(progressHandler: { progress in
                    Task { @MainActor in
                        llmModelProgress = Self.clamp(progress)
                        overallProgress = combinedProgress()
                        statusText = llmModelProgress < 1.0
                            ? "Downloading rewrite model..."
                            : "Starting rewrite model..."
                    }
                })

                await MainActor.run {
                    overallProgress = 1.0
                    statusText = "Finishing setup..."
                    onDownloaded()
                }
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

    private func combinedProgress() -> Double {
        let whisperBytes = whisperModelProgress * Double(Constants.localWhisperModelExpectedDownloadBytes)
        let llmBytes = llmModelProgress * Double(Constants.localLLMModelExpectedDownloadBytes)
        let totalBytes = Double(
            Constants.localWhisperModelExpectedDownloadBytes + Constants.localLLMModelExpectedDownloadBytes
        )
        guard totalBytes > 0 else {
            return Self.clamp(max(whisperModelProgress, llmModelProgress))
        }

        return Self.clamp((whisperBytes + llmBytes) / totalBytes)
    }

    private var progressPercentText: String {
        "\(Int((overallProgress * 100).rounded()))%"
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }
}
