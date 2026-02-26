import Foundation

enum PartialTranscriptMerger {
    static func merge(previous: String, incoming: String) -> String {
        guard !previous.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return previous }

        if incoming.count >= previous.count, incoming.hasPrefix(previous) {
            return incoming
        }
        if previous.hasPrefix(incoming) {
            return previous
        }

        let prefixLength = longestCommonPrefixLength(previous, incoming)
        guard prefixLength > 0 else { return previous }

        let previousSuffixLength = previous.count - prefixLength
        let incomingSuffixLength = incoming.count - prefixLength
        guard incomingSuffixLength >= previousSuffixLength else {
            return previous
        }

        let prefix = String(previous.prefix(prefixLength))
        let incomingTail = String(incoming.dropFirst(prefixLength))
        return prefix + incomingTail
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
