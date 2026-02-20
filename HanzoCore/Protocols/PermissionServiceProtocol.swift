protocol PermissionServiceProtocol {
    var hasMicrophonePermission: Bool { get }
    var hasAccessibilityPermission: Bool { get }
    func requestMicrophonePermission() async -> Bool
}
