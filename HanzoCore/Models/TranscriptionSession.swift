import Foundation

@Observable
final class TranscriptionSession {
    var sessionId: String?
    var partialText: String = ""
    var finalText: String = ""
    var language: String = ""
    var startTime: Date?
    var endTime: Date?

    var durationSeconds: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }
}
