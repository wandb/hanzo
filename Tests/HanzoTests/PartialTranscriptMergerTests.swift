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
}
