import Foundation

enum TextInsertionFailureReason: String, Codable, Equatable {
    case accessibilityPermissionMissing
    case noFocusedElement
    case focusedElementNotEditable
    case pasteEventCreationFailed
    case noTargetAppAvailable
    case targetAppActivationFailed
}

enum TextInsertionResult: Equatable {
    case inserted
    case failed(TextInsertionFailureReason)
}
