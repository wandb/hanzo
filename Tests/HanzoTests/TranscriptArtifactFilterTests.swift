import Testing
@testable import HanzoCore

@Suite("TranscriptArtifactFilter")
struct TranscriptArtifactFilterTests {

    @Test("sanitize removes known marker variants")
    func sanitizeRemovesKnownMarkerVariants() {
        for marker in ["[BLANK_AUDIO]", "[ Silence ]", "[blank-audio]", "[blank audio]"] {
            let sanitized = TranscriptArtifactFilter.sanitize(marker)
            #expect(sanitized.text == "")
            #expect(sanitized.removedMarkerCount == 1)
        }
    }

    @Test("sanitize preserves unknown bracket tags")
    func sanitizePreservesUnknownBracketTags() {
        let sanitized = TranscriptArtifactFilter.sanitize("ship [TODO] after review")
        #expect(sanitized.text == "ship [TODO] after review")
        #expect(sanitized.removedMarkerCount == 0)
    }

    @Test("sanitize strips known markers from mixed text")
    func sanitizeStripsKnownMarkersFromMixedText() {
        let sanitized = TranscriptArtifactFilter.sanitize("hello [BLANK_AUDIO] world")
        #expect(sanitized.text == "hello world")
        #expect(sanitized.removedMarkerCount == 1)
    }

    @Test("containsOnlyKnownMarkers returns true for marker-only payloads")
    func containsOnlyKnownMarkersForMarkerOnlyPayloads() {
        #expect(TranscriptArtifactFilter.containsOnlyKnownMarkers("[BLANK_AUDIO] [ Silence ]"))
        #expect(!TranscriptArtifactFilter.containsOnlyKnownMarkers("hello [BLANK_AUDIO] world"))
        #expect(!TranscriptArtifactFilter.containsOnlyKnownMarkers("[TODO]"))
    }

    @Test("isStandaloneParentheticalOnly matches parenthetical-only payloads")
    func standaloneParentheticalDetectionMatchesParentheticalOnlyPayloads() {
        #expect(TranscriptArtifactFilter.isStandaloneParentheticalOnly("(sigh)"))
        #expect(TranscriptArtifactFilter.isStandaloneParentheticalOnly("( clapping )"))
        #expect(!TranscriptArtifactFilter.isStandaloneParentheticalOnly("hello (sigh)"))
        #expect(!TranscriptArtifactFilter.isStandaloneParentheticalOnly("(sigh) hello"))
        #expect(!TranscriptArtifactFilter.isStandaloneParentheticalOnly("()"))
    }

    @Test("isOnlyStandaloneAnnotations matches annotation-only payloads")
    func annotationOnlyDetectionMatchesAnnotationOnlyPayloads() {
        #expect(TranscriptArtifactFilter.isOnlyStandaloneAnnotations("(sighs) (clapping)"))
        #expect(TranscriptArtifactFilter.isOnlyStandaloneAnnotations("*cough*."))
        #expect(TranscriptArtifactFilter.isOnlyStandaloneAnnotations("(sigh), *clapping*!"))
        #expect(!TranscriptArtifactFilter.isOnlyStandaloneAnnotations("huh"))
        #expect(!TranscriptArtifactFilter.isOnlyStandaloneAnnotations("hello (sighs)"))
    }

    @Test("isOnlyStandaloneBracketedAnnotations matches bracket-only payloads")
    func bracketOnlyDetectionMatchesBracketOnlyPayloads() {
        #expect(TranscriptArtifactFilter.isOnlyStandaloneBracketedAnnotations("[MUSIC PLAYING]"))
        #expect(TranscriptArtifactFilter.isOnlyStandaloneBracketedAnnotations("[MUSIC PLAYING] [APPLAUSE]"))
        #expect(TranscriptArtifactFilter.isOnlyStandaloneBracketedAnnotations("[MUSIC PLAYING]."))
        #expect(!TranscriptArtifactFilter.isOnlyStandaloneBracketedAnnotations("hello [MUSIC PLAYING]"))
        #expect(!TranscriptArtifactFilter.isOnlyStandaloneBracketedAnnotations("[ ]"))
    }

    @Test("stripTrailingStandaloneAnnotations removes trailing annotations but keeps spoken text")
    func stripTrailingStandaloneAnnotationsRemovesTrailingAnnotations() {
        let trailingParenthetical = TranscriptArtifactFilter.stripTrailingStandaloneAnnotations(
            "All of which are American dreams (crowd cheering)"
        )
        #expect(trailingParenthetical.text == "All of which are American dreams")
        #expect(trailingParenthetical.removedAnnotationCount == 1)

        let trailingMixed = TranscriptArtifactFilter.stripTrailingStandaloneAnnotations(
            "hello world (cheering) [MUSIC PLAYING]"
        )
        #expect(trailingMixed.text == "hello world")
        #expect(trailingMixed.removedAnnotationCount == 2)

        let inlineAnnotation = TranscriptArtifactFilter.stripTrailingStandaloneAnnotations(
            "hello (cheering) world"
        )
        #expect(inlineAnnotation.text == "hello (cheering) world")
        #expect(inlineAnnotation.removedAnnotationCount == 0)
    }
}
