import Foundation

enum ASRProvider: String, CaseIterable {
    case hosted
    case local
    case server

    var displayName: String {
        switch self {
        case .hosted:
            return "Hosted"
        case .local:
            return "Local (Whisper)"
        case .server:
            return "Custom Server"
        }
    }
}
