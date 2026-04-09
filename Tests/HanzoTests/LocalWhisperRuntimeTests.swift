import Testing
@testable import HanzoCore

@Suite("LocalWhisperRuntime")
struct LocalWhisperRuntimeTests {
    @Test("short empty final transcript is eligible for retry")
    func shortEmptyFinalTranscriptIsEligibleForRetry() {
        let shortSampleCount = Int(Constants.audioSampleRate * 0.9)

        #expect(
            LocalWhisperRuntime.shouldRetryShortFinalTranscription(
                text: "",
                audioSampleCount: shortSampleCount
            )
        )
        #expect(
            LocalWhisperRuntime.shouldRetryShortFinalTranscription(
                text: "   ",
                audioSampleCount: shortSampleCount
            )
        )
    }

    @Test("non-empty or long final transcript does not retry")
    func nonEmptyOrLongFinalTranscriptDoesNotRetry() {
        let longSampleCount = Int(
            Constants.audioSampleRate * (Constants.localWhisperShortFinalRetryMaxOriginalSeconds + 0.1)
        )

        #expect(
            !LocalWhisperRuntime.shouldRetryShortFinalTranscription(
                text: "create the doc",
                audioSampleCount: 1
            )
        )
        #expect(
            !LocalWhisperRuntime.shouldRetryShortFinalTranscription(
                text: "",
                audioSampleCount: longSampleCount
            )
        )
        #expect(
            !LocalWhisperRuntime.shouldRetryShortFinalTranscription(
                text: "",
                audioSampleCount: 0
            )
        )
    }

    @Test("short final retry padding preserves samples and reaches minimum duration")
    func shortFinalRetryPaddingPreservesSamplesAndReachesMinimumDuration() {
        let original = Array(repeating: Float(0.25), count: Int(Constants.audioSampleRate * 0.6))

        let padded = LocalWhisperRuntime.paddedShortFinalAudioSamples(original)
        let minimumSampleCount = Int(
            Constants.localWhisperShortFinalRetryMinimumSeconds * Constants.audioSampleRate
        )

        #expect(padded.count >= minimumSampleCount)

        let leadingPaddingCount = (padded.count - original.count) / 2
        let originalSlice = Array(padded[leadingPaddingCount..<(leadingPaddingCount + original.count)])

        #expect(originalSlice == original)
        #expect(padded[..<leadingPaddingCount].allSatisfy { $0 == 0 })
        #expect(padded[(leadingPaddingCount + original.count)...].allSatisfy { $0 == 0 })
    }

    @Test("short final retry padding adds preferred silence around retriable clips")
    func shortFinalRetryPaddingAddsPreferredSilenceAroundRetriableClips() {
        let original = Array(
            repeating: Float(0.5),
            count: Int(Constants.audioSampleRate * Constants.localWhisperShortFinalRetryMinimumSeconds)
        )

        let padded = LocalWhisperRuntime.paddedShortFinalAudioSamples(original)
        let expectedPaddingCount = Int(
            Constants.localWhisperShortFinalRetryPaddingSeconds * Constants.audioSampleRate * 2
        )

        #expect(padded.count == original.count + expectedPaddingCount)
    }
}
