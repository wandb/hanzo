@testable import HanzoCore

final class MockPermissionService: PermissionServiceProtocol {
    var hasMicrophonePermission: Bool = true
    var hasAccessibilityPermission: Bool = true
    var requestMicReturn: Bool = true

    func requestMicrophonePermission() async -> Bool {
        return requestMicReturn
    }
}
