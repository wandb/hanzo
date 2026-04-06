import Foundation

enum AutoSubmitMode: String, CaseIterable, Codable {
    case enter
    case cmdEnter
    case off

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .enter:
            return "Enter"
        case .cmdEnter:
            return "Cmd+Enter"
        }
    }
}

enum AppearanceMode: String {
    case system
    case light
    case dark
}

enum Constants {
    static let releaseBundleIdentifier = "com.hanzo.app"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? releaseBundleIdentifier
    }

    static var isDevBuild: Bool {
        bundleIdentifier != releaseBundleIdentifier
    }

    static let defaultServerEndpoint = ""
    static let localModelsFolderName = "models"
    static let localWhisperModel = "small.en"
    static let localWhisperModelRepository = "argmaxinc/whisperkit-coreml"
    static let localWhisperPartialMinSeconds: Double = 1.0
    static let localWhisperPartialMinIntervalSeconds: Double = 0.8
    // Adaptive partial decode window bounds. Runtime adjusts within this range
    // to keep HUD updates responsive under sustained dictation.
    static let localWhisperPartialWindowSeconds: Double = 30.0
    static let localWhisperPartialMinWindowSeconds: Double = 6.0
    static let localWhisperPartialTargetDecodeSeconds: Double = 0.9
    static let partialTranscriptAggressiveRecoveryAfterSeconds: Double = 6.0
    static let localWhisperSessionTTLSeconds: Double = 180.0
    static let localLLMModelsSubfolderName = "llm"
    static let localLLMModelRepository = "Qwen/Qwen3-4B-GGUF"
    static let localLLMModelFileName = "Qwen3-4B-Q4_K_M.gguf"
    // Fallback download size when the remote host does not expose Content-Length metadata.
    static let localLLMModelExpectedDownloadBytes: Int64 = 2_497_280_256
    static let localLLMContextSizeKey = "localLLMContextSize"
    static let supportedLocalLLMContextSizes = [1024, 2048]
    static let defaultLocalLLMContextSize = 2048
    static let localLLMServerPort = 39281
    static let localLLMServerHost = "127.0.0.1"
    static let localLLMServerExecutableName = "llama-server"
    static let localLLMServerExecutableOverrideKey = "localLLMServerExecutablePath"
    static let localLLMServerGPULayers = 99
    static let localLLMRequestTimeoutSeconds: TimeInterval = 20
    static let localLLMPostProcessingTimeoutSeconds: Double = 4.0
    static let defaultCustomServerPassword = ""
    static let serverEndpointKey = "serverEndpoint"
    static let customServerPasswordKey = "customServerPassword"
    static let asrProviderKey = "asrProvider"
    static let defaultASRProvider: ASRProvider = .local
    static let onboardingCompleteKey = "onboardingComplete"
    static let hotkeyCodeKey = "hotkeyCode"
    static let hotkeyModifiersKey = "hotkeyModifiers"
    static let defaultHotkeyCode: UInt32 = 49    // Space (Carbon virtual key code)
    static let defaultHotkeyModifiers: UInt32 = 2048  // Option (Carbon flag)
    static let hotkeyHoldThresholdSeconds: TimeInterval = 0.3
    static let logFileName = "hanzo.log"
    static let maxLogFileSizeMB = 10
    static let audioSampleRate: Double = 16000
    static let audioChannels: UInt32 = 1
    static let defaultMaxChunkBytes = 1_048_576
    // ~250ms of float32 mono audio at 16kHz
    static let chunkAccumulationBytes = 16000

    // Auto-submit (press Return/Cmd+Return after paste)
    static let autoSubmitKey = "autoSubmitMode"
    static let defaultAutoSubmitMode: AutoSubmitMode = .off
    static let textInsertionPasteboardReadyDelay: Duration = .milliseconds(50)
    static let textInsertionSettleDelay: Duration = .milliseconds(350)

    // Final transcript post-processing
    static let transcriptPostProcessingModeKey = "transcriptPostProcessingMode"
    static let defaultTranscriptPostProcessingMode: TranscriptPostProcessingMode = .llm
    static let llmPostProcessingPromptKey = "llmPostProcessingPrompt"
    static let commonTermsKey = "commonTerms"
    static let rewritePromptTemplateKey = "rewritePromptTemplate"
    static let defaultLLMPostProcessingPrompt = ""

    // Launch at login
    static let launchAtLoginDisabledByUserKey = "launchAtLoginDisabledByUser"

    // Appearance
    static let appearanceModeKey = "appearanceMode"
    static let defaultAppearanceMode: AppearanceMode = .system
    static let hudDisplayModeKey = "hudDisplayMode"
    static let defaultHUDDisplayMode: HUDDisplayMode = .full

    // Silence auto-close
    static let silenceTimeoutKey = "silenceTimeout"
    static let defaultSilenceTimeout: Double = 2.0  // seconds; 0 = disabled
    static let silenceRelativeThreshold: Float = 0.15  // fraction of peak speech level
    static let silenceAbsoluteFloor: Float = 0.005  // minimum silence threshold
    static let silencePeakDecayPerSecond: Float = 0.70
    static let silenceAmbientThresholdMultiplier: Float = 1.85
    static let silenceAmbientThresholdOffset: Float = 0.0022
    static let silenceSpeechActivityThresholdMultiplier: Float = 1.20
    static let silenceSpeechActivityThresholdOffset: Float = 0.0015
    static let silenceAmbientTrackingRisePerSecond: Float = 0.35
    static let silenceAmbientTrackingFallPerSecond: Float = 0.85
    static let silenceAmbientTrackingPeakFraction: Float = 0.65
    static let silenceAmbientTrackingRelaxedPeakFraction: Float = 0.90
    // Per-band weights for the 7 FFT bands emitted by the audio capture service (low to high frequency).
    // Keep the count and ordering in sync with AudioCaptureService.bandEdges.
    static let silenceSpeechBandWeights: [Float] = [0.0, 0.15, 0.45, 1.0, 1.0, 0.8, 0.35]
    static let silenceTranscriptActivityGraceMultiplier: Double = 0.35
    static let silenceTranscriptActivityGraceMinimumSeconds: Double = 0.15
    static let silenceTranscriptActivityGraceMaximumSeconds: Double = 0.45
    static let silenceTranscriptPacketIntervalEWMASmoothing: Double = 0.35
    static let silenceTranscriptContinuationMinimumLevelMultiplier: Float = 1.1
    static let silenceTranscriptContinuationThresholdMultiplier: Float = 0.45
    static let silenceTranscriptContinuationThresholdOffset: Float = 0.0015
    static let silenceMotionWindowSeconds: Double = 0.6
    static let silenceMotionAbsoluteFloor: Float = 0.0020
    static let silenceMotionThresholdMultiplier: Float = 0.18
    static let silenceMotionContinuationSignalOffset: Float = 0.0060
    static let silenceMotionContinuationThresholdMinimumFraction: Float = 0.60
    static let silenceTimerArmDelayMinimumSeconds: Double = 0.15
    static let silenceTimerArmDelayMaximumSeconds: Double = 0.30
    static let silenceTimerArmDelayTimeoutFraction: Double = 0.15

    // App-specific behavior overrides
    static let appBehaviorOverridesKey = "appBehaviorOverrides"
    static let appBehaviorCustomAppsKey = "appBehaviorCustomApps"

    // Usage stats
    static let usageStatsWordsAllTimeKey = "usageStatsWordsAllTime"
    static let usageStatsDictatedSecondsAllTimeKey = "usageStatsDictatedSecondsAllTime"
    static let usageStatsAutoSubmitsAllTimeKey = "usageStatsAutoSubmitsAllTime"

    static func localLLMContextSize(defaults: UserDefaults = .standard) -> Int {
        let configured = defaults.integer(forKey: Constants.localLLMContextSizeKey)
        if Constants.supportedLocalLLMContextSizes.contains(configured) {
            return configured
        }
        return Constants.defaultLocalLLMContextSize
    }
}
