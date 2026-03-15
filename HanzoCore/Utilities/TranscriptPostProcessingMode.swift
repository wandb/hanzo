import Foundation

enum TranscriptPostProcessingMode: String, CaseIterable {
    case off
    case removeVerbalPauses
    case llm

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .removeVerbalPauses:
            return "Remove verbal pauses"
        case .llm:
            return "LLM"
        }
    }
}
