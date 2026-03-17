import Foundation

enum ASRProvider: String, CaseIterable {
    case local
    case server

    var displayName: String {
        switch self {
        case .local:
            return "Local (Whisper)"
        case .server:
            return "Custom Server"
        }
    }
}
