import Foundation

enum RecentDictationInsertOutcome: String, Codable, Equatable {
    case inserted
    case failed
}

struct RecentDictationEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date
    let sourceBundleIdentifier: String?
    let sourceAppName: String?
    let insertOutcome: RecentDictationInsertOutcome
}
