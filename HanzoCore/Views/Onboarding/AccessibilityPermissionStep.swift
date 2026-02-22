import SwiftUI

struct AccessibilityPermissionStep: View {
    var onNext: () -> Void
    @State private var permissionGranted = PermissionService.shared.hasAccessibilityPermission

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)

            Text("Accessibility access")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text("Hanzo needs accessibility access to insert transcribed text into other apps.")
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
                Button("Open System Settings") {
                    PermissionService.shared.openAccessibilitySettings()
                }
                .buttonStyle(HUDButtonStyle())

                Text("Grant access in System Settings, then return here.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
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
