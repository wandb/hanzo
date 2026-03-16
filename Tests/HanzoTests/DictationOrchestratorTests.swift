import Testing
import Foundation
import AppKit
@testable import HanzoCore

@Suite("DictationOrchestrator", .serialized)
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
        let mockLLM: MockLocalLLMRuntimeManager
    }

    func makeSUT(
        micPermission: Bool = true,
        accessibilityPermission: Bool = true,
        onboardingComplete: Bool = true,
        asrStartResult: Result<String, Error> = .success("test-session"),
        asrChunkResult: Result<ASRChunkResponse, Error> = .success(
            ASRChunkResponse(text: "partial", language: "en")
        ),
        asrFinishResult: Result<ASRFinishResponse, Error> = .success(
            ASRFinishResponse(text: "final transcript", language: "en")
        ),
        audioThrowOnStart: Error? = nil,
        localLLMRuntimeManager: MockLocalLLMRuntimeManager = MockLocalLLMRuntimeManager(),
        postProcessingMode: TranscriptPostProcessingMode = .off,
        llmPostProcessingPrompt: String = "",
        frontmostApplicationProvider: @escaping () -> NSRunningApplication? = { nil }
    ) -> SUT {
        // Set global post-processing settings so the orchestrator picks them up.
        AppBehaviorSettings.setGlobalPostProcessingMode(postProcessingMode)
        AppBehaviorSettings.setGlobalLLMPostProcessingPrompt(llmPostProcessingPrompt)

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
        mockPerms.hasAccessibilityPermission = accessibilityPermission
        let mockLogger = MockLogger()
        appState.isOnboardingComplete = onboardingComplete

        let orchestrator = DictationOrchestrator(
            appState: appState,
            asrClient: mockASR,
            audioService: mockAudio,
            textInsertion: mockText,
            permissionService: mockPerms,
            localLLMRuntimeManager: localLLMRuntimeManager,
            logger: mockLogger,
            frontmostApplicationProvider: frontmostApplicationProvider
        )
        return SUT(
            orchestrator: orchestrator,
            appState: appState,
            mockASR: mockASR,
            mockAudio: mockAudio,
            mockText: mockText,
            mockPerms: mockPerms,
            mockLogger: mockLogger,
            mockLLM: localLLMRuntimeManager
        )
    }

    @MainActor
    func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollNanoseconds: UInt64 = 20_000_000,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return condition()
    }

    // MARK: - Initial State

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        let sut = makeSUT()
        #expect(sut.appState.dictationState == .idle)
    }

    @Test("Init skips LLM prewarm while onboarding is incomplete")
    @MainActor func initSkipsLLMPrewarmWhenOnboardingIncomplete() async throws {
        let mockLLM = MockLocalLLMRuntimeManager()
        _ = makeSUT(
            onboardingComplete: false,
            localLLMRuntimeManager: mockLLM,
            postProcessingMode: .llm
        )

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(mockLLM.prepareModelCallCount == 0)
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
            logger: mockLogger,
            frontmostApplicationProvider: { nil }
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
            logger: mockLogger,
            frontmostApplicationProvider: { nil }
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
        let finished = await waitUntil {
            sut.mockASR.finishStreamCalls.first == "flow-session-id"
        }
        #expect(finished)
    }

    @Test("State returns to idle after successful stop")
    @MainActor func stateIdleAfterStop() async throws {
        let sut = makeSUT()
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.orchestrator.toggle()
        let isIdle = await waitUntil {
            sut.appState.dictationState == .idle
        }
        #expect(isIdle)
    }

    @Test("finishStream failure transitions to error state")
    @MainActor func finishStreamFailureSetsError() async throws {
        let sut = makeSUT(
            asrFinishResult: .failure(ASRError.sessionNotFound)
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.orchestrator.toggle()
        let isError = await waitUntil {
            sut.appState.dictationState == .error
        }
        #expect(isError)
    }

    @Test("Final transcript is post-processed before insertion when filter is enabled")
    @MainActor func finalTranscriptPostProcessedBeforeInsertion() async throws {
        let sut = makeSUT(
            asrFinishResult: .success(
                ASRFinishResponse(text: "Um I feel like this is, like, great uh.", language: "en")
            ),
            postProcessingMode: .removeVerbalPauses,
            frontmostApplicationProvider: { NSRunningApplication.current }
        )

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let inserted = await waitUntil(timeoutNanoseconds: 4_000_000_000) {
            sut.mockText.insertedTexts.count == 1
        }
        #expect(inserted)
        #expect(sut.mockText.insertedTexts.first == "I feel like this is great.")
    }

    @Test("Final transcript is unchanged when verbal pause filter is disabled")
    @MainActor func finalTranscriptUnchangedWhenFilterDisabled() async throws {
        let sut = makeSUT(
            asrFinishResult: .success(
                ASRFinishResponse(text: "Um this is still untouched.", language: "en")
            ),
            postProcessingMode: .off,
            frontmostApplicationProvider: { NSRunningApplication.current }
        )

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let inserted = await waitUntil(timeoutNanoseconds: 4_000_000_000) {
            sut.mockText.insertedTexts.count == 1
        }
        #expect(inserted)
        #expect(sut.mockText.insertedTexts.first == "Um this is still untouched.")
    }

    @Test("Final transcript uses LLM post-processing output when mode is LLM")
    @MainActor func finalTranscriptUsesLLMOutputWhenModeEnabled() async throws {
        let mockLLM = MockLocalLLMRuntimeManager()
        mockLLM.postProcessResult = .success("This is concise and professional.")

        let sut = makeSUT(
            asrFinishResult: .success(
                ASRFinishResponse(text: "Um this is, like, the update uh", language: "en")
            ),
            localLLMRuntimeManager: mockLLM,
            postProcessingMode: .llm,
            llmPostProcessingPrompt: "Make this concise and professional.",
            frontmostApplicationProvider: { NSRunningApplication.current }
        )

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let inserted = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            sut.mockText.insertedTexts.count == 1
        }
        #expect(inserted)
        #expect(sut.mockText.insertedTexts.first == "This is concise and professional.")
        #expect(mockLLM.postProcessCallCount == 1)
        #expect(mockLLM.lastPrompt == "Make this concise and professional.")
    }

    @Test("LLM mode falls back to cleaned transcript when local LLM processing fails")
    @MainActor func llmModeFallsBackWhenLocalLLMProcessingFails() async throws {
        let mockLLM = MockLocalLLMRuntimeManager()
        mockLLM.postProcessResult = .failure(LocalLLMRuntimeError.serverNotReady)

        let sut = makeSUT(
            asrFinishResult: .success(
                ASRFinishResponse(text: "Um I feel like this is, like, great uh.", language: "en")
            ),
            localLLMRuntimeManager: mockLLM,
            postProcessingMode: .llm,
            llmPostProcessingPrompt: "Make this concise and professional.",
            frontmostApplicationProvider: { NSRunningApplication.current }
        )

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let inserted = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            sut.mockText.insertedTexts.count == 1
        }
        #expect(inserted)
        #expect(sut.mockText.insertedTexts.first == "I feel like this is great.")
        #expect(mockLLM.postProcessCallCount == 1)
    }

    @Test("LLM mode falls back to cleaned transcript when local LLM processing times out")
    @MainActor func llmModeFallsBackWhenLocalLLMProcessingTimesOut() async throws {
        let mockLLM = MockLocalLLMRuntimeManager()
        mockLLM.postProcessDelayNanoseconds = 6_000_000_000
        mockLLM.postProcessResult = .success("This should not be used.")

        let sut = makeSUT(
            asrFinishResult: .success(
                ASRFinishResponse(text: "Um I feel like this is, like, great uh.", language: "en")
            ),
            localLLMRuntimeManager: mockLLM,
            postProcessingMode: .llm,
            llmPostProcessingPrompt: "Make this concise and professional.",
            frontmostApplicationProvider: { NSRunningApplication.current }
        )

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let inserted = await waitUntil(timeoutNanoseconds: 8_000_000_000) {
            sut.mockText.insertedTexts.count == 1
        }
        #expect(inserted)
        #expect(sut.mockText.insertedTexts.first == "I feel like this is great.")
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
