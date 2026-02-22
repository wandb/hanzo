import SwiftUI

struct MicPermissionStep: View {
    var onNext: () -> Void
    @State private var permissionGranted = PermissionService.shared.hasMicrophonePermission

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)

            Text("Microphone access")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text("Hanzo needs microphone access to capture your speech for transcription.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if permissionGranted {
                Button("Continue") {
                    onNext()
                }
                .buttonStyle(HUDButtonStyle())
            } else {
                Button("Enable microphone") {
                    Task {
                        let granted = await PermissionService.shared.requestMicrophonePermission()
                        await MainActor.run {
                            permissionGranted = granted
                            if granted { onNext() }
                        }
                    }
                }
                .buttonStyle(HUDButtonStyle())
            }
        }
    }
}
