import Foundation

enum PartialTranscriptMerger {
    static func merge(
        previous: String,
        incoming: String,
        allowAggressiveRecovery: Bool = true
    ) -> String {
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

        if let mergedFromRecentTailRewrite = mergeUsingRecentTailRewrite(
            previous: previousTrimmed,
            incoming: incomingTrimmed
        ) {
            return mergedFromRecentTailRewrite
        }

        if let mergedFromOverlap = mergeUsingSuffixPrefixOverlap(
            previous: previousTrimmed,
            incoming: incomingTrimmed
        ) {
            return mergedFromOverlap
        }

        if let mergedFromWordOverlap = mergeUsingWordSuffixOverlap(
            previous: previousTrimmed,
            incoming: incomingTrimmed
        ) {
            return mergedFromWordOverlap
        }

        if allowAggressiveRecovery,
           let mergedFromAnchorRealignment = mergeUsingWordAnchorRealignment(
               previous: previousTrimmed,
               incoming: incomingTrimmed
           ) {
            return mergedFromAnchorRealignment
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

    private static func mergeUsingRecentTailRewrite(previous: String, incoming: String) -> String? {
        let correctionWindowWords = 48
        let minimumOverlapWords = 3
        let maximumIncomingOffsetWords = 12
        let maximumCorrectionRewriteWords = 16
        let maximumCorrectionShrinkWords = 8

        let previousWords = previous.split(whereSeparator: \.isWhitespace).map(String.init)
        let incomingWords = incoming.split(whereSeparator: \.isWhitespace).map(String.init)
        guard previousWords.count > correctionWindowWords / 2,
              incomingWords.count >= minimumOverlapWords else {
            return nil
        }

        let keepWordCount = max(0, previousWords.count - correctionWindowWords)
        guard keepWordCount > 0 else { return nil }

        let keptPrefixWords = Array(previousWords[..<keepWordCount])
        let keptPrefixNormalized = keptPrefixWords.map(normalizedWord)
        let incomingNormalized = incomingWords.map(normalizedWord)
        guard keptPrefixNormalized.count >= minimumOverlapWords else { return nil }

        let maxOverlap = min(keptPrefixNormalized.count, incomingNormalized.count)
        for overlap in stride(from: maxOverlap, through: minimumOverlapWords, by: -1) {
            let previousStart = keptPrefixNormalized.count - overlap
            let previousSuffix = keptPrefixNormalized[previousStart..<keptPrefixNormalized.count]
            let maxIncomingStart = min(maximumIncomingOffsetWords, incomingNormalized.count - overlap)
            guard maxIncomingStart >= 0 else { continue }

            for incomingStart in 0...maxIncomingStart {
                let incomingEnd = incomingStart + overlap
                let incomingSlice = incomingNormalized[incomingStart..<incomingEnd]
                guard incomingSlice == previousSuffix else { continue }
                guard incomingEnd < incomingWords.count else { continue }

                let mergedWords = keptPrefixWords + incomingWords[incomingEnd...]
                let merged = mergedWords.joined(separator: " ")
                if merged.isEmpty || merged == previous {
                    continue
                }

                let mergedWordsArray = Array(mergedWords)
                let commonPrefixWords = longestCommonPrefixWordCount(previousWords, mergedWordsArray)
                let rewrittenWords = previousWords.count - commonPrefixWords
                let shrinkWords = max(0, previousWords.count - mergedWordsArray.count)
                if rewrittenWords > maximumCorrectionRewriteWords || shrinkWords > maximumCorrectionShrinkWords {
                    continue
                }

                return merged
            }
        }

        return nil
    }

    private static func longestCommonPrefixWordCount(_ left: [String], _ right: [String]) -> Int {
        let limit = min(left.count, right.count)
        var index = 0
        while index < limit, left[index] == right[index] {
            index += 1
        }
        return index
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

    private static func mergeUsingWordSuffixOverlap(previous: String, incoming: String) -> String? {
        let minimumWordOverlap = 4
        let maximumIncomingOffsetWords = 12

        let previousWords = previous.split(whereSeparator: \.isWhitespace).map(String.init)
        let incomingWords = incoming.split(whereSeparator: \.isWhitespace).map(String.init)
        guard previousWords.count >= minimumWordOverlap,
              incomingWords.count >= minimumWordOverlap else {
            return nil
        }

        let previousNormalized = previousWords.map(normalizedWord)
        let incomingNormalized = incomingWords.map(normalizedWord)
        let maxOverlap = min(previousNormalized.count, incomingNormalized.count)

        for overlap in stride(from: maxOverlap, through: minimumWordOverlap, by: -1) {
            let previousStart = previousNormalized.count - overlap
            let previousSuffix = previousNormalized[previousStart..<previousNormalized.count]
            let maxIncomingStart = min(maximumIncomingOffsetWords, incomingNormalized.count - overlap)
            guard maxIncomingStart >= 0 else { continue }

            for incomingStart in 0...maxIncomingStart {
                let incomingEnd = incomingStart + overlap
                let incomingSlice = incomingNormalized[incomingStart..<incomingEnd]
                if incomingSlice != previousSuffix {
                    continue
                }

                if incomingEnd >= incomingWords.count {
                    return previous
                }

                let tail = incomingWords[incomingEnd...].joined(separator: " ")
                guard !tail.isEmpty else { return previous }
                return previous + " " + tail
            }
        }

        return nil
    }

    private static func mergeUsingWordAnchorRealignment(previous: String, incoming: String) -> String? {
        let anchorWordCount = 4
        let lookbackWordCount = 120
        let maximumTailGapWords = 40

        let previousWords = previous.split(whereSeparator: \.isWhitespace).map(String.init)
        let incomingWords = incoming.split(whereSeparator: \.isWhitespace).map(String.init)
        guard previousWords.count >= anchorWordCount,
              incomingWords.count >= anchorWordCount else {
            return nil
        }

        let previousNormalized = previousWords.map(normalizedWord)
        let incomingNormalized = incomingWords.map(normalizedWord)
        guard previousNormalized.count >= anchorWordCount,
              incomingNormalized.count >= anchorWordCount else {
            return nil
        }

        var incomingAnchors: [String: [Int]] = [:]
        for incomingStart in 0...(incomingNormalized.count - anchorWordCount) {
            let anchor = incomingNormalized[incomingStart..<(incomingStart + anchorWordCount)]
            let key = anchor.joined(separator: "|")
            incomingAnchors[key, default: []].append(incomingStart)
        }

        let previousSearchStart = max(0, previousNormalized.count - lookbackWordCount)
        var bestMatch: (previousStart: Int, incomingStart: Int, length: Int)?

        for previousStart in previousSearchStart...(previousNormalized.count - anchorWordCount) {
            let anchor = previousNormalized[previousStart..<(previousStart + anchorWordCount)]
            let key = anchor.joined(separator: "|")
            guard let incomingStarts = incomingAnchors[key] else { continue }

            for incomingStart in incomingStarts {
                var length = anchorWordCount
                while previousStart + length < previousNormalized.count,
                      incomingStart + length < incomingNormalized.count,
                      previousNormalized[previousStart + length] == incomingNormalized[incomingStart + length] {
                    length += 1
                }

                let previousEnd = previousStart + length
                let isNearTail = previousNormalized.count - previousEnd <= maximumTailGapWords
                let isInRecentRegion = previousEnd * 5 >= previousNormalized.count * 3
                guard isNearTail, isInRecentRegion else { continue }

                if let currentBest = bestMatch {
                    let currentBestEnd = currentBest.previousStart + currentBest.length
                    if previousEnd > currentBestEnd || (previousEnd == currentBestEnd && length > currentBest.length) {
                        bestMatch = (previousStart, incomingStart, length)
                    }
                } else {
                    bestMatch = (previousStart, incomingStart, length)
                }
            }
        }

        guard let bestMatch else {
            return nil
        }

        let previousEnd = bestMatch.previousStart + bestMatch.length
        let incomingEnd = bestMatch.incomingStart + bestMatch.length
        guard incomingEnd < incomingWords.count else {
            return previous
        }

        let mergedPrefix = previousWords[..<previousEnd].joined(separator: " ")
        let mergedTail = incomingWords[incomingEnd...].joined(separator: " ")
        guard !mergedTail.isEmpty else { return mergedPrefix }

        if mergedPrefix.isEmpty {
            return mergedTail
        }
        return mergedPrefix + " " + mergedTail
    }

    private static func normalizedWord(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
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
