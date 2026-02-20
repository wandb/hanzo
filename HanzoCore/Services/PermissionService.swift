import AVFoundation
import ApplicationServices
import AppKit

final class PermissionService: PermissionServiceProtocol {
    static let shared = PermissionService()

    private init() {}

    var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func promptAccessibilityIfNeeded() {
        if !hasAccessibilityPermission {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }
}
