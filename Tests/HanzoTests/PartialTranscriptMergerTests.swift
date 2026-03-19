import Testing
@testable import HanzoCore

@Suite("PartialTranscriptMerger")
struct PartialTranscriptMergerTests {

    @Test("empty previous uses incoming")
    func emptyPreviousUsesIncoming() {
        let merged = PartialTranscriptMerger.merge(previous: "", incoming: "hello")
        #expect(merged == "hello")
    }

    @Test("incoming extension replaces previous")
    func incomingExtensionReplacesPrevious() {
        let merged = PartialTranscriptMerger.merge(previous: "hello", incoming: "hello world")
        #expect(merged == "hello world")
    }

    @Test("incoming shrink does not regress visible partial")
    func incomingShrinkDoesNotRegress() {
        let merged = PartialTranscriptMerger.merge(previous: "hello world", incoming: "hello wor")
        #expect(merged == "hello world")
    }

    @Test("common-prefix correction keeps non-regressive update")
    func commonPrefixCorrection() {
        let merged = PartialTranscriptMerger.merge(previous: "turn on the ligh", incoming: "turn on the lights now")
        #expect(merged == "turn on the lights now")
    }

    @Test("unrelated shorter text keeps previous")
    func unrelatedShorterTextKeepsPrevious() {
        let merged = PartialTranscriptMerger.merge(previous: "hello world", incoming: "bye")
        #expect(merged == "hello world")
    }

    @Test("short starter fragment can be replaced by longer no-prefix update")
    func shortStarterFragmentCanBeReplaced() {
        let merged = PartialTranscriptMerger.merge(previous: "I.", incoming: "This is a complete sentence")
        #expect(merged == "This is a complete sentence")
    }

    @Test("rolling partial window appends new tail using suffix overlap")
    func rollingPartialWindowAppendsNewTailUsingSuffixOverlap() {
        let previous = "one two three four five six seven eight nine ten"
        let incoming = "five six seven eight nine ten eleven twelve"
        let merged = PartialTranscriptMerger.merge(previous: previous, incoming: incoming)
        #expect(merged == "one two three four five six seven eight nine ten eleven twelve")
    }

    @Test("small accidental suffix-prefix overlap does not merge unrelated text")
    func smallAccidentalOverlapDoesNotMergeUnrelatedText() {
        let previous = "I think"
        let incoming = "k now"
        let merged = PartialTranscriptMerger.merge(previous: previous, incoming: incoming)
        #expect(merged == previous)
    }

    @Test("word overlap tolerates punctuation re-edits")
    func wordOverlapToleratesPunctuationReEdits() {
        let previous = "we are testing world, this is a test"
        let incoming = "world this is a test and then more words"
        let merged = PartialTranscriptMerger.merge(previous: previous, incoming: incoming)
        #expect(merged == "we are testing world, this is a test and then more words")
    }

    @Test("word overlap can recover when incoming window starts with rewritten lead words")
    func wordOverlapRecoversFromRewrittenLeadWords() {
        let previous = "one two three four five six seven eight nine ten"
        let incoming = "zero five six seven eight nine ten eleven"
        let merged = PartialTranscriptMerger.merge(previous: previous, incoming: incoming)
        #expect(merged == "one two three four five six seven eight nine ten eleven")
    }

    @Test("anchor realignment can recover when previous tail diverges")
    func anchorRealignmentRecoversFromDivergedTail() {
        let previous = "one two three four five six seven eight wrong words wrong words"
        let incoming = "five six seven eight nine ten eleven"
        let merged = PartialTranscriptMerger.merge(previous: previous, incoming: incoming)
        #expect(merged == "one two three four five six seven eight nine ten eleven")
    }

    @Test("aggressive anchor realignment can be disabled for smoother updates")
    func anchorRealignmentCanBeDisabled() {
        let previous = "one two three four five six seven eight wrong words wrong words"
        let incoming = "five six seven eight nine ten eleven"
        let merged = PartialTranscriptMerger.merge(
            previous: previous,
            incoming: incoming,
            allowAggressiveRecovery: false
        )
        #expect(merged == previous)
    }

    @Test("anchor realignment does not rewrite from distant earlier match")
    func anchorRealignmentIgnoresDistantMatches() {
        let previous = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
        let incoming = "alpha beta gamma delta and totally new stream"
        let merged = PartialTranscriptMerger.merge(previous: previous, incoming: incoming)
        #expect(merged == previous)
    }

    @Test("recent tail rewrite keeps streaming but allows local corrections")
    func recentTailRewriteAllowsCorrections() {
        let previous = "a b c d e f g h i j k l m n o p q r s t u v w x y z one two three four five six seven eight maybe later words here"
        let incoming = "one two three four five six seven eight right now words here"
        let merged = PartialTranscriptMerger.merge(previous: previous, incoming: incoming)
        #expect(merged == "a b c d e f g h i j k l m n o p q r s t u v w x y z one two three four five six seven eight right now words here")
    }
}
