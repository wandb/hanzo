import Testing
import Foundation
@testable import HanzoCore

/// Pure-logic tests for `SilenceDetector`. The detector is evaluated
/// directly (no audio-capture dispatch), so `TestClock.advance(by:)`
/// fully controls elapsed-time decisions — no `Task.sleep` needed.
@Suite("SilenceDetector")
struct SilenceDetectorTests {

    // MARK: - Harness

    final class StubDelegate: SilenceDetectorDelegate {
        var currentDictationState: DictationState = .listening
        var currentShowsHoldIndicator: Bool = false
        var currentPartialTranscript: String = ""
        private(set) var stopRequestCount = 0

        func silenceDetectorDidRequestStopRecording(_ detector: SilenceDetector) {
            stopRequestCount += 1
        }
    }

    struct Harness {
        let detector: SilenceDetector
        let delegate: StubDelegate
        let clock: TestClock
        let logger: MockLogger
    }

    func makeHarness(silenceTimeout: Double = 0.2) -> Harness {
        let logger = MockLogger()
        let clock = TestClock()
        let detector = SilenceDetector(logger: logger, clock: clock)
        detector.silenceTimeout = silenceTimeout
        let delegate = StubDelegate()
        detector.delegate = delegate
        return Harness(detector: detector, delegate: delegate, clock: clock, logger: logger)
    }

    /// Matches the broadband/speech-band split used by
    /// `Constants.silenceSpeechBandWeights` — levels are 7 floats per sample.
    static let speechLevels: [Float] = [0.1, 0.15, 0.12, 0.08, 0.1, 0.09, 0.11]
    static let silentLevels: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001]

    // MARK: - Core auto-close behaviour

    @Test("Auto-close fires once silence persists past the timeout")
    func autoCloseFiresAfterTimeout() {
        let h = makeHarness(silenceTimeout: 0.2)

        // Seed a speech peak so the relative threshold is non-trivial.
        h.detector.evaluate(levels: Self.speechLevels)

        // Now there's transcript content — silence timer can arm.
        h.delegate.currentPartialTranscript = "hello world"

        // Drive silence forward across the timeout boundary.
        for _ in 0..<12 {
            h.clock.advance(by: 0.1)
            h.detector.evaluate(levels: Self.silentLevels)
            if h.delegate.stopRequestCount > 0 { break }
        }

        #expect(h.delegate.stopRequestCount == 1)
        #expect(h.logger.infoMessages.contains { $0.contains("Silence auto-close after") })
    }

    @Test("Auto-close does not fire before any speech has been observed")
    func autoCloseWaitsForSpeech() {
        let h = makeHarness(silenceTimeout: 0.2)

        for _ in 0..<10 {
            h.clock.advance(by: 0.1)
            h.detector.evaluate(levels: Self.silentLevels)
        }

        #expect(h.delegate.stopRequestCount == 0)
    }

    @Test("Auto-close is suspended while the hold indicator is showing")
    func autoCloseSuspendedWhileHolding() {
        let h = makeHarness(silenceTimeout: 0.2)

        h.detector.evaluate(levels: Self.speechLevels)
        h.delegate.currentPartialTranscript = "hold speech"
        h.delegate.currentShowsHoldIndicator = true

        for _ in 0..<10 {
            h.clock.advance(by: 0.1)
            h.detector.evaluate(levels: Self.silentLevels)
        }

        #expect(h.delegate.stopRequestCount == 0)
        #expect(!h.logger.infoMessages.contains { $0.contains("Silence auto-close after") })
    }

    @Test("Auto-close disabled when timeout is zero")
    func autoCloseDisabledWhenTimeoutZero() {
        let h = makeHarness(silenceTimeout: 0)

        h.detector.evaluate(levels: Self.speechLevels)
        h.delegate.currentPartialTranscript = "hello"

        for _ in 0..<20 {
            h.clock.advance(by: 0.1)
            h.detector.evaluate(levels: Self.silentLevels)
        }

        #expect(h.delegate.stopRequestCount == 0)
    }

    @Test("Silence timer resets when speech resumes mid-session")
    func silenceTimerResetsOnSpeech() {
        let h = makeHarness(silenceTimeout: 1.0)

        h.detector.evaluate(levels: Self.speechLevels)
        h.delegate.currentPartialTranscript = "hello"

        // Quiet for 600ms — below the 1s timeout.
        for _ in 0..<6 {
            h.clock.advance(by: 0.1)
            h.detector.evaluate(levels: Self.silentLevels)
        }
        #expect(h.delegate.stopRequestCount == 0)

        // Speech resumes — should clear the silence timer.
        h.clock.advance(by: 0.05)
        h.detector.evaluate(levels: Self.speechLevels)
        h.delegate.currentPartialTranscript = "hello world"

        // Another 600ms quiet — still under the full timeout since reset.
        for _ in 0..<6 {
            h.clock.advance(by: 0.1)
            h.detector.evaluate(levels: Self.silentLevels)
        }
        #expect(h.delegate.stopRequestCount == 0)
    }

    // MARK: - Transcript activity bookkeeping

    @Test("Meaningful partial transcript updates set the meaningful-transcript flag")
    func meaningfulTranscriptMarksFlag() {
        let h = makeHarness()
        let merged = h.detector.applyIncomingPartialTranscript(
            "hello",
            at: h.clock.now(),
            previousPartial: ""
        )
        #expect(merged == "hello")
        #expect(h.detector.hasObservedMeaningfulTranscript)
    }

    @Test("Annotation-only packets are suppressed and do not advance transcript state")
    func annotationOnlyPacketsSuppressed() {
        let h = makeHarness()
        let merged = h.detector.applyIncomingPartialTranscript(
            "[BLANK_AUDIO]",
            at: h.clock.now(),
            previousPartial: ""
        )
        #expect(merged == nil)
        #expect(!h.detector.hasObservedMeaningfulTranscript)
    }

    @Test("estimatedTranscriptActiveSeconds adds a tail cap after the final packet")
    func estimatedTranscriptActiveSecondsAddsTail() {
        let h = makeHarness()

        _ = h.detector.applyIncomingPartialTranscript(
            "one",
            at: h.clock.now(),
            previousPartial: ""
        )
        h.clock.advance(by: 0.3)
        _ = h.detector.applyIncomingPartialTranscript(
            "one two",
            at: h.clock.now(),
            previousPartial: "one"
        )

        // Simulate recording ending 0.2s after the last packet.
        let recordingEnd = h.clock.now().addingTimeInterval(0.2)
        let active = h.detector.estimatedTranscriptActiveSeconds(until: recordingEnd)
        #expect(active > 0)
    }

    // MARK: - Reset semantics

    @Test("resetForNewSession clears timer + transcript bookkeeping")
    func resetClearsState() {
        let h = makeHarness(silenceTimeout: 0.2)

        h.detector.evaluate(levels: Self.speechLevels)
        h.delegate.currentPartialTranscript = "hello"
        h.clock.advance(by: 0.1)
        h.detector.evaluate(levels: Self.silentLevels)

        h.detector.resetForNewSession()

        #expect(!h.detector.hasObservedMeaningfulTranscript)
        #expect(!h.detector.hasSeenTranscriptPacket)
        #expect(h.detector.transcriptActiveSeconds == 0)
    }
}
