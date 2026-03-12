import SwiftUI

struct ModelDownloadStep: View {
    var onDownloaded: () -> Void

    @State private var statusText = "Preparing on-device Whisper model..."
    @State private var errorText: String?
    @State private var prepareTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.primary)

            Text("Preparing local model")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text("Hanzo is setting up the on-device Whisper model. This can take a few minutes the first time.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)

                Text(errorText ?? statusText)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(errorText == nil ? .secondary : .red)
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
        statusText = "Preparing on-device Whisper model..."

        prepareTask = Task {
            do {
                let manager = LocalASRRuntimeManager()
                try await manager.prepareModel()
                await MainActor.run {
                    statusText = "Local Whisper model is ready"
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
}
