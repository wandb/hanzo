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
        let mockLocalRuntime: MockLocalASRRuntimeManager
        let mockLLM: MockLocalLLMRuntimeManager
    }

    func makeSUT(
        micPermission: Bool = true,
        accessibilityPermission: Bool = true,
        onboardingComplete: Bool = true,
        autoSubmitMode: AutoSubmitMode = .off,
        asrStartResult: Result<String, Error> = .success("test-session"),
        asrChunkResult: Result<ASRChunkResponse, Error> = .success(
            ASRChunkResponse(text: "partial", language: "en")
        ),
        asrFinishResult: Result<ASRFinishResponse, Error> = .success(
            ASRFinishResponse(text: "final transcript", language: "en")
        ),
        audioThrowOnStart: Error? = nil,
        localRuntimeManager: MockLocalASRRuntimeManager = MockLocalASRRuntimeManager(),
        localLLMRuntimeManager: MockLocalLLMRuntimeManager = MockLocalLLMRuntimeManager(),
        postProcessingMode: TranscriptPostProcessingMode = .off,
        llmPostProcessingPrompt: String = "",
        frontmostApplicationProvider: @escaping () -> NSRunningApplication? = { nil }
    ) -> SUT {
        // Set global post-processing settings so the orchestrator picks them up.
        AppBehaviorSettings.setGlobalAutoSubmitMode(autoSubmitMode)
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
            localRuntimeManager: localRuntimeManager,
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
            mockLocalRuntime: localRuntimeManager,
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

    @MainActor
    func sendLargeChunk(
        _ sut: SUT,
        settleNanoseconds: UInt64 = 100_000_000
    ) async throws {
        let largeChunk = Data(repeating: 0x01, count: Constants.chunkAccumulationBytes + 1)
        sut.mockAudio.simulateChunk(largeChunk)
        try await Task.sleep(nanoseconds: settleNanoseconds)
    }

    // MARK: - Initial State

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        let sut = makeSUT()
        #expect(sut.appState.dictationState == .idle)
    }

    @Test("Init prewarms LLM while onboarding is incomplete when permissions are granted")
    @MainActor func initPrewarmsLLMWhenOnboardingIncomplete() async throws {
        let defaults = UserDefaults.standard
        let priorProvider = defaults.string(forKey: Constants.asrProviderKey)
        defer {
            if let priorProvider {
                defaults.set(priorProvider, forKey: Constants.asrProviderKey)
            } else {
                defaults.removeObject(forKey: Constants.asrProviderKey)
            }
        }
        defaults.set(ASRProvider.server.rawValue, forKey: Constants.asrProviderKey)

        let mockLLM = MockLocalLLMRuntimeManager()
        _ = makeSUT(
            onboardingComplete: false,
            localLLMRuntimeManager: mockLLM,
            postProcessingMode: .llm
        )

        let didPrewarm = await waitUntil {
            mockLLM.prepareModelCallCount == 1
        }
        #expect(didPrewarm)
        #expect(mockLLM.prepareModelCallCount == 1)
    }

    // MARK: - Shutdown

    @Test("shutdown() stops local runtimes asynchronously")
    @MainActor func shutdownStopsLocalRuntimes() async {
        let sut = makeSUT()
        sut.orchestrator.shutdown()

        let localStopped = await waitUntil {
            sut.mockLocalRuntime.stopCallCount == 1
        }
        let llmStopped = await waitUntil {
            sut.mockLLM.stopCallCount == 1
        }

        #expect(localStopped)
        #expect(llmStopped)
    }

    @Test("shutdownAndWait() stops local runtimes synchronously")
    @MainActor func shutdownAndWaitStopsLocalRuntimes() {
        let sut = makeSUT()
        sut.orchestrator.shutdownAndWait(timeoutSeconds: 0.5)

        #expect(sut.mockLocalRuntime.stopCallCount == 1)
        #expect(sut.mockLLM.stopCallCount == 1)
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

    @Test("cancel() during forging does not transition to error")
    @MainActor func cancelDuringForgingStaysIdle() async throws {
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
            frontmostApplicationProvider: { NSRunningApplication.current }
        )

        orchestrator.toggle()
        try await Task.sleep(nanoseconds: 60_000_000)
        orchestrator.toggle() // listening -> forging
        #expect(appState.dictationState == .forging)

        orchestrator.cancel()

        let settledIdle = await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            appState.dictationState == .idle
        }
        #expect(settledIdle)

        // Wait past SlowFinishingASRClient delay to ensure late finish results are ignored.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(appState.dictationState == .idle)
        #expect(appState.errorMessage == nil)
        #expect(mockText.insertedTexts.isEmpty)
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

        try await sendLargeChunk(sut)

        #expect(sut.appState.partialTranscript == "hello world")
    }

    // MARK: - Leading Non-Speech Markers

    @Test("Leading non-speech marker detection matches only whole-response markers")
    func leadingNonSpeechMarkerDetectionMatchesWholeResponseOnly() {
        for marker in ["[ Silence ]", "[BLANK_AUDIO]", "[blank audio]", "[blank-audio]"] {
            #expect(DictationOrchestrator.isLeadingNonSpeechMarker(marker))
        }

        for nonMarker in ["silence", "blank audio", "hello", "hello [BLANK_AUDIO]", "[TODO]"] {
            #expect(!DictationOrchestrator.isLeadingNonSpeechMarker(nonMarker))
        }
    }

    @Test("Leading marker-only partials do not update the visible transcript")
    @MainActor func leadingMarkerOnlyPartialDoesNotUpdateVisibleTranscript() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "[BLANK_AUDIO]", language: "en"))
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)

        #expect(sut.appState.partialTranscript == "")
        #expect(sut.appState.dictationState == .listening)
    }

    @Test("Mixed partials strip known markers before updating the HUD transcript")
    @MainActor func mixedPartialsStripKnownMarkersBeforeHUDUpdate() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "hello [BLANK_AUDIO] world", language: "en"))
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)

        #expect(sut.appState.partialTranscript == "hello world")
    }

    @Test("Parenthetical-only partials do not update the visible transcript")
    @MainActor func parentheticalOnlyPartialsDoNotUpdateVisibleTranscript() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "(sigh)", language: "en"))
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)

        #expect(sut.appState.partialTranscript == "")
        #expect(sut.appState.dictationState == .listening)
    }

    @Test("Annotation-only partial sequences do not update the visible transcript")
    @MainActor func annotationOnlyPartialSequencesDoNotUpdateVisibleTranscript() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "(sighs) (clapping)", language: "en"))
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)

        #expect(sut.appState.partialTranscript == "")
        #expect(sut.appState.dictationState == .listening)
    }

    @Test("Asterisk annotation-only partials do not update the visible transcript")
    @MainActor func asteriskAnnotationOnlyPartialsDoNotUpdateVisibleTranscript() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "*cough*.", language: "en"))
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)

        #expect(sut.appState.partialTranscript == "")
        #expect(sut.appState.dictationState == .listening)
    }

    @Test("Bracket-only partials do not update the visible transcript")
    @MainActor func bracketOnlyPartialsDoNotUpdateVisibleTranscript() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "[MUSIC PLAYING]", language: "en"))
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)

        #expect(sut.appState.partialTranscript == "")
        #expect(sut.appState.dictationState == .listening)
    }

    @Test("Partials strip trailing parenthetical annotations while preserving spoken text")
    @MainActor func partialsStripTrailingParentheticalAnnotations() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(
                ASRChunkResponse(
                    text: "All of which are American dreams (crowd cheering)",
                    language: "en"
                )
            )
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)

        #expect(sut.appState.partialTranscript == "All of which are American dreams")
    }

    @Test("Leading marker-only sessions do not arm auto-close")
    @MainActor func leadingMarkerOnlySessionsDoNotArmAutoClose() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "[BLANK_AUDIO]", language: "en"))
        )
        sut.orchestrator.silenceTimeout = 0.2
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "")

        let silentLevels: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001]
        for _ in 0..<10 {
            sut.mockAudio.simulateLevels(silentLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(sut.appState.dictationState == .listening)
        #expect(sut.mockAudio.stopCaptureCalled == false)
        #expect(!sut.mockLogger.infoMessages.contains(where: { $0.contains("Silence timer started") }))
        #expect(!sut.mockLogger.infoMessages.contains(where: { $0.contains("Silence auto-close after") }))
    }

    @Test("First real speech after leading markers appears normally")
    @MainActor func firstRealSpeechAfterLeadingMarkersAppearsNormally() async throws {
        let sut = makeSUT()
        var chunkResponses = [
            ASRChunkResponse(text: "[BLANK_AUDIO]", language: "en"),
            ASRChunkResponse(text: "[ Silence ]", language: "en"),
            ASRChunkResponse(text: "hello world", language: "en"),
        ]
        sut.mockASR.sendChunkHandler = { _, _ in
            chunkResponses.removeFirst()
        }

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "")

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "")

        try await sendLargeChunk(sut)

        let showedSpeech = await waitUntil {
            sut.appState.partialTranscript == "hello world"
        }
        #expect(showedSpeech)
        #expect(sut.appState.partialTranscript == "hello world")
    }

    @Test("Marker-only packets after real speech do not regress visible transcript")
    @MainActor func markerOnlyPacketsAfterRealSpeechDoNotRegressVisibleTranscript() async throws {
        let sut = makeSUT()
        var chunkResponses = [
            ASRChunkResponse(text: "hello world", language: "en"),
            ASRChunkResponse(text: "[BLANK_AUDIO]", language: "en"),
        ]
        sut.mockASR.sendChunkHandler = { _, _ in
            chunkResponses.removeFirst()
        }

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")
    }

    @Test("Parenthetical-only packets after real speech do not regress visible transcript")
    @MainActor func parentheticalOnlyPacketsAfterRealSpeechDoNotRegressVisibleTranscript() async throws {
        let sut = makeSUT()
        var chunkResponses = [
            ASRChunkResponse(text: "hello world", language: "en"),
            ASRChunkResponse(text: "(sighs) (clapping)", language: "en"),
        ]
        sut.mockASR.sendChunkHandler = { _, _ in
            chunkResponses.removeFirst()
        }

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")
    }

    @Test("Asterisk annotation-only packets after real speech do not regress visible transcript")
    @MainActor func asteriskAnnotationOnlyPacketsAfterRealSpeechDoNotRegressVisibleTranscript() async throws {
        let sut = makeSUT()
        var chunkResponses = [
            ASRChunkResponse(text: "hello world", language: "en"),
            ASRChunkResponse(text: "*cough*.", language: "en"),
        ]
        sut.mockASR.sendChunkHandler = { _, _ in
            chunkResponses.removeFirst()
        }

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")
    }

    @Test("Bracket-only packets after real speech do not regress visible transcript")
    @MainActor func bracketOnlyPacketsAfterRealSpeechDoNotRegressVisibleTranscript() async throws {
        let sut = makeSUT()
        var chunkResponses = [
            ASRChunkResponse(text: "hello world", language: "en"),
            ASRChunkResponse(text: "[MUSIC PLAYING]", language: "en"),
        ]
        sut.mockASR.sendChunkHandler = { _, _ in
            chunkResponses.removeFirst()
        }

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")
    }

    @Test("Manual stop on a leading marker-only final inserts nothing")
    @MainActor func manualStopOnLeadingMarkerOnlyFinalInsertsNothing() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "[BLANK_AUDIO]", language: "en")),
            asrFinishResult: .success(ASRFinishResponse(text: "[BLANK_AUDIO]", language: "en")),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "")

        sut.orchestrator.toggle()

        let returnedToIdle = await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            sut.appState.dictationState == .idle
        }
        #expect(returnedToIdle)
        #expect(sut.mockText.insertedTexts.isEmpty)
        #expect(sut.mockText.returnSimulated == false)
        #expect(sut.mockText.cmdReturnSimulated == false)
        #expect(
            sut.mockLogger.infoMessages.contains {
                $0.contains("Final transcription empty after artifact filtering; skipping insertion")
            }
        )
    }

    @Test("Manual stop on marker-only final inserts nothing even after speech appears in the HUD")
    @MainActor func manualStopOnMarkerOnlyFinalInsertsNothingAfterSpeech() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "hello world", language: "en")),
            asrFinishResult: .success(ASRFinishResponse(text: "[BLANK_AUDIO]", language: "en")),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")

        sut.orchestrator.toggle()

        let returnedToIdle = await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            sut.appState.dictationState == .idle
        }
        #expect(returnedToIdle)
        #expect(sut.mockText.insertedTexts.isEmpty)
    }

    @Test("Manual stop inserts mixed final transcript after stripping known markers")
    @MainActor func manualStopInsertsMixedFinalTranscriptAfterStrippingKnownMarkers() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "hello [BLANK_AUDIO] world", language: "en")),
            asrFinishResult: .success(ASRFinishResponse(text: "hello [BLANK_AUDIO] world", language: "en")),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        sut.orchestrator.toggle()

        let insertedCleanText = await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            sut.mockText.insertedTexts == ["hello world"]
        }
        #expect(insertedCleanText)
        #expect(sut.mockText.insertedTexts == ["hello world"])
    }

    @Test("Manual stop on annotation-only final inserts nothing")
    @MainActor func manualStopOnAnnotationOnlyFinalInsertsNothing() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "hello world", language: "en")),
            asrFinishResult: .success(ASRFinishResponse(text: "(sighs) (clapping)", language: "en")),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")

        sut.orchestrator.toggle()

        let returnedToIdle = await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            sut.appState.dictationState == .idle
        }
        #expect(returnedToIdle)
        #expect(sut.mockText.insertedTexts.isEmpty)
    }

    @Test("Manual stop on asterisk annotation-only final inserts nothing")
    @MainActor func manualStopOnAsteriskAnnotationOnlyFinalInsertsNothing() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "hello world", language: "en")),
            asrFinishResult: .success(ASRFinishResponse(text: "*cough*.", language: "en")),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")

        sut.orchestrator.toggle()

        let returnedToIdle = await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            sut.appState.dictationState == .idle
        }
        #expect(returnedToIdle)
        #expect(sut.mockText.insertedTexts.isEmpty)
    }

    @Test("Manual stop on bracket-only final inserts nothing")
    @MainActor func manualStopOnBracketOnlyFinalInsertsNothing() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(ASRChunkResponse(text: "hello world", language: "en")),
            asrFinishResult: .success(ASRFinishResponse(text: "[MUSIC PLAYING]", language: "en")),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        #expect(sut.appState.partialTranscript == "hello world")

        sut.orchestrator.toggle()

        let returnedToIdle = await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            sut.appState.dictationState == .idle
        }
        #expect(returnedToIdle)
        #expect(sut.mockText.insertedTexts.isEmpty)
    }

    @Test("Manual stop strips trailing parenthetical annotations from final transcript before insertion")
    @MainActor func manualStopStripsTrailingParentheticalAnnotationsFromFinal() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(
                ASRChunkResponse(
                    text: "All of which are American dreams (crowd cheering)",
                    language: "en"
                )
            ),
            asrFinishResult: .success(
                ASRFinishResponse(
                    text: "All of which are American dreams (crowd cheering)",
                    language: "en"
                )
            ),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await sendLargeChunk(sut)
        sut.orchestrator.toggle()

        let insertedCleanText = await waitUntil(timeoutNanoseconds: 3_000_000_000) {
            sut.mockText.insertedTexts == ["All of which are American dreams"]
        }
        #expect(insertedCleanText)
        #expect(sut.mockText.insertedTexts == ["All of which are American dreams"])
    }

    @Test("Stopping merges trailing buffered chunk response into partialTranscript")
    @MainActor func stopMergesTrailingBufferedChunkIntoTranscript() async throws {
        let sut = makeSUT(
            asrChunkResult: .success(
                ASRChunkResponse(text: "base transcript with trailing words", language: "en")
            )
        )
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.appState.partialTranscript = "base transcript"

        // Keep this below the send threshold so stop() flushes it as the trailing buffer.
        let smallChunk = Data(repeating: 0x01, count: 256)
        sut.mockAudio.simulateChunk(smallChunk)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(sut.mockASR.sendChunkCalls.isEmpty)

        sut.orchestrator.toggle()

        let didMergeTrailingText = await waitUntil {
            sut.appState.partialTranscript == "base transcript with trailing words"
        }
        #expect(didMergeTrailingText)
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

    @Test("Final transcript is unchanged when post-processing mode is off")
    @MainActor func finalTranscriptUnchangedWhenPostProcessingIsOff() async throws {
        let defaults = UserDefaults.standard
        let originalCommonTerms = defaults.string(forKey: Constants.commonTermsKey)
        AppBehaviorSettings.setGlobalCommonTerms("LLM\nPyTorch")
        defer {
            if let originalCommonTerms {
                defaults.set(originalCommonTerms, forKey: Constants.commonTermsKey)
            } else {
                defaults.removeObject(forKey: Constants.commonTermsKey)
            }
        }

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
        #expect(sut.mockLLM.postProcessCallCount == 0)
    }

    @Test("Final transcript uses LLM post-processing output when mode is LLM")
    @MainActor func finalTranscriptUsesLLMOutputWhenModeEnabled() async throws {
        let mockLLM = MockLocalLLMRuntimeManager()
        mockLLM.postProcessResult = .success("This is concise and professional.")
        let rawTranscript = "Um this is, like, the update uh"
        let expectedTargetApp: String? = {
            let localized = NSRunningApplication.current.localizedName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let localized, !localized.isEmpty {
                return localized
            }

            let bundleIdentifier = NSRunningApplication.current.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                return bundleIdentifier
            }
            return nil
        }()

        let sut = makeSUT(
            asrFinishResult: .success(
                ASRFinishResponse(text: rawTranscript, language: "en")
            ),
            localLLMRuntimeManager: mockLLM,
            postProcessingMode: .llm,
            llmPostProcessingPrompt: "Make this concise and professional.",
            frontmostApplicationProvider: { NSRunningApplication.current }
        )

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let inserted = await waitUntil(timeoutNanoseconds: 4_000_000_000) {
            sut.mockText.insertedTexts.count == 1
        }
        #expect(inserted)
        #expect(sut.mockText.insertedTexts.first == "This is concise and professional.")
        #expect(mockLLM.postProcessCallCount == 1)
        #expect(mockLLM.lastInputText == rawTranscript)
        #expect(mockLLM.lastPrompt == "Make this concise and professional.")
        #expect(mockLLM.lastTargetApp == expectedTargetApp)
        #expect(mockLLM.lastCommonTerms == [])
    }

    @Test("LLM mode passes global common terms to local rewrite")
    @MainActor func llmModePassesGlobalCommonTerms() async throws {
        let defaults = UserDefaults.standard
        let originalCommonTerms = defaults.string(forKey: Constants.commonTermsKey)
        AppBehaviorSettings.setGlobalCommonTerms("LLM\nPyTorch\nLLM")
        defer {
            if let originalCommonTerms {
                defaults.set(originalCommonTerms, forKey: Constants.commonTermsKey)
            } else {
                defaults.removeObject(forKey: Constants.commonTermsKey)
            }
        }

        let mockLLM = MockLocalLLMRuntimeManager()
        mockLLM.postProcessResult = .success("Normalized output")
        let sut = makeSUT(
            asrFinishResult: .success(
                ASRFinishResponse(text: "raw transcript", language: "en")
            ),
            localLLMRuntimeManager: mockLLM,
            postProcessingMode: .llm,
            llmPostProcessingPrompt: "Keep terms accurate.",
            frontmostApplicationProvider: { NSRunningApplication.current }
        )

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let inserted = await waitUntil(timeoutNanoseconds: 4_000_000_000) {
            sut.mockText.insertedTexts.count == 1
        }
        #expect(inserted)
        #expect(mockLLM.lastCommonTerms == ["LLM", "PyTorch"])
    }

    @Test("LLM mode falls back to raw transcript when local LLM processing fails")
    @MainActor func llmModeFallsBackWhenLocalLLMProcessingFails() async throws {
        let mockLLM = MockLocalLLMRuntimeManager()
        mockLLM.postProcessResult = .failure(LocalLLMRuntimeError.serverNotReady)
        let rawTranscript = "Um I feel like this is, like, great uh."

        let sut = makeSUT(
            asrFinishResult: .success(
                ASRFinishResponse(text: rawTranscript, language: "en")
            ),
            localLLMRuntimeManager: mockLLM,
            postProcessingMode: .llm,
            llmPostProcessingPrompt: "Make this concise and professional.",
            frontmostApplicationProvider: { NSRunningApplication.current }
        )

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let inserted = await waitUntil(timeoutNanoseconds: 4_000_000_000) {
            sut.mockText.insertedTexts.count == 1
        }
        #expect(inserted)
        #expect(sut.mockText.insertedTexts.first == rawTranscript)
        #expect(mockLLM.postProcessCallCount == 1)
    }

    @Test("LLM mode falls back to raw transcript when local LLM processing times out")
    @MainActor func llmModeFallsBackWhenLocalLLMProcessingTimesOut() async throws {
        let mockLLM = MockLocalLLMRuntimeManager()
        mockLLM.postProcessDelayNanoseconds = 6_000_000_000
        mockLLM.postProcessResult = .success("This should not be used.")
        let rawTranscript = "Um I feel like this is, like, great uh."

        let sut = makeSUT(
            asrFinishResult: .success(
                ASRFinishResponse(text: rawTranscript, language: "en")
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
        #expect(sut.mockText.insertedTexts.first == rawTranscript)
    }

    // MARK: - Auto-Submit

    @Test("Enter auto-submit runs only after text insertion completes")
    @MainActor func enterAutoSubmitWaitsForInsertionCompletion() async throws {
        let sut = makeSUT(
            autoSubmitMode: .enter,
            asrFinishResult: .success(
                ASRFinishResponse(text: "final transcript", language: "en")
            ),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.mockText.insertionDelayNanoseconds = 700_000_000

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let submitted = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            sut.mockText.returnSimulated
        }
        #expect(submitted)
        #expect(
            sut.mockText.eventLog == ["insert:start", "insert:end", "submit:return"]
        )
    }

    @Test("Cmd+Enter auto-submit runs only after text insertion completes")
    @MainActor func cmdEnterAutoSubmitWaitsForInsertionCompletion() async throws {
        let sut = makeSUT(
            autoSubmitMode: .cmdEnter,
            asrFinishResult: .success(
                ASRFinishResponse(text: "final transcript", language: "en")
            ),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.mockText.insertionDelayNanoseconds = 700_000_000

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        let submitted = await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            sut.mockText.cmdReturnSimulated
        }
        #expect(submitted)
        #expect(
            sut.mockText.eventLog == ["insert:start", "insert:end", "submit:cmd-return"]
        )
    }

    @Test("State stays forging until insertion and submit complete")
    @MainActor func stateStaysForgingUntilInsertionAndSubmitComplete() async throws {
        let sut = makeSUT(
            autoSubmitMode: .enter,
            asrFinishResult: .success(
                ASRFinishResponse(text: "final transcript", language: "en")
            ),
            frontmostApplicationProvider: { NSRunningApplication.current }
        )
        sut.mockText.insertionDelayNanoseconds = 1_000_000_000

        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.orchestrator.toggle()

        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(sut.appState.dictationState == .forging)

        let isIdle = await waitUntil(timeoutNanoseconds: 6_000_000_000) {
            sut.appState.dictationState == .idle
        }
        #expect(isIdle)
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

    @Test("Silence auto-close waits for sustained quiet before arming the countdown")
    @MainActor func silenceAutoCloseWaitsForSustainedQuietBeforeArming() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.5
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.mockAudio.simulateLevels([0.1, 0.15, 0.12, 0.08, 0.1, 0.09, 0.11])
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.appState.partialTranscript = "hello world"

        let silentLevels: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001]

        for _ in 0..<4 {
            sut.mockAudio.simulateLevels(silentLevels)
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(sut.appState.dictationState == .listening)
        #expect(!sut.mockLogger.infoMessages.contains(where: { $0.contains("Silence timer started") }))

        let didStop = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            sut.mockAudio.simulateLevels(silentLevels)
            return sut.appState.dictationState != .listening
        }

        #expect(didStop)
        #expect(sut.mockLogger.infoMessages.contains(where: { $0.contains("Silence timer started") }))
        #expect(sut.mockAudio.stopCaptureCalled == true)
    }

    @Test("Silence auto-close triggers despite steady ambient noise")
    @MainActor func silenceAutoCloseTriggersWithAmbientNoise() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.2
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Capture a modest speech peak so the raw threshold can fall to the floor.
        sut.mockAudio.simulateLevels([0.028, 0.031, 0.03, 0.027, 0.029, 0.03, 0.028])
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.appState.partialTranscript = "hello"

        // Ambient room noise stays above absolute floor and previously held the timer open.
        let ambientLevels: [Float] = [0.007, 0.0072, 0.0068, 0.0071, 0.007, 0.0072, 0.0069]
        for _ in 0..<24 {
            sut.mockAudio.simulateLevels(ambientLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
            if sut.appState.dictationState != .listening {
                break
            }
        }

        #expect(sut.appState.dictationState != .listening)
        #expect(sut.mockAudio.stopCaptureCalled == true)
    }

    @Test("Silence auto-close still triggers when quiet baseline is high relative to speech peak")
    @MainActor func silenceAutoCloseTriggersWithHighRelativeBaseline() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.2
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Built-in mics can have elevated steady background where "quiet"
        // sits close to a short speech peak.
        sut.mockAudio.simulateLevels([0.042, 0.045, 0.043, 0.041, 0.044, 0.043, 0.042])
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.appState.partialTranscript = "hello"

        let elevatedQuietLevels: [Float] = [0.030, 0.031, 0.029, 0.030, 0.031, 0.030, 0.029]
        for _ in 0..<26 {
            sut.mockAudio.simulateLevels(elevatedQuietLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
            if sut.appState.dictationState != .listening {
                break
            }
        }

        #expect(sut.appState.dictationState != .listening)
        #expect(sut.mockAudio.stopCaptureCalled == true)
    }

    @Test("Silence auto-close ignores low-frequency rumble that lacks speech-band energy")
    @MainActor func silenceAutoCloseIgnoresLowFrequencyRumble() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.2
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Speech has broad mid-band energy, unlike fan or airflow rumble.
        sut.mockAudio.simulateLevels([0.01, 0.025, 0.05, 0.08, 0.09, 0.06, 0.02])
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.appState.partialTranscript = "hello"

        let rumbleLevels: [Float] = [0.055, 0.045, 0.018, 0.006, 0.004, 0.003, 0.002]
        for _ in 0..<26 {
            sut.mockAudio.simulateLevels(rumbleLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
            if sut.appState.dictationState != .listening {
                break
            }
        }

        #expect(sut.appState.dictationState != .listening)
        #expect(sut.mockAudio.stopCaptureCalled == true)
    }

    @Test("Silence auto-close is not excessively delayed by ambient jitter")
    @MainActor func silenceAutoCloseIsNotDelayedByAmbientJitter() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.2
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.mockAudio.simulateLevels([0.03, 0.031, 0.029, 0.03, 0.03, 0.031, 0.029])
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.appState.partialTranscript = "hello"

        let jitterA: [Float] = [0.0072, 0.007, 0.0068, 0.0073, 0.0071, 0.007, 0.0069]
        let jitterB: [Float] = [0.0108, 0.0112, 0.0106, 0.011, 0.0109, 0.0111, 0.0107]
        var stopIteration: Int?

        for i in 0..<24 {
            let levels = (i % 2 == 0) ? jitterA : jitterB
            sut.mockAudio.simulateLevels(levels)
            try await Task.sleep(nanoseconds: 50_000_000)
            if sut.appState.dictationState != .listening {
                stopIteration = i
                break
            }
        }

        #expect(sut.appState.dictationState != .listening)
        #expect(stopIteration != nil)
        #expect((stopIteration ?? Int.max) <= 21)
    }

    @Test("Silence auto-close ignores borderline ambient bumps")
    @MainActor func silenceAutoCloseIgnoresBorderlineAmbientBumps() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.2
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        sut.mockAudio.simulateLevels([0.03, 0.031, 0.029, 0.03, 0.03, 0.031, 0.029])
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.appState.partialTranscript = "hello"

        let ambientBaseline: [Float] = [0.007, 0.0071, 0.0069, 0.007, 0.0071, 0.0069, 0.007]
        let ambientBumps: [Float] = [0.0104, 0.0105, 0.0103, 0.0104, 0.0105, 0.0104, 0.0103]
        var stopIteration: Int?

        for i in 0..<24 {
            let levels = (i % 2 == 0) ? ambientBaseline : ambientBumps
            sut.mockAudio.simulateLevels(levels)
            try await Task.sleep(nanoseconds: 50_000_000)
            if sut.appState.dictationState != .listening {
                stopIteration = i
                break
            }
        }

        #expect(sut.appState.dictationState != .listening)
        #expect(stopIteration != nil)
        #expect((stopIteration ?? Int.max) <= 21)
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

    @Test("Transcript growth during quiet does not indefinitely delay silence auto-close")
    @MainActor func silenceAutoCloseNotBlockedByTranscriptGrowthDuringQuiet() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.25
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Initial speech and words.
        sut.mockAudio.simulateLevels([0.1, 0.15, 0.12, 0.08, 0.1, 0.09, 0.11])
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.appState.partialTranscript = "hello"

        // Low-volume stretch starts silence tracking after transcript grace.
        let quietLevels: [Float] = [0.0065, 0.0067, 0.0066, 0.0065, 0.0066, 0.0067, 0.0065]
        for _ in 0..<4 {
            sut.mockAudio.simulateLevels(quietLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Late transcript growth while still quiet should not keep the
        // session alive for much longer than the configured timeout.
        sut.appState.partialTranscript = "hello world"
        var stopIteration: Int?
        for i in 0..<26 {
            if i == 2 {
                sut.appState.partialTranscript = "hello world again"
            }
            sut.mockAudio.simulateLevels(quietLevels)
            try await Task.sleep(nanoseconds: 50_000_000)
            if sut.appState.dictationState != .listening {
                stopIteration = i
                break
            }
        }

        #expect(sut.appState.dictationState != .listening)
        #expect(stopIteration != nil)
        #expect((stopIteration ?? Int.max) <= 22)
    }

    @Test("Silence auto-close does not trigger while low-energy moving speech continues")
    @MainActor func silenceAutoCloseIgnoresLowEnergyMovingSpeech() async throws {
        let sut = makeSUT()
        sut.mockASR.sendChunkHandler = { _, _ in
            ASRChunkResponse(text: "hello", language: "en")
        }

        sut.orchestrator.silenceTimeout = 0.3
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let chunk = Data(repeating: 0, count: Constants.chunkAccumulationBytes)
        let speechPeak: [Float] = [0.08, 0.12, 0.19, 0.28, 0.26, 0.18, 0.09]
        let movingA: [Float] = [0.025, 0.034, 0.032, 0.034, 0.032, 0.032, 0.032]
        let movingB: [Float] = [0.030, 0.027, 0.023, 0.027, 0.029, 0.028, 0.030]
        let movingC: [Float] = [0.035, 0.034, 0.026, 0.033, 0.036, 0.033, 0.026]
        let movingSequence = [movingA, movingB, movingC, movingB]

        sut.mockAudio.simulateLevels(speechPeak)
        sut.mockAudio.simulateChunk(chunk)

        let gotInitialPartial = await waitUntil(timeoutNanoseconds: 500_000_000) {
            sut.appState.partialTranscript == "hello"
        }
        #expect(gotInitialPartial)

        for i in 0..<12 {
            sut.mockAudio.simulateLevels(movingSequence[i % movingSequence.count])
            sut.mockAudio.simulateChunk(chunk)
            try await Task.sleep(nanoseconds: 100_000_000)

            if sut.appState.dictationState != .listening {
                break
            }
        }

        #expect(sut.appState.dictationState == .listening)
        #expect(sut.mockAudio.stopCaptureCalled == false)
    }

    @Test("Low-dominance moving speech keeps the session alive after transcript content goes stale")
    @MainActor func silenceAutoCloseIgnoresLowDominanceMovingSpeechAfterTranscriptGrowthStales() async throws {
        let sut = makeSUT()
        sut.mockASR.sendChunkHandler = { _, _ in
            ASRChunkResponse(text: "hello", language: "en")
        }

        sut.orchestrator.silenceTimeout = 0.3
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let chunk = Data(repeating: 0, count: Constants.chunkAccumulationBytes)
        let speechPeak: [Float] = [0.08, 0.12, 0.19, 0.28, 0.26, 0.18, 0.09]
        let movingA: [Float] = [0.025, 0.034, 0.032, 0.034, 0.032, 0.032, 0.032]
        let movingB: [Float] = [0.030, 0.027, 0.023, 0.027, 0.029, 0.028, 0.030]
        let movingC: [Float] = [0.035, 0.034, 0.026, 0.033, 0.036, 0.033, 0.026]
        let movingSequence = [movingA, movingB, movingC]

        sut.mockAudio.simulateLevels(speechPeak)
        sut.mockAudio.simulateChunk(chunk)

        let gotInitialPartial = await waitUntil(timeoutNanoseconds: 500_000_000) {
            sut.appState.partialTranscript == "hello"
        }
        #expect(gotInitialPartial)

        for i in 0..<24 {
            sut.mockAudio.simulateLevels(movingSequence[i % movingSequence.count])
            sut.mockAudio.simulateChunk(chunk)
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(sut.appState.dictationState == .listening)
        #expect(sut.mockAudio.stopCaptureCalled == false)
        #expect(
            !sut.mockLogger.infoMessages.contains {
                $0.contains("Silence auto-close after")
            }
        )
    }

    @Test("Continuation audio clears a running silence timer when motion resumes")
    @MainActor func silenceAutoCloseClearsRunningTimerForMovingContinuationAudio() async throws {
        let sut = makeSUT()
        sut.mockASR.sendChunkHandler = { _, _ in
            ASRChunkResponse(text: "hello", language: "en")
        }

        sut.orchestrator.silenceTimeout = 0.35
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let chunk = Data(repeating: 0, count: Constants.chunkAccumulationBytes)
        let speechPeak: [Float] = [0.08, 0.12, 0.19, 0.28, 0.26, 0.18, 0.09]
        let lowNoiseLevels: [Float] = [0.0051, 0.0052, 0.0050, 0.0051, 0.0052, 0.0051, 0.0050]
        let movingA: [Float] = [0.025, 0.027, 0.027, 0.022, 0.026, 0.021, 0.024]
        let movingB: [Float] = [0.018, 0.024, 0.023, 0.025, 0.017, 0.023, 0.024]
        let movingC: [Float] = [0.028, 0.023, 0.027, 0.022, 0.025, 0.029, 0.028]
        let movingSequence = [movingA, movingB, movingC]

        sut.mockAudio.simulateLevels(speechPeak)
        sut.mockAudio.simulateChunk(chunk)

        let gotInitialPartial = await waitUntil(timeoutNanoseconds: 500_000_000) {
            sut.appState.partialTranscript == "hello"
        }
        #expect(gotInitialPartial)

        var sawTimerStart = false
        for _ in 0..<8 {
            sut.mockAudio.simulateLevels(lowNoiseLevels)
            sut.mockAudio.simulateChunk(chunk)
            try await Task.sleep(nanoseconds: 100_000_000)

            sawTimerStart = sut.mockLogger.infoMessages.contains {
                $0.contains("Silence timer started")
            }
            if sawTimerStart || sut.appState.dictationState != .listening {
                break
            }
        }

        #expect(sawTimerStart)
        #expect(sut.appState.dictationState == .listening)

        for levels in movingSequence {
            sut.mockAudio.simulateLevels(levels)
            sut.mockAudio.simulateChunk(chunk)
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(sut.appState.dictationState == .listening)
        #expect(
            sut.mockLogger.infoMessages.contains {
                $0.contains("Silence timer cleared by continuation audio")
            }
        )
    }

    @Test("Silence auto-close still triggers during low-level noise despite repeated identical partials")
    @MainActor func silenceAutoCloseStillTriggersWithRepeatedIdenticalPartialsInLowNoise() async throws {
        let sut = makeSUT()
        sut.mockASR.sendChunkHandler = { _, _ in
            ASRChunkResponse(text: "hello", language: "en")
        }
        sut.orchestrator.silenceTimeout = 0.25
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let chunk = Data(repeating: 0, count: Constants.chunkAccumulationBytes)
        sut.mockAudio.simulateLevels([0.08, 0.12, 0.19, 0.28, 0.26, 0.18, 0.09])
        sut.mockAudio.simulateChunk(chunk)

        let gotInitialPartial = await waitUntil(timeoutNanoseconds: 500_000_000) {
            sut.appState.partialTranscript == "hello"
        }
        #expect(gotInitialPartial)

        let lowNoiseLevels: [Float] = [0.0051, 0.0052, 0.0050, 0.0051, 0.0052, 0.0051, 0.0050]
        for _ in 0..<10 {
            sut.mockAudio.simulateLevels(lowNoiseLevels)
            sut.mockAudio.simulateChunk(chunk)
            try await Task.sleep(nanoseconds: 100_000_000)

            if sut.appState.dictationState != .listening {
                break
            }
        }

        #expect(sut.appState.dictationState != .listening)
        #expect(sut.mockAudio.stopCaptureCalled == true)
        #expect(
            sut.mockLogger.infoMessages.contains {
                $0.contains("Silence auto-close after")
                    && $0.contains("audioMotion")
                    && $0.contains("motionThreshold")
                    && $0.contains("silenceState candidateSilence")
            }
        )
    }

    @Test("Silence auto-close still triggers during steady fan-like noise")
    @MainActor func silenceAutoCloseStillTriggersWithSteadyFanLikeNoise() async throws {
        let sut = makeSUT()
        sut.mockASR.sendChunkHandler = { _, _ in
            ASRChunkResponse(text: "hello", language: "en")
        }
        sut.orchestrator.silenceTimeout = 0.25
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let chunk = Data(repeating: 0, count: Constants.chunkAccumulationBytes)
        let speechPeak: [Float] = [0.08, 0.12, 0.19, 0.28, 0.26, 0.18, 0.09]
        let fanLikeLevels: [Float] = [0.040, 0.038, 0.034, 0.028, 0.024, 0.020, 0.018]

        sut.mockAudio.simulateLevels(speechPeak)
        sut.mockAudio.simulateChunk(chunk)

        let gotInitialPartial = await waitUntil(timeoutNanoseconds: 500_000_000) {
            sut.appState.partialTranscript == "hello"
        }
        #expect(gotInitialPartial)

        for _ in 0..<14 {
            sut.mockAudio.simulateLevels(fanLikeLevels)
            sut.mockAudio.simulateChunk(chunk)
            try await Task.sleep(nanoseconds: 100_000_000)

            if sut.appState.dictationState != .listening {
                break
            }
        }

        #expect(sut.appState.dictationState != .listening)
        #expect(sut.mockAudio.stopCaptureCalled == true)
        #expect(
            sut.mockLogger.infoMessages.contains {
                $0.contains("Silence auto-close after")
                    && $0.contains("audioMotion")
                    && $0.contains("motionThreshold")
                    && $0.contains("silenceState candidateSilence")
            }
        )
    }

    @Test("Moving low-energy broadband audio stays alive while steady low-energy broadband closes")
    @MainActor func silenceAutoCloseDistinguishesMovingFromSteadyLowEnergyBroadband() async throws {
        let movingSUT = makeSUT()
        movingSUT.mockASR.sendChunkHandler = { _, _ in
            ASRChunkResponse(text: "hello", language: "en")
        }
        movingSUT.orchestrator.silenceTimeout = 0.25
        movingSUT.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let chunk = Data(repeating: 0, count: Constants.chunkAccumulationBytes)
        let speechPeak: [Float] = [0.08, 0.12, 0.19, 0.28, 0.26, 0.18, 0.09]
        let movingA: [Float] = [0.025, 0.034, 0.032, 0.034, 0.032, 0.032, 0.032]
        let movingB: [Float] = [0.030, 0.027, 0.023, 0.027, 0.029, 0.028, 0.030]
        let movingC: [Float] = [0.035, 0.034, 0.026, 0.033, 0.036, 0.033, 0.026]
        let movingSequence = [movingA, movingB, movingC]

        movingSUT.mockAudio.simulateLevels(speechPeak)
        movingSUT.mockAudio.simulateChunk(chunk)
        let gotMovingPartial = await waitUntil(timeoutNanoseconds: 500_000_000) {
            movingSUT.appState.partialTranscript == "hello"
        }
        #expect(gotMovingPartial)

        for i in 0..<12 {
            movingSUT.mockAudio.simulateLevels(movingSequence[i % movingSequence.count])
            movingSUT.mockAudio.simulateChunk(chunk)
            try await Task.sleep(nanoseconds: 100_000_000)
            if movingSUT.appState.dictationState != .listening {
                break
            }
        }

        #expect(movingSUT.appState.dictationState == .listening)

        let steadySUT = makeSUT()
        steadySUT.mockASR.sendChunkHandler = { _, _ in
            ASRChunkResponse(text: "hello", language: "en")
        }
        steadySUT.orchestrator.silenceTimeout = 0.25
        steadySUT.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let steadyBroadbandLevels: [Float] = [0.030, 0.030, 0.030, 0.030, 0.030, 0.030, 0.030]

        steadySUT.mockAudio.simulateLevels(speechPeak)
        steadySUT.mockAudio.simulateChunk(chunk)
        let gotSteadyPartial = await waitUntil(timeoutNanoseconds: 500_000_000) {
            steadySUT.appState.partialTranscript == "hello"
        }
        #expect(gotSteadyPartial)

        for _ in 0..<14 {
            steadySUT.mockAudio.simulateLevels(steadyBroadbandLevels)
            steadySUT.mockAudio.simulateChunk(chunk)
            try await Task.sleep(nanoseconds: 100_000_000)
            if steadySUT.appState.dictationState != .listening {
                break
            }
        }

        #expect(steadySUT.appState.dictationState != .listening)
        #expect(steadySUT.mockAudio.stopCaptureCalled == true)
    }

    @Test("Silence auto-close stays within the configured motion linger bound")
    @MainActor func silenceAutoCloseStaysWithinMotionLingerBound() async throws {
        let sut = makeSUT()
        sut.orchestrator.silenceTimeout = 0.25
        sut.orchestrator.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)

        let speechPeak: [Float] = [0.08, 0.12, 0.19, 0.28, 0.26, 0.18, 0.09]
        let silentLevels: [Float] = [0.001, 0.001, 0.001, 0.001, 0.001, 0.001, 0.001]

        sut.mockAudio.simulateLevels(speechPeak)
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.appState.partialTranscript = "hello"

        let lingerBound = sut.orchestrator.silenceTimeout
            + min(
                max(
                    sut.orchestrator.silenceTimeout * Constants.silenceTimerArmDelayTimeoutFraction,
                    Constants.silenceTimerArmDelayMinimumSeconds
                ),
                Constants.silenceTimerArmDelayMaximumSeconds
            )
            + Constants.silenceMotionWindowSeconds
            + 0.15

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(lingerBound * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline
            && sut.appState.dictationState == .listening {
            sut.mockAudio.simulateLevels(silentLevels)
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(sut.appState.dictationState != .listening)
        #expect(sut.mockAudio.stopCaptureCalled == true)
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
