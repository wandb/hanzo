import Foundation

enum ASRProvider: String, CaseIterable {
    case server
    case local

    var displayName: String {
        switch self {
        case .server:
            return "Server"
        case .local:
            return "Local"
        }
    }
}

enum LocalASRModelPreset: String, CaseIterable {
    case fast
    case balanced
    case max

    var displayName: String {
        switch self {
        case .fast:
            return "Fast (0.6B 8-bit)"
        case .balanced:
            return "Balanced (1.7B 4-bit)"
        case .max:
            return "Max (1.7B 8-bit)"
        }
    }

    var modelRepository: String {
        switch self {
        case .fast:
            return "mlx-community/Qwen3-ASR-0.6B-8bit"
        case .balanced:
            return "mlx-community/Qwen3-ASR-1.7B-4bit"
        case .max:
            return "mlx-community/Qwen3-ASR-1.7B-8bit"
        }
    }
}
