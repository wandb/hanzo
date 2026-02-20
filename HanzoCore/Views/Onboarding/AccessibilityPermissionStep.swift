import SwiftUI

struct AccessibilityPermissionStep: View {
    var onNext: () -> Void
    @State private var permissionGranted = PermissionService.shared.hasAccessibilityPermission

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Accessibility access")
                .font(.title2.bold())

            Text("Hanzo needs accessibility access to insert transcribed text into other apps.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if permissionGranted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Button("Continue") {
                    onNext()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Open System Settings") {
                    PermissionService.shared.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)

                Text("Grant access in System Settings, then return here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task {
            guard !permissionGranted else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if AXIsProcessTrusted() {
                    permissionGranted = true
                    onNext()
                    break
                }
            }
        }
    }
}
