import Foundation

enum TranscriptArtifactFilter {
    struct SanitizationResult {
        let text: String
        let removedMarkerCount: Int
    }

    struct TrailingAnnotationStripResult {
        let text: String
        let removedAnnotationCount: Int
    }

    private static let knownMarkerKeys: Set<String> = [
        "blank_audio",
        "silence",
    ]
    private static let bracketedTokenRegex = try! NSRegularExpression(
        pattern: #"\[[^\[\]\r\n]{1,64}\]"#
    )
    private static let markerSeparatorRegex = try! NSRegularExpression(
        pattern: #"[\s_-]+"#
    )
    private static let standaloneParentheticalRegex = try! NSRegularExpression(
        pattern: #"^\(\s*[^()\r\n]{1,64}\s*\)$"#
    )
    private static let standaloneAnnotationTokenRegex = try! NSRegularExpression(
        pattern: #"(\(\s*[^()\r\n]{1,64}\s*\)|\*\s*[^*\r\n]{1,64}\s*\*)[.,;:!?]*"#
    )
    private static let standaloneBracketAnnotationTokenRegex = try! NSRegularExpression(
        pattern: #"\[\s*[^\[\]\r\n]{1,64}\s*\][.,;:!?]*"#
    )
    private static let trailingStandaloneAnnotationRegex = try! NSRegularExpression(
        pattern: #"(?:\s+|^)(\(\s*[^()\r\n]{1,64}\s*\)|\*\s*[^*\r\n]{1,64}\s*\*|\[\s*[^\[\]\r\n]{1,64}\s*\])[.,;:!?]*\s*$"#
    )
    private static let whitespaceCollapseRegex = try! NSRegularExpression(
        pattern: #"\s+"#
    )
    private static let spaceBeforePunctuationRegex = try! NSRegularExpression(
        pattern: #"\s+([,.;:!?])"#
    )

    static func sanitize(_ text: String) -> SanitizationResult {
        guard !text.isEmpty else {
            return SanitizationResult(text: "", removedMarkerCount: 0)
        }

        guard text.contains("[") else {
            return SanitizationResult(
                text: normalizeSpacing(in: text),
                removedMarkerCount: 0
            )
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = bracketedTokenRegex.matches(in: text, options: [], range: fullRange)

        guard !matches.isEmpty else {
            return SanitizationResult(
                text: normalizeSpacing(in: text),
                removedMarkerCount: 0
            )
        }

        let mutable = NSMutableString(string: text)
        var removedMarkerCount = 0

        for match in matches.reversed() {
            let token = nsText.substring(with: match.range)
            guard isKnownMarkerToken(token) else { continue }
            mutable.replaceCharacters(in: match.range, with: " ")
            removedMarkerCount += 1
        }

        return SanitizationResult(
            text: normalizeSpacing(in: mutable as String),
            removedMarkerCount: removedMarkerCount
        )
    }

    static func containsOnlyKnownMarkers(_ text: String) -> Bool {
        let sanitized = sanitize(text)
        return sanitized.removedMarkerCount > 0 && sanitized.text.isEmpty
    }

    static func isStandaloneParentheticalOnly(_ text: String) -> Bool {
        let normalized = normalizeSpacing(in: text)
        guard !normalized.isEmpty else { return false }

        let fullRange = NSRange(normalized.startIndex..., in: normalized)
        let hasStandaloneParenthetical = standaloneParentheticalRegex.firstMatch(
            in: normalized,
            options: [],
            range: fullRange
        ) != nil
        guard hasStandaloneParenthetical else { return false }

        let inner = normalized
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.rangeOfCharacter(from: .alphanumerics) != nil
    }

    static func isOnlyStandaloneAnnotations(_ text: String) -> Bool {
        let normalized = normalizeSpacing(in: text)
        guard !normalized.isEmpty else { return false }
        guard normalized.contains("(") || normalized.contains("*") else { return false }

        let nsText = normalized as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = standaloneAnnotationTokenRegex.matches(
            in: normalized,
            options: [],
            range: fullRange
        )
        guard !matches.isEmpty else { return false }

        var removedCount = 0
        let mutable = NSMutableString(string: normalized)
        for match in matches.reversed() {
            let token = nsText.substring(with: match.range)
            guard annotationTokenContainsAlphanumeric(token) else { continue }
            mutable.replaceCharacters(in: match.range, with: " ")
            removedCount += 1
        }

        guard removedCount > 0 else { return false }
        let remainder = normalizeSpacing(in: mutable as String)
        return remainder.isEmpty
    }

    static func isOnlyStandaloneBracketedAnnotations(_ text: String) -> Bool {
        let normalized = normalizeSpacing(in: text)
        guard !normalized.isEmpty else { return false }
        guard normalized.contains("[") else { return false }

        let nsText = normalized as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = standaloneBracketAnnotationTokenRegex.matches(
            in: normalized,
            options: [],
            range: fullRange
        )
        guard !matches.isEmpty else { return false }

        var removedCount = 0
        let mutable = NSMutableString(string: normalized)
        for match in matches.reversed() {
            let token = nsText.substring(with: match.range)
            guard bracketTokenContainsAlphanumeric(token) else { continue }
            mutable.replaceCharacters(in: match.range, with: " ")
            removedCount += 1
        }

        guard removedCount > 0 else { return false }
        let remainder = normalizeSpacing(in: mutable as String)
        return remainder.isEmpty
    }

    static func stripTrailingStandaloneAnnotations(_ text: String) -> TrailingAnnotationStripResult {
        var normalized = normalizeSpacing(in: text)
        guard !normalized.isEmpty else {
            return TrailingAnnotationStripResult(text: "", removedAnnotationCount: 0)
        }

        var removedCount = 0
        while true {
            let fullRange = NSRange(normalized.startIndex..., in: normalized)
            guard let match = trailingStandaloneAnnotationRegex.firstMatch(
                in: normalized,
                options: [],
                range: fullRange
            ) else {
                break
            }

            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound,
                  let tokenSwiftRange = Range(tokenRange, in: normalized) else {
                break
            }
            let token = String(normalized[tokenSwiftRange])
            guard standaloneAnnotationTokenContainsAlphanumeric(token) else { break }

            guard let matchSwiftRange = Range(match.range, in: normalized) else { break }
            normalized.removeSubrange(matchSwiftRange)
            normalized = normalizeSpacing(in: normalized)
            removedCount += 1
        }

        return TrailingAnnotationStripResult(
            text: normalized,
            removedAnnotationCount: removedCount
        )
    }

    private static func isKnownMarkerToken(_ token: String) -> Bool {
        guard token.first == "[", token.last == "]" else { return false }

        let innerText = token.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !innerText.isEmpty else { return false }

        let lowercased = innerText.lowercased()
        let range = NSRange(lowercased.startIndex..., in: lowercased)
        let normalized = markerSeparatorRegex.stringByReplacingMatches(
            in: lowercased,
            options: [],
            range: range,
            withTemplate: "_"
        )

        return knownMarkerKeys.contains(normalized)
    }

    private static func annotationTokenContainsAlphanumeric(_ token: String) -> Bool {
        let trimmed = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        guard !trimmed.isEmpty else { return false }

        let core: Substring
        if trimmed.first == "(", trimmed.last == ")" {
            core = trimmed.dropFirst().dropLast()
        } else if trimmed.first == "*", trimmed.last == "*" {
            core = trimmed.dropFirst().dropLast()
        } else {
            return false
        }

        let inner = core.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return false }
        return inner.rangeOfCharacter(from: .alphanumerics) != nil
    }

    private static func bracketTokenContainsAlphanumeric(_ token: String) -> Bool {
        let trimmed = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        guard trimmed.first == "[", trimmed.last == "]" else { return false }

        let inner = trimmed
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return false }
        return inner.rangeOfCharacter(from: .alphanumerics) != nil
    }

    private static func standaloneAnnotationTokenContainsAlphanumeric(_ token: String) -> Bool {
        if token.first == "(" {
            return annotationTokenContainsAlphanumeric(token)
        }
        if token.first == "*" {
            return annotationTokenContainsAlphanumeric(token)
        }
        if token.first == "[" {
            return bracketTokenContainsAlphanumeric(token)
        }
        return false
    }

    private static func normalizeSpacing(in text: String) -> String {
        let textRange = NSRange(text.startIndex..., in: text)
        let collapsedWhitespace = whitespaceCollapseRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: textRange,
            withTemplate: " "
        )
        let collapsedRange = NSRange(collapsedWhitespace.startIndex..., in: collapsedWhitespace)
        let tightenedPunctuation = spaceBeforePunctuationRegex.stringByReplacingMatches(
            in: collapsedWhitespace,
            options: [],
            range: collapsedRange,
            withTemplate: "$1"
        )

        return tightenedPunctuation.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
