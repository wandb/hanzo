import Foundation

enum PartialTranscriptMerger {
    static func merge(previous: String, incoming: String) -> String {
        let previousTrimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTrimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !previousTrimmed.isEmpty else { return incomingTrimmed }
        guard !incomingTrimmed.isEmpty else { return previousTrimmed }

        if incomingTrimmed.count >= previousTrimmed.count,
           incomingTrimmed.hasPrefix(previousTrimmed) {
            return incomingTrimmed
        }
        if previousTrimmed.hasPrefix(incomingTrimmed) {
            return previousTrimmed
        }

        if let mergedFromOverlap = mergeUsingSuffixPrefixOverlap(
            previous: previousTrimmed,
            incoming: incomingTrimmed
        ) {
            return mergedFromOverlap
        }

        let prefixLength = longestCommonPrefixLength(previousTrimmed, incomingTrimmed)
        if prefixLength == 0 {
            // Some decoders occasionally emit a very short first fragment ("I.", "So")
            // and then continue with a full phrase that does not share a prefix.
            if shouldPreferIncomingWithoutPrefix(previous: previousTrimmed, incoming: incomingTrimmed) {
                return incomingTrimmed
            }
            return previousTrimmed
        }

        let previousSuffixLength = previousTrimmed.count - prefixLength
        let incomingSuffixLength = incomingTrimmed.count - prefixLength
        guard incomingSuffixLength >= previousSuffixLength else {
            return previousTrimmed
        }

        let prefix = String(previousTrimmed.prefix(prefixLength))
        let incomingTail = String(incomingTrimmed.dropFirst(prefixLength))
        return prefix + incomingTail
    }

    private static func shouldPreferIncomingWithoutPrefix(previous: String, incoming: String) -> Bool {
        if previous.count <= 8, incoming.count > previous.count {
            return true
        }

        let previousWords = wordCount(previous)
        let incomingWords = wordCount(incoming)
        if incomingWords >= previousWords + 3, incoming.count >= previous.count + 10 {
            return true
        }

        return false
    }

    private static func mergeUsingSuffixPrefixOverlap(previous: String, incoming: String) -> String? {
        let overlapLength = longestSuffixPrefixOverlapLength(previous, incoming)
        guard overlapLength >= 12 else {
            return nil
        }

        if overlapLength == incoming.count {
            return previous
        }

        let incomingTail = String(incoming.dropFirst(overlapLength))
        return previous + incomingTail
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func longestSuffixPrefixOverlapLength(_ left: String, _ right: String) -> Int {
        let maxLength = min(left.count, right.count)
        guard maxLength > 0 else { return 0 }

        for length in stride(from: maxLength, through: 1, by: -1) {
            let leftStart = left.index(left.endIndex, offsetBy: -length)
            let rightEnd = right.index(right.startIndex, offsetBy: length)
            if left[leftStart...] == right[..<rightEnd] {
                return length
            }
        }

        return 0
    }

    private static func longestCommonPrefixLength(_ left: String, _ right: String) -> Int {
        var leftIndex = left.startIndex
        var rightIndex = right.startIndex
        var count = 0

        while leftIndex < left.endIndex,
              rightIndex < right.endIndex,
              left[leftIndex] == right[rightIndex] {
            count += 1
            left.formIndex(after: &leftIndex)
            right.formIndex(after: &rightIndex)
        }

        return count
    }
}
