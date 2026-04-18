import Foundation

protocol SilenceDetectorDelegate: AnyObject {
    var currentDictationState: DictationState { get }
    var currentShowsHoldIndicator: Bool { get }
    var currentPartialTranscript: String { get }
    func silenceDetectorDidRequestStopRecording(_ detector: SilenceDetector)
}

/// Evaluates microphone level samples + partial-transcript packets to decide
/// when a recording session has gone quiet long enough to auto-close. Owns
/// ambient-noise calibration, speech-band dominance classification, audio
/// motion smoothing, and the transcript-activity bookkeeping that records
/// "effective speaking time" for usage stats.
///
/// Mutable state is MainActor-only — every public entry point is called from
/// the main actor (audio level callback routes through `MainActor.run`, and
/// transcript packets are applied after a `MainActor.run` hop).
final class SilenceDetector {
    weak var delegate: SilenceDetectorDelegate?
    private let logger: LoggingServiceProtocol
    private let clock: ClockProtocol

    var silenceTimeout: Double = 0

    private var silenceStartTime: Date?
    private var peakSpeechLevel: Float = 0
    private var ambientNoiseLevel: Float = Constants.silenceAbsoluteFloor
    private var lastSilenceEvaluationAt: Date?
    private var silenceCandidateStartTime: Date?
    private var lastObservedPartialTranscript: String = ""
    private var lastTranscriptContentUpdateAt: Date?
    private var lastTranscriptActivityAt: Date?
    private var lastTranscriptPacketAt: Date?
    private var transcriptPacketIntervalEWMA: TimeInterval?
    private(set) var transcriptActiveSeconds: TimeInterval = 0
    private(set) var hasObservedMeaningfulTranscript = false
    private var previousAudioLevels: [Float]?
    private var recentAudioMotionSamples: [(timestamp: Date, motion: Float)] = []

    init(logger: LoggingServiceProtocol, clock: ClockProtocol = SystemClock()) {
        self.logger = logger
        self.clock = clock
    }

    var hasSeenTranscriptPacket: Bool { lastTranscriptPacketAt != nil }

    func resetForNewSession() {
        silenceStartTime = nil
        silenceCandidateStartTime = nil
        peakSpeechLevel = 0
        ambientNoiseLevel = Constants.silenceAbsoluteFloor
        lastSilenceEvaluationAt = nil
        lastObservedPartialTranscript = ""
        lastTranscriptContentUpdateAt = nil
        lastTranscriptActivityAt = nil
        lastTranscriptPacketAt = nil
        transcriptPacketIntervalEWMA = nil
        transcriptActiveSeconds = 0
        hasObservedMeaningfulTranscript = false
        previousAudioLevels = nil
        recentAudioMotionSamples.removeAll()
    }

    func resetEvaluationWindow() {
        silenceStartTime = nil
        silenceCandidateStartTime = nil
        lastSilenceEvaluationAt = nil
        previousAudioLevels = nil
        recentAudioMotionSamples.removeAll()
    }

    /// Called when an ASR partial packet arrives. Sanitizes and merges with the
    /// previous partial; returns the merged string if it should replace the
    /// caller's partial, or nil if the packet was suppressed / produced no change.
    func applyIncomingPartialTranscript(
        _ incomingText: String,
        at now: Date,
        previousPartial: String
    ) -> String? {
        let transcriptStaleness = lastTranscriptContentUpdateAt
            .map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let sanitizedIncomingText: String
        if TranscriptArtifactFilter.shouldRunFullFiltering(incomingText) {
            let sanitizedIncomingResult = TranscriptArtifactFilter.sanitize(incomingText)
            if sanitizedIncomingResult.removedMarkerCount > 0 {
                logger.info(
                    "Filtered \(sanitizedIncomingResult.removedMarkerCount) non-speech marker(s) from partial transcript packet"
                )
            }
            let trailingPartialStripResult = TranscriptArtifactFilter.stripTrailingStandaloneAnnotations(
                sanitizedIncomingResult.text
            )
            if trailingPartialStripResult.removedAnnotationCount > 0 {
                logger.info(
                    "Stripped \(trailingPartialStripResult.removedAnnotationCount) trailing non-speech annotation(s) from partial transcript packet"
                )
            }
            sanitizedIncomingText = trailingPartialStripResult.text
        } else {
            sanitizedIncomingText = incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if TranscriptArtifactFilter.isOnlyStandaloneAnnotations(sanitizedIncomingText)
            || TranscriptArtifactFilter.isOnlyStandaloneBracketedAnnotations(sanitizedIncomingText) {
            logger.info("Suppressing annotation-only partial transcript packet")
            return nil
        }
        let hasPacketText = !sanitizedIncomingText.isEmpty

        if hasPacketText {
            noteTranscriptPacketActivity(at: now)
        } else {
            return nil
        }

        let allowAggressiveRecovery = transcriptStaleness
            >= Constants.partialTranscriptAggressiveRecoveryAfterSeconds
        let mergedPartial = PartialTranscriptMerger.merge(
            previous: previousPartial,
            incoming: sanitizedIncomingText,
            allowAggressiveRecovery: allowAggressiveRecovery
        )

        guard mergedPartial != previousPartial else { return nil }
        lastTranscriptContentUpdateAt = now
        lastObservedPartialTranscript = mergedPartial
        if !mergedPartial.isEmpty {
            hasObservedMeaningfulTranscript = true
        }
        return mergedPartial
    }

    func estimatedTranscriptActiveSeconds(until recordingEndedAt: Date) -> TimeInterval {
        var seconds = transcriptActiveSeconds

        if let lastTranscriptPacketAt {
            let tailSeconds = max(0, recordingEndedAt.timeIntervalSince(lastTranscriptPacketAt))
            let tailCapBase = transcriptPacketIntervalEWMA ?? 0.5
            let tailCap = max(0.25, min(3.0, tailCapBase * 1.5))
            seconds += min(tailSeconds, tailCap)
        }

        return seconds
    }

    func evaluate(levels: [Float]) {
        guard silenceTimeout > 0 else { return }
        guard let delegate else { return }
        let now = clock.now()

        guard delegate.currentDictationState == .listening else {
            resetEvaluationWindow()
            return
        }

        guard !delegate.currentShowsHoldIndicator else {
            resetEvaluationWindow()
            return
        }

        let partialTranscript = delegate.currentPartialTranscript
        if partialTranscript != lastObservedPartialTranscript {
            lastObservedPartialTranscript = partialTranscript
            if !partialTranscript.isEmpty {
                lastTranscriptContentUpdateAt = now
                if lastTranscriptActivityAt == nil {
                    lastTranscriptActivityAt = now
                }
            }
        }

        let averageLevel = silenceSignalLevel(for: levels)
        let elapsedSinceLastEvaluation: TimeInterval
        if let lastEvaluation = lastSilenceEvaluationAt {
            let elapsed = max(0, now.timeIntervalSince(lastEvaluation))
            elapsedSinceLastEvaluation = elapsed
            let decayBase = Double(Constants.silencePeakDecayPerSecond)
            let decayedPeak = peakSpeechLevel * Float(pow(decayBase, elapsed))
            peakSpeechLevel = max(decayedPeak, averageLevel)
        } else {
            elapsedSinceLastEvaluation = 0
            peakSpeechLevel = max(peakSpeechLevel, averageLevel)
        }
        lastSilenceEvaluationAt = now

        let transcriptGrace = max(
            Constants.silenceTranscriptActivityGraceMinimumSeconds,
            silenceTimeout * Constants.silenceTranscriptActivityGraceMultiplier
        )
        let clampedTranscriptGrace = min(
            transcriptGrace,
            Constants.silenceTranscriptActivityGraceMaximumSeconds
        )
        let transcriptRecentlyUpdated = lastTranscriptContentUpdateAt
            .map { now.timeIntervalSince($0) < clampedTranscriptGrace } ?? false
        let shouldRelaxAmbientSampleCap = !partialTranscript.isEmpty && !transcriptRecentlyUpdated
        let currentAudioMotion = currentAudioMotion(for: levels)

        var ambientSampleCap = max(
            Constants.silenceAbsoluteFloor * 2,
            peakSpeechLevel * Constants.silenceAmbientTrackingPeakFraction
        )
        if shouldRelaxAmbientSampleCap {
            ambientSampleCap = max(
                ambientSampleCap,
                peakSpeechLevel * Constants.silenceAmbientTrackingRelaxedPeakFraction
            )
        }
        if averageLevel <= ambientSampleCap {
            let riseAlpha = exponentialSmoothingAlpha(
                ratePerSecond: Constants.silenceAmbientTrackingRisePerSecond,
                elapsed: elapsedSinceLastEvaluation
            )
            let fallAlpha = exponentialSmoothingAlpha(
                ratePerSecond: Constants.silenceAmbientTrackingFallPerSecond,
                elapsed: elapsedSinceLastEvaluation
            )
            let alpha: Float
            if averageLevel > ambientNoiseLevel {
                if currentAudioMotion >= Constants.silenceMotionAbsoluteFloor {
                    alpha = 0
                } else {
                    alpha = shouldRelaxAmbientSampleCap ? max(riseAlpha, fallAlpha) : riseAlpha
                }
            } else {
                alpha = fallAlpha
            }
            ambientNoiseLevel += (averageLevel - ambientNoiseLevel) * alpha
        }
        ambientNoiseLevel = max(Constants.silenceAbsoluteFloor, ambientNoiseLevel)

        let rawThreshold = max(
            peakSpeechLevel * Constants.silenceRelativeThreshold,
            Constants.silenceAbsoluteFloor
        )
        let ambientThreshold = max(
            ambientNoiseLevel * Constants.silenceAmbientThresholdMultiplier,
            ambientNoiseLevel + Constants.silenceAmbientThresholdOffset
        )
        let threshold = max(
            rawThreshold,
            ambientThreshold
        )
        let speechActivityThreshold = max(
            threshold * Constants.silenceSpeechActivityThresholdMultiplier,
            threshold + Constants.silenceSpeechActivityThresholdOffset
        )
        let continuationThreshold = max(
            Constants.silenceAbsoluteFloor
                * Constants.silenceTranscriptContinuationMinimumLevelMultiplier,
            ambientNoiseLevel + Constants.silenceTranscriptContinuationThresholdOffset,
            threshold * Constants.silenceTranscriptContinuationThresholdMultiplier
        )
        let speechBandDominance = speechBandDominance(
            for: levels,
            signalLevel: averageLevel
        )
        let audioMotion = noteAudioMotion(currentAudioMotion, levels: levels, at: now)
        let motionThreshold = max(
            Constants.silenceMotionAbsoluteFloor,
            continuationThreshold * Constants.silenceMotionThresholdMultiplier
        )
        let silenceState = classifySilenceState(
            signalLevel: averageLevel,
            ambientLevel: ambientNoiseLevel,
            threshold: threshold,
            speechActivityThreshold: speechActivityThreshold,
            continuationThreshold: continuationThreshold,
            recentAudioMotion: audioMotion,
            motionThreshold: motionThreshold
        )
        let metrics = SilenceMetrics(
            signalLevel: averageLevel,
            speechBandDominance: speechBandDominance,
            rawThreshold: rawThreshold,
            ambientThreshold: ambientThreshold,
            threshold: threshold,
            speechActivityThreshold: speechActivityThreshold,
            continuationThreshold: continuationThreshold,
            audioMotion: audioMotion,
            motionThreshold: motionThreshold,
            silenceState: silenceState
        )

        switch silenceState {
        case .strongSpeech:
            clearSilenceTimer(
                reason: "strong speech",
                now: now,
                metrics: metrics
            )
            return
        case .activeContinuation:
            clearSilenceTimer(
                reason: "continuation audio",
                now: now,
                metrics: metrics
            )
            return
        case .candidateSilence:
            break
        }

        // Audio is below threshold — only start timer after meaningful transcript
        // content has appeared. Leading non-speech ASR markers are ignored.
        guard !partialTranscript.isEmpty else {
            silenceCandidateStartTime = nil
            return
        }

        if transcriptRecentlyUpdated && silenceStartTime == nil {
            silenceCandidateStartTime = nil
            return
        }

        if silenceStartTime == nil {
            let silenceArmDelay = silenceTimerArmDelay()
            if let silenceCandidateStartTime {
                guard now.timeIntervalSince(silenceCandidateStartTime) >= silenceArmDelay else {
                    return
                }
            } else {
                silenceCandidateStartTime = now
                return
            }
            silenceCandidateStartTime = nil
            silenceStartTime = now
            logSilenceEvent(
                "Silence timer started",
                now: now,
                metrics: metrics
            )
        }

        if let start = silenceStartTime,
           now.timeIntervalSince(start) >= silenceTimeout {
            logSilenceEvent(
                "Silence auto-close after \(silenceTimeout)s",
                now: now,
                metrics: metrics
            )
            silenceStartTime = nil
            delegate.silenceDetectorDidRequestStopRecording(self)
        }
    }

    // MARK: - Internal helpers

    private enum SilenceState: String {
        case strongSpeech
        case activeContinuation
        case candidateSilence
    }

    private struct SilenceMetrics {
        let signalLevel: Float
        let speechBandDominance: Float
        let rawThreshold: Float
        let ambientThreshold: Float
        let threshold: Float
        let speechActivityThreshold: Float
        let continuationThreshold: Float
        let audioMotion: Float
        let motionThreshold: Float
        let silenceState: SilenceState
    }

    private func exponentialSmoothingAlpha(ratePerSecond: Float, elapsed: TimeInterval) -> Float {
        guard elapsed > 0 else { return 0 }
        let clampedRate = min(max(ratePerSecond, 0), 1)
        guard clampedRate < 1 else { return 1 }
        return 1 - Float(pow(Double(1 - clampedRate), elapsed))
    }

    private func speechBandDominance(for levels: [Float], signalLevel: Float) -> Float {
        guard !levels.isEmpty else { return 0 }
        let broadbandLevel = levels.reduce(0, +) / Float(levels.count)
        guard broadbandLevel > 0 else { return 0 }
        return signalLevel / broadbandLevel
    }

    private func classifySilenceState(
        signalLevel: Float,
        ambientLevel: Float,
        threshold: Float,
        speechActivityThreshold: Float,
        continuationThreshold: Float,
        recentAudioMotion: Float,
        motionThreshold: Float
    ) -> SilenceState {
        if signalLevel >= speechActivityThreshold {
            return .strongSpeech
        }

        let motionQualifiedSignalFloor = max(
            continuationThreshold,
            ambientLevel + Constants.silenceMotionContinuationSignalOffset,
            threshold * Constants.silenceMotionContinuationThresholdMinimumFraction
        )

        if signalLevel >= continuationThreshold
            && signalLevel >= motionQualifiedSignalFloor
            && (
                signalLevel >= threshold
                    || recentAudioMotion >= motionThreshold
            ) {
            return .activeContinuation
        }

        return .candidateSilence
    }

    private func noteTranscriptPacketActivity(at now: Date) {
        if let lastTranscriptPacketAt {
            let observedInterval = max(0, now.timeIntervalSince(lastTranscriptPacketAt))
            if observedInterval > 0 {
                let priorPacketIntervalEWMA = transcriptPacketIntervalEWMA
                if let existingEWMA = transcriptPacketIntervalEWMA {
                    let alpha = Constants.silenceTranscriptPacketIntervalEWMASmoothing
                    transcriptPacketIntervalEWMA =
                        existingEWMA + (observedInterval - existingEWMA) * alpha
                } else {
                    transcriptPacketIntervalEWMA = observedInterval
                }

                let activityCapBase = priorPacketIntervalEWMA ?? observedInterval
                let activityCap = max(0.25, min(8.0, activityCapBase * 3.0))
                transcriptActiveSeconds += min(observedInterval, activityCap)
            }
        } else {
            transcriptActiveSeconds += 0.25
        }
        lastTranscriptPacketAt = now
        lastTranscriptActivityAt = now
    }

    private func clearSilenceTimer(reason: String, now: Date, metrics: SilenceMetrics) {
        silenceCandidateStartTime = nil
        guard silenceStartTime != nil else { return }
        silenceStartTime = nil
        logSilenceEvent(
            "Silence timer cleared by \(reason)",
            now: now,
            metrics: metrics
        )
    }

    private func logSilenceEvent(_ event: String, now: Date, metrics: SilenceMetrics) {
        logger.info(
            "\(event) " +
            "(avg \(formattedSilenceValue(metrics.signalLevel)), " +
            "peak \(formattedSilenceValue(peakSpeechLevel)), " +
            "ambient \(formattedSilenceValue(ambientNoiseLevel)), " +
            "rawThreshold \(formattedSilenceValue(metrics.rawThreshold)), " +
            "ambientThreshold \(formattedSilenceValue(metrics.ambientThreshold)), " +
            "threshold \(formattedSilenceValue(metrics.threshold)), " +
            "continuationThreshold \(formattedSilenceValue(metrics.continuationThreshold)), " +
            "activityThreshold \(formattedSilenceValue(metrics.speechActivityThreshold)), " +
            "audioMotion \(formattedSilenceValue(metrics.audioMotion)), " +
            "motionThreshold \(formattedSilenceValue(metrics.motionThreshold)), " +
            "silenceState \(metrics.silenceState.rawValue), " +
            "speechBandDominance \(formattedSilenceValue(metrics.speechBandDominance)), " +
            "transcriptContentAge \(formattedSilenceAge(lastTranscriptContentUpdateAt, now: now)), " +
            "transcriptActivityAge \(formattedSilenceAge(lastTranscriptActivityAt, now: now)), " +
            "packetInterval \(formattedSilenceInterval(transcriptPacketIntervalEWMA))"
        )
    }

    private func formattedSilenceValue(_ value: Float) -> String {
        String(format: "%.4f", value)
    }

    private func formattedSilenceAge(_ date: Date?, now: Date) -> String {
        guard let date else { return "n/a" }
        return String(format: "%.2fs", now.timeIntervalSince(date))
    }

    private func formattedSilenceInterval(_ interval: TimeInterval?) -> String {
        guard let interval else { return "n/a" }
        return String(format: "%.2fs", interval)
    }

    private func silenceTimerArmDelay() -> TimeInterval {
        let scaledDelay = silenceTimeout * Constants.silenceTimerArmDelayTimeoutFraction
        return min(
            max(scaledDelay, Constants.silenceTimerArmDelayMinimumSeconds),
            Constants.silenceTimerArmDelayMaximumSeconds
        )
    }

    private func noteAudioMotion(_ motion: Float, levels: [Float], at now: Date) -> Float {
        previousAudioLevels = levels
        recentAudioMotionSamples.append((timestamp: now, motion: motion))
        return recentAudioMotion(now: now)
    }

    private func currentAudioMotion(for levels: [Float]) -> Float {
        guard let previousAudioLevels,
              previousAudioLevels.count == levels.count else {
            return 0
        }
        return audioMotion(for: levels, previousLevels: previousAudioLevels)
    }

    private func recentAudioMotion(now: Date) -> Float {
        let windowStart = now.addingTimeInterval(-Constants.silenceMotionWindowSeconds)
        recentAudioMotionSamples.removeAll { $0.timestamp < windowStart }
        guard !recentAudioMotionSamples.isEmpty else { return 0 }

        let sum = recentAudioMotionSamples.reduce(Float.zero) { partialResult, sample in
            partialResult + sample.motion
        }
        return sum / Float(recentAudioMotionSamples.count)
    }

    private func audioMotion(for levels: [Float], previousLevels: [Float]) -> Float {
        guard levels.count == previousLevels.count else { return 0 }

        let weights = Constants.silenceSpeechBandWeights
        guard levels.count == weights.count else {
            assertionFailure(
                "audioMotion: levels.count (\(levels.count)) != silenceSpeechBandWeights.count (\(weights.count)); falling back to unweighted delta mean."
            )
            logger.warn(
                "audioMotion band-count mismatch: levels.count=\(levels.count), weights.count=\(weights.count); falling back to unweighted delta mean."
            )
            let deltas = zip(levels, previousLevels).map { abs($0 - $1) }
            guard !deltas.isEmpty else { return 0 }
            return deltas.reduce(0, +) / Float(deltas.count)
        }

        let weightTotal = weights.reduce(0, +)
        guard weightTotal > 0 else { return 0 }

        var weightedDeltaSum: Float = 0
        for ((level, previousLevel), weight) in zip(zip(levels, previousLevels), weights) {
            weightedDeltaSum += abs(level - previousLevel) * weight
        }
        return weightedDeltaSum / weightTotal
    }

    private func silenceSignalLevel(for levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 0 }

        let weights = Constants.silenceSpeechBandWeights
        guard levels.count == weights.count else {
            assertionFailure(
                "silenceSignalLevel: levels.count (\(levels.count)) != silenceSpeechBandWeights.count (\(weights.count)); falling back to unweighted mean."
            )
            logger.warn(
                "silenceSignalLevel band-count mismatch: levels.count=\(levels.count), weights.count=\(weights.count); falling back to unweighted mean."
            )
            return levels.reduce(0, +) / Float(levels.count)
        }

        let weightTotal = weights.reduce(0, +)
        guard weightTotal > 0 else {
            return levels.reduce(0, +) / Float(levels.count)
        }

        var weightedSum: Float = 0
        for (level, weight) in zip(levels, weights) {
            weightedSum += level * weight
        }
        return weightedSum / weightTotal
    }
}
