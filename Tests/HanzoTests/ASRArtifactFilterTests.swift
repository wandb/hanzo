import Testing
@testable import HanzoCore

@Suite("ASRArtifactFilter")
struct ASRArtifactFilterTests {
    @Test("removes bracketed silence tag")
    func removesBracketedSilenceTag() {
        #expect(ASRArtifactFilter.sanitize("[ Silence ]") == "")
    }

    @Test("removes bracketed blank audio tag with underscore")
    func removesBracketedBlankAudioTag() {
        #expect(ASRArtifactFilter.sanitize("[BLANK_AUDIO]") == "")
    }

    @Test("removes bracketed sound tag from sentence")
    func removesBracketedSoundTagFromSentence() {
        #expect(ASRArtifactFilter.sanitize("hello [SOUND] world") == "hello world")
    }

    @Test("does not remove unbracketed phrase")
    func doesNotRemoveUnbracketedPhrase() {
        #expect(ASRArtifactFilter.sanitize("blank audio should stay") == "blank audio should stay")
    }
}
