import Foundation

enum VerbalPausePostProcessor {
    static func process(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // Remove common hesitation tokens and discourse filler phrases.
        text = replacingRegex(
            in: text,
            pattern: #"(?i)(?:,\s*)?\b(?:um+|uh+|er+|ah+|hmm+|mm+)\b(?:\s*,)?"#,
            template: " "
        )
        text = replacingRegex(
            in: text,
            pattern: #"(?i)(?:,\s*)?\b(?:you know|i mean|kind of|sort of)\b(?:\s*,)?"#,
            template: " "
        )

        // Remove high-confidence filler "like" usages only.
        text = replacingRegex(
            in: text,
            pattern: #"(?i)(^|[.!?]\s+)like,\s+"#,
            template: "$1"
        )
        text = replacingRegex(
            in: text,
            pattern: #"(?i),\s*like,\s*"#,
            template: " "
        )
        text = replacingRegex(
            in: text,
            pattern: #"(?i)\blike\s+like\b"#,
            template: "like"
        )
        text = replacingRegex(
            in: text,
            pattern: #"(?i)\bwith\s+like,\s+"#,
            template: ""
        )
        text = replacingRegex(
            in: text,
            pattern: #"(?i)\bwith\s+like\s+(?=(?:where|when|why|how|a|an|the|this|that|these|those|things?|stuff|it)\b)"#,
            template: ""
        )
        text = replacingRegex(
            in: text,
            pattern: #"(?i)\b(and|but|so)\s+like\s+(?=(?:a|an|the|this|that|these|those|things?|stuff|it|we|you|they|he|she)\b)"#,
            template: "$1 "
        )
        text = replacingRegex(
            in: text,
            pattern: #"(?i)\b(that|which|who)\s+like\s+(?=(?:just|really|basically|literally|honestly)\b)"#,
            template: "$1 "
        )
        text = replacingRegex(
            in: text,
            pattern: #"(?i)\blike\s+(?=(?:just|really|basically|literally|honestly)\b)"#,
            template: ""
        )

        // Remove immediate repeated words (e.g. "where where").
        text = replacingRegexUntilStable(
            in: text,
            pattern: #"(?i)\b([a-z][a-z']*)\s+\1\b"#,
            template: "$1"
        )

        // Normalize spacing and punctuation after removals.
        text = replacingRegex(in: text, pattern: #"\s+([,.;:!?])"#, template: "$1")
        text = replacingRegex(in: text, pattern: #"([,.;:!?])\s*([,.;:!?])"#, template: "$1")
        text = replacingRegex(in: text, pattern: #"\s{2,}"#, template: " ")
        text = replacingRegex(in: text, pattern: #"^\s*[,;:]\s*"#, template: "")
        text = replacingRegex(in: text, pattern: #"\s*[,;:]\s*$"#, template: "")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingRegex(
        in text: String,
        pattern: String,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replacingRegexUntilStable(
        in text: String,
        pattern: String,
        template: String
    ) -> String {
        var result = text
        while true {
            let updated = replacingRegex(in: result, pattern: pattern, template: template)
            if updated == result {
                return result
            }
            result = updated
        }
    }
}
