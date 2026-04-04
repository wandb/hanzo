import SwiftUI

struct ModelDownloadStep: View {
    var onDownloaded: () -> Void
    private let whisperStageWeight = 0.35
    private let llmStageWeight = 0.65

    @State private var errorText: String?
    @State private var prepareTask: Task<Void, Never>?
    @State private var llmTrickleTask: Task<Void, Never>?
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
            llmTrickleTask?.cancel()
            llmTrickleTask = nil
        }
    }

    private func startFlow() {
        prepareTask?.cancel()
        llmTrickleTask?.cancel()
        llmTrickleTask = nil
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
                startLLMTrickle()
                let llmManager = LocalLLMRuntimeManager.shared
                try await llmManager.prepareModel(progressHandler: { progress in
                    Task { @MainActor in
                        llmModelProgress = max(llmModelProgress, Self.clamp(progress))
                        overallProgress = combinedProgress()
                        statusText = llmModelProgress < 1.0
                            ? "Downloading rewrite model..."
                            : "Starting rewrite model..."
                    }
                })
                llmTrickleTask?.cancel()
                llmTrickleTask = nil

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
                    llmTrickleTask?.cancel()
                    llmTrickleTask = nil
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func startLLMTrickle() {
        llmTrickleTask?.cancel()
        llmTrickleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000)
                await MainActor.run {
                    guard llmModelProgress < 0.92 else { return }

                    let remaining = 0.92 - llmModelProgress
                    let step = max(0.0025, remaining * 0.06)
                    llmModelProgress = min(0.92, llmModelProgress + step)
                    overallProgress = combinedProgress()

                    if llmModelProgress < 0.7 {
                        statusText = "Preparing rewrite model..."
                    } else {
                        statusText = "Starting rewrite model..."
                    }
                }
            }
        }
    }

    private func combinedProgress() -> Double {
        let stageWeighted = (whisperModelProgress * whisperStageWeight) + (llmModelProgress * llmStageWeight)
        return Self.clamp(stageWeighted)
    }

    private var progressPercentText: String {
        "\(Int((overallProgress * 100).rounded()))%"
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }
}
