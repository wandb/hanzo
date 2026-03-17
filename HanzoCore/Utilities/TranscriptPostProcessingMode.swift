import Foundation

enum TranscriptPostProcessingMode: String, CaseIterable, Codable {
    case off
    case llm

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .llm:
            return "LLM"
        }
    }
}
