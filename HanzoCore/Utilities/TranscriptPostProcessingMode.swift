import Foundation

enum TranscriptPostProcessingMode: String, CaseIterable, Codable {
    case off
    case llm

    private static let legacyRemoveVerbalPausesRawValue = "removeVerbalPauses"

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .llm:
            return "LLM"
        }
    }

    static func fromStoredRawValue(_ rawValue: String) -> TranscriptPostProcessingMode? {
        switch rawValue {
        case TranscriptPostProcessingMode.off.rawValue:
            return .off
        case TranscriptPostProcessingMode.llm.rawValue:
            return .llm
        case legacyRemoveVerbalPausesRawValue:
            // Legacy setting migrated to nearest non-LLM behavior.
            return .off
        default:
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = TranscriptPostProcessingMode.fromStoredRawValue(rawValue) ?? .off
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
