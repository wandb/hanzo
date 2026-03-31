import Foundation

enum ASRArtifactFilter {
    private static let nonSpeechTagPattern = #"(?:\(|\[)\s*(?:blank[\s_-]*audio|silence|sound)\s*(?:\)|\])"#

    static func sanitize(_ transcript: String) -> String {
        guard !transcript.isEmpty else { return transcript }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard let nonSpeechRegex = try? NSRegularExpression(
            pattern: nonSpeechTagPattern,
            options: [.caseInsensitive]
        ) else {
            return trimmed
        }

        let withoutTags = nonSpeechRegex.stringByReplacingMatches(
            in: trimmed,
            options: [],
            range: range,
            withTemplate: " "
        )
        let normalizedWhitespace = withoutTags.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return normalizedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
