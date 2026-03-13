import Testing
@testable import HanzoCore

@Suite("VerbalPausePostProcessor")
struct VerbalPausePostProcessorTests {
    @Test("removes common hesitation words")
    func removesHesitationWords() {
        let input = "Um I think uh this is fine."
        let output = VerbalPausePostProcessor.process(input)
        #expect(output == "I think this is fine.")
    }

    @Test("removes parenthetical filler like")
    func removesParentheticalLike() {
        let input = "It was, like, really fast."
        let output = VerbalPausePostProcessor.process(input)
        #expect(output == "It was really fast.")
    }

    @Test("keeps semantic like usage")
    func keepsSemanticLike() {
        let input = "I feel like this works."
        let output = VerbalPausePostProcessor.process(input)
        #expect(output == "I feel like this works.")
    }

    @Test("removes common discourse fillers")
    func removesDiscourseFillers() {
        let input = "You know, I mean this is kind of sort of noisy."
        let output = VerbalPausePostProcessor.process(input)
        #expect(output == "this is noisy.")
    }

    @Test("removes repeated words")
    func removesRepeatedWords() {
        let input = "where where should we go"
        let output = VerbalPausePostProcessor.process(input)
        #expect(output == "where should we go")
    }

    @Test("cleans realistic verbal pause heavy transcript")
    func cleansRealisticTranscript() {
        let input = """
        Now, here's, you know, the post processing filter with like, you know, where where we should pull out you know, words that are verbal pauses and like things that like just don't belong.
        """
        let output = VerbalPausePostProcessor.process(input)
        #expect(
            output
                == "Now, here's the post processing filter where we should pull out words that are verbal pauses and things that just don't belong."
        )
    }
}
