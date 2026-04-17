import Foundation

protocol AppSettingsProtocol: AnyObject {
    var appearanceMode: AppearanceMode { get set }
    var hudDisplayMode: HUDDisplayMode { get set }
    var muteSystemAudioDuringDictation: Bool { get set }
    var asrProvider: ASRProvider { get set }
    var serverEndpoint: String { get set }
    var customServerPassword: String { get set }
    var hotkeyCode: UInt32 { get set }
    var hotkeyModifiers: UInt32 { get set }
    var onboardingComplete: Bool { get set }
    var launchAtLoginDisabledByUser: Bool { get set }
    var localLLMContextSize: Int { get set }
    var globalAutoSubmitMode: AutoSubmitMode { get set }
    var globalSilenceTimeout: Double { get set }
    var globalTranscriptPostProcessingMode: TranscriptPostProcessingMode { get set }
    var globalLLMPostProcessingPrompt: String { get set }
    var globalCommonTerms: String { get set }
    var customRewritePromptTemplate: String? { get set }
    var hasSeededBuiltInAppInstructionOverrides: Bool { get set }
    var appBehaviorOverridesData: Data? { get set }
    var appBehaviorCustomAppsData: Data? { get set }
    var localLLMServerExecutableOverridePath: String? { get set }

    var hasConfiguredASRProvider: Bool { get }
    var hasConfiguredTranscriptPostProcessingMode: Bool { get }
}
