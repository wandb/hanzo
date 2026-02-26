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
            return "Local"
        case .server:
            return "Custom Server"
        }
    }
}

enum LocalASRModelPreset: String, CaseIterable {
    case fast
    case balanced

    var displayName: String {
        switch self {
        case .fast:
            return "Fast (0.6B 8-bit)"
        case .balanced:
            return "Balanced (1.7B 4-bit)"
        }
    }

    var modelRepository: String {
        switch self {
        case .fast:
            return "mlx-community/Qwen3-ASR-0.6B-8bit"
        case .balanced:
            return "mlx-community/Qwen3-ASR-1.7B-4bit"
        }
    }
}
