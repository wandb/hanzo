import SwiftUI

struct AccessibilityPermissionStep: View {
    var onNext: () -> Void
    @State private var permissionGranted = false
    @State private var timer: Timer?
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Accessibility Access")
                .font(.title2.bold())

            Text("Hanzo needs Accessibility access to insert transcribed text into other apps.")
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
        .onAppear {
            checkPermission()
            startPolling()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func checkPermission() {
        let granted = AXIsProcessTrusted()
        permissionGranted = granted
        if granted {
            timer?.invalidate()
            onNext()
        }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            checkPermission()
        }
    }
}
