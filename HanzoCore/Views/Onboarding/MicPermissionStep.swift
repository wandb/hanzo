import SwiftUI

struct MicPermissionStep: View {
    var onNext: () -> Void
    @State private var permissionGranted = PermissionService.shared.hasMicrophonePermission

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Microphone Access")
                .font(.title2.bold())

            Text("Hanzo needs microphone access to capture your speech for transcription.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if permissionGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Button("Continue") {
                    onNext()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Enable Microphone") {
                    Task {
                        let granted = await PermissionService.shared.requestMicrophonePermission()
                        await MainActor.run {
                            permissionGranted = granted
                            if granted { onNext() }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
