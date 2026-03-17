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
    static let bundleIdentifier = "com.hanzo.app"
    static let defaultServerEndpoint = ""
    static let localModelsFolderName = "models"
    static let localWhisperModel = "base.en"
    static let localWhisperModelRepository = "argmaxinc/whisperkit-coreml"
    // Remote model payload sizes (bytes) used to weight onboarding download progress.
    static let localWhisperModelExpectedDownloadBytes: Int64 = 146_707_731
    static let localWhisperPartialMinSeconds: Double = 2.0
    static let localWhisperPartialMinIntervalSeconds: Double = 0.8
    static let localWhisperPartialWindowSeconds: Double = 30.0
    static let localWhisperSessionTTLSeconds: Double = 180.0
    static let localLLMModelsSubfolderName = "llm"
    static let localLLMModelRepository = "Qwen/Qwen3-4B-GGUF"
    static let localLLMModelFileName = "Qwen3-4B-Q4_K_M.gguf"
    static let localLLMModelExpectedDownloadBytes: Int64 = 2_497_280_256
    static let localLLMModelContextSize = 2048
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
    static let defaultHotkeyModifiers: UInt32 = 4096  // Control (Carbon flag)
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

    // Final transcript post-processing
    static let transcriptPostProcessingModeKey = "transcriptPostProcessingMode"
    static let defaultTranscriptPostProcessingMode: TranscriptPostProcessingMode = .llm
    static let llmPostProcessingPromptKey = "llmPostProcessingPrompt"
    static let rewritePromptTemplateKey = "rewritePromptTemplate"
    static let defaultLLMPostProcessingPrompt = ""

    // Launch at login
    static let launchAtLoginDisabledByUserKey = "launchAtLoginDisabledByUser"

    // Appearance
    static let appearanceModeKey = "appearanceMode"
    static let defaultAppearanceMode: AppearanceMode = .system

    // Silence auto-close
    static let silenceTimeoutKey = "silenceTimeout"
    static let defaultSilenceTimeout: Double = 2.0  // seconds; 0 = disabled
    static let silenceRelativeThreshold: Float = 0.15  // fraction of peak speech level
    static let silenceAbsoluteFloor: Float = 0.005  // minimum silence threshold

    // App-specific behavior overrides
    static let appBehaviorOverridesKey = "appBehaviorOverrides"
    static let appBehaviorCustomAppsKey = "appBehaviorCustomApps"
}
