import Testing
import Foundation
@testable import HanzoCore

private actor DelayedSessionASRClient: ASRClientProtocol {
    private var startCounter = 0

    func startStream() async throws -> String {
        startCounter += 1
        return startCounter == 1 ? "session-1" : "session-2"
    }

    func sendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        if sessionId == "session-1" {
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return ASRChunkResponse(text: "stale from session one", language: "en")
        }

        return ASRChunkResponse(text: "fresh from session two", language: "en")
    }

    func finishStream(sessionId: String) async throws -> ASRFinishResponse {
        ASRFinishResponse(text: "", language: "en")
    }
}

private actor SlowFinishingASRClient: ASRClientProtocol {
    func startStream() async throws -> String {
        "slow-finish-session"
    }

    func sendChunk(sessionId: String, pcmData: Data) async throws -> ASRChunkResponse {
        ASRChunkResponse(text: "streaming transcript", language: "en")
    }

    func finishStream(sessionId: String) async throws -> ASRFinishResponse {
        try? await Task.sleep(nanoseconds: 400_000_000)
        return ASRFinishResponse(text: "final transcript", language: "en")
    }
}

@Suite("DictationOrchestrator")
struct DictationOrchestratorTests {

    // MARK: - Helpers

    struct SUT {
        let orchestrator: DictationOrchestrator
        let appState: AppState
        let mockASR: MockASRClient
        let mockAudio: MockAudioCaptureService
        let mockText: MockTextInsertionService
        let mockPerms: MockPermissionService
        let mockLogger: MockLogger
    }

    func makeSUT(
        micPermission: Bool = true,
        asrStartResult: Result<String, Error> = .success("test-session"),
        asrChunkResult: Result<ASRChunkResponse, Error> = .success(
            ASRChunkResponse(text: "partial", language: "en")
        ),
        asrFinishResult: Result<ASRFinishResponse, Error> = .success(
            ASRFinishResponse(text: "final transcript", language: "en")
        ),
        audioThrowOnStart: Error? = nil
    ) -> SUT {
        let appState = AppState()
        let mockASR = MockASRClient()
        mockASR.startStreamResult = asrStartResult
        mockASR.sendChunkResult = asrChunkResult
        mockASR.finishStreamResult = asrFinishResult

        let mockAudio = MockAudioCaptureService()
        mockAudio.throwOnStart = audioThrowOnStart

        let mockText = MockTextInsertionService()
        let mockPerms = MockPermissionService()
        mockPerms.hasMicrophonePermission = micPermission
        let mockLogger = MockLogger()

        let orchestrator = DictationOrchestrator(
            appState: appState,
            asrClient: mockASR,
            audioService: mockAudio,
            textInsertion: mockText,
            permissionService: mockPerms,
            logger: mockLogger
        )
        return SUT(
            orchestrator: orchestrator,
            appState: appState,
            mockASR: mockASR,
            mockAudio: mockAudio,
            mockText: mockText,
            mockPerms: mockPerms,
            mockLogger: mockLogger
        )
    }

    // MARK: - Initial State

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        let sut = makeSUT()
        #expect(sut.appState.dictationState == .idle)
    }

    // MARK: - toggle() from idle → listening

    @Test("toggle() from idle sets state to listening when mic permission granted")
    @MainActor func toggleIdleToListening() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        #expect(sut.appState.dictationState == .listening)
    }

    @Test("toggle() from idle starts ASR session")
    @MainActor func toggleStartsASRSession() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sut.mockASR.startStreamCallCount == 1)
    }

    @Test("toggle() from idle starts audio capture")
    @MainActor func toggleStartsAudioCapture() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sut.mockAudio.startCaptureCalled == true)
    }

    @Test("toggle() from idle sets isPopoverPresented to true")
    @MainActor func toggleSetsPopoverPresented() {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        #expect(sut.appState.isPopoverPresented == true)
    }

    @Test("toggle() from idle transitions to error when mic permission denied")
    @MainActor func toggleNoMicPermission() {
        let sut = makeSUT(micPermission: false)
        sut.orchestrator.toggle()
        #expect(sut.appState.dictationState == .error)
        #expect(sut.appState.errorMessage != nil)
    }

    // MARK: - toggle() from idle → error (ASR failure)

    @Test("toggle() transitions to error state when ASR start fails")
    @MainActor func toggleASRStartFailure() async throws {
        let sut = makeSUT(
            asrStartResult: .failure(ASRError.authenticationFailed)
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sut.appState.dictationState == .error)
    }

    @Test("toggle() transitions to error state when audio capture fails")
    @MainActor func toggleAudioCaptureFailure() async throws {
        let sut = makeSUT(
            audioThrowOnStart: AudioCaptureError.converterCreationFailed
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sut.appState.dictationState == .error)
    }

    // MARK: - toggle() from listening → forging

    @Test("toggle() from listening transitions to forging")
    @MainActor func toggleListeningToForging() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sut.appState.dictationState == .listening)
        sut.orchestrator.toggle()
        #expect(sut.appState.dictationState == .forging)
    }

    @Test("toggle() from listening stops audio capture")
    @MainActor func toggleStopsAudioCapture() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()
        #expect(sut.mockAudio.stopCaptureCalled == true)
    }

    @Test("Transcript remains visible while forging until HUD dismissal")
    @MainActor func transcriptRemainsVisibleDuringForging() async throws {
        let appState = AppState()
        let asr = SlowFinishingASRClient()
        let mockAudio = MockAudioCaptureService()
        let mockText = MockTextInsertionService()
        let mockPerms = MockPermissionService()
        mockPerms.hasMicrophonePermission = true
        let mockLogger = MockLogger()

        let orchestrator = DictationOrchestrator(
            appState: appState,
            asrClient: asr,
            audioService: mockAudio,
            textInsertion: mockText,
            permissionService: mockPerms,
            logger: mockLogger
        )

        orchestrator.toggle()
        try await Task.sleep(nanoseconds: 60_000_000)

        let chunk = Data(repeating: 0x01, count: Constants.chunkAccumulationBytes + 1)
        mockAudio.simulateChunk(chunk)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(appState.partialTranscript == "streaming transcript")

        orchestrator.toggle()
        #expect(appState.dictationState == .forging)
        #expect(appState.partialTranscript == "streaming transcript")
    }

    // MARK: - toggle() from forging (no-op)

    @Test("toggle() from forging state is ignored")
    @MainActor func toggleForgingIsNoOp() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle() // → forging
        let callCount = sut.mockASR.startStreamCallCount
        sut.orchestrator.toggle() // should be no-op
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sut.mockASR.startStreamCallCount == callCount)
    }

    // MARK: - toggle() from error → idle (reset)

    @Test("toggle() from error resets to idle")
    @MainActor func toggleErrorResetsToIdle() {
        let sut = makeSUT(micPermission: false)
        sut.orchestrator.toggle() // → error
        #expect(sut.appState.dictationState == .error)
        sut.orchestrator.toggle() // → reset → idle
        #expect(sut.appState.dictationState == .idle)
        #expect(sut.appState.errorMessage == nil)
    }

    // MARK: - cancel()

    @Test("cancel() from listening resets state")
    @MainActor func cancelFromListening() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sut.appState.dictationState == .idle)
    }

    @Test("cancel() clears partialTranscript")
    @MainActor func cancelClearsTranscript() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.appState.partialTranscript = "some partial text"
        sut.orchestrator.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sut.appState.partialTranscript == "")
    }

    @Test("cancel() stops audio capture")
    @MainActor func cancelStopsAudio() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.cancel()
        #expect(sut.mockAudio.stopCaptureCalled == true)
    }

    @Test("cancel() hides popover")
    @MainActor func cancelHidesPopover() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sut.appState.isPopoverPresented == false)
    }

    // MARK: - Audio buffer accumulation

    @Test("Audio chunk below threshold does not trigger sendChunk")
    @MainActor func audioBelowThreshold() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let smallChunk = Data(repeating: 0x00, count: 100)
        sut.mockAudio.simulateChunk(smallChunk)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(sut.mockASR.sendChunkCalls.isEmpty)
    }

    @Test("Audio chunks accumulate and trigger sendChunk at threshold")
    @MainActor func audioChunksTriggerSendAtThreshold() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let largeChunk = Data(repeating: 0x01, count: Constants.chunkAccumulationBytes + 1)
        sut.mockAudio.simulateChunk(largeChunk)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(sut.mockASR.sendChunkCalls.count == 1)
    }

    @Test("Audio chunk send uses correct session ID")
    @MainActor func audioChunkUsesSessionId() async throws {
        let sut = makeSUT(asrStartResult: .success("expected-session"))
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let largeChunk = Data(repeating: 0x01, count: Constants.chunkAccumulationBytes + 1)
        sut.mockAudio.simulateChunk(largeChunk)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(sut.mockASR.sendChunkCalls.first?.sessionId == "expected-session")
    }

    @Test("Chunk response updates partialTranscript")
    @MainActor func chunkResponseUpdatesTranscript() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "hello world", language: "en"))
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let largeChunk = Data(repeating: 0x01, count: Constants.chunkAccumulationBytes + 1)
        sut.mockAudio.simulateChunk(largeChunk)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(sut.appState.partialTranscript == "hello world")
    }

    @Test("Late chunk response from previous session is ignored")
    @MainActor func lateChunkResponseFromPreviousSessionIgnored() async throws {
        let appState = AppState()
        let delayedASR = DelayedSessionASRClient()
        let mockAudio = MockAudioCaptureService()
        let mockText = MockTextInsertionService()
        let mockPerms = MockPermissionService()
        mockPerms.hasMicrophonePermission = true
        let mockLogger = MockLogger()

        let orchestrator = DictationOrchestrator(
            appState: appState,
            asrClient: delayedASR,
            audioService: mockAudio,
            textInsertion: mockText,
            permissionService: mockPerms,
            logger: mockLogger
        )

        let chunk = Data(repeating: 0x01, count: Constants.chunkAccumulationBytes + 1)

        orchestrator.toggle() // Session 1
        try await Task.sleep(nanoseconds: 60_000_000)
        mockAudio.simulateChunk(chunk)

        orchestrator.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)

        orchestrator.toggle() // Session 2
        try await Task.sleep(nanoseconds: 60_000_000)
        mockAudio.simulateChunk(chunk)

        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(appState.partialTranscript == "fresh from session two")
    }

    // MARK: - Full flow: stop → finishStream

    @Test("finishStream is called with correct session ID when stopping")
    @MainActor func stopCallsFinishStream() async throws {
        let sut = makeSUT(asrStartResult: .success("flow-session-id"))
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.orchestrator.toggle() // stop
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(sut.mockASR.finishStreamCalls.first == "flow-session-id")
    }

    @Test("State returns to idle after successful stop")
    @MainActor func stateIdleAfterStop() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(sut.appState.dictationState == .idle)
    }

    @Test("finishStream failure transitions to error state")
    @MainActor func finishStreamFailureSetsError() async throws {
        let sut = makeSUT(
            asrFinishResult: .failure(ASRError.sessionNotFound)
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(sut.appState.dictationState == .error)
    }

    // MARK: - Audio Levels

    @Test("Audio levels callback updates appState.audioLevels")
    @MainActor func audioLevelsUpdatesAppState() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.mockAudio.simulateLevels([0.05, 0.1, 0.08, 0.12, 0.06, 0.09, 0.07])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(!sut.appState.audioLevels.isEmpty)
    }

    @Test("audioLevels resets to empty after cancel")
    @MainActor func audioLevelsResetsOnCancel() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.mockAudio.simulateLevels([0.05, 0.1, 0.08, 0.12, 0.06, 0.09, 0.07])
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.orchestrator.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(sut.appState.audioLevels.isEmpty)
    }

    // MARK: - Silence Auto-Close

    @Test("Silence auto-close triggers after timeout")
    @MainActor func silenceAutoCloseTriggersStop() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.2
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Simulate speech (above absolute floor)
        sut.mockAudio.simulateLevels([0.1, 0.15, 0.12, 0.08, 0.1, 0.09, 0.11])
        try await Task.sleep(nanoseconds: 100_000_000)

        // Simulate transcription arriving (silence timer only starts after words are transcribed)
        sut.appState.partialTranscript = "hello world"

        // Simulate silence repeatedly — well past the 200ms timeout
        let silentLevels: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001]
        for _ in 0..<10 {
            sut.mockAudio.simulateLevels(silentLevels)
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Should have triggered stopRecording (forging or idle)
        #expect(sut.appState.dictationState != .listening)
        #expect(sut.mockAudio.stopCaptureCalled == true)
    }

    @Test("Silence auto-close does not trigger before speech")
    @MainActor func silenceAutoCloseWaitsForSpeech() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.2
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Only silence — no speech first
        let silentLevels: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001]
        for _ in 0..<8 {
            sut.mockAudio.simulateLevels(silentLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Should still be listening
        #expect(sut.appState.dictationState == .listening)
    }

    @Test("Silence timer resets when speech resumes")
    @MainActor func silenceAutoCloseResetsOnSpeech() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 1.0
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Speech
        sut.mockAudio.simulateLevels([0.1, 0.15, 0.12, 0.08, 0.1, 0.09, 0.11])
        try await Task.sleep(nanoseconds: 50_000_000)

        // Simulate transcription arriving
        sut.appState.partialTranscript = "hello"

        // Brief silence (well under 1s timeout)
        let silentLevels: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001]
        for _ in 0..<3 {
            sut.mockAudio.simulateLevels(silentLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Speech resumes — resets timer
        sut.mockAudio.simulateLevels([0.1, 0.15, 0.12, 0.08, 0.1, 0.09, 0.11])
        try await Task.sleep(nanoseconds: 50_000_000)

        // Should still be listening
        #expect(sut.appState.dictationState == .listening)
    }

    @Test("Silence auto-close does not trigger with audio but no transcription")
    @MainActor func silenceAutoCloseWaitsForTranscription() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.2
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Speech-level audio (above threshold) but NO transcription
        sut.mockAudio.simulateLevels([0.1, 0.15, 0.12, 0.08, 0.1, 0.09, 0.11])
        try await Task.sleep(nanoseconds: 50_000_000)

        // Silence well past timeout — but no words transcribed
        let silentLevels: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001]
        for _ in 0..<10 {
            sut.mockAudio.simulateLevels(silentLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Should still be listening — no transcription means no silence timer
        #expect(sut.appState.dictationState == .listening)
    }

    @Test("Silence auto-close disabled when timeout is 0")
    @MainActor func silenceAutoCloseDisabledWhenZero() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.0
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Speech then silence
        sut.mockAudio.simulateLevels([0.1, 0.15, 0.12, 0.08, 0.1, 0.09, 0.11])
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.appState.partialTranscript = "hello"

        let silentLevels: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001]
        for _ in 0..<10 {
            sut.mockAudio.simulateLevels(silentLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Should still be listening — feature disabled
        #expect(sut.appState.dictationState == .listening)
    }
}
