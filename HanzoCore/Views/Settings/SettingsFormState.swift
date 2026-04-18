import Foundation
import ServiceManagement

/// Shared mutable form state for the settings panes. Factored into an
/// `@Observable` class so each pane can live in its own `View` struct
/// (with `@Bindable` access) without every `@State` field leaking across
/// file boundaries.
@Observable
final class SettingsFormState {
    var asrProvider: ASRProvider
    var serverEndpoint: String
    var serverPassword: String
    var hotkeyCode: UInt32
    var hotkeyModifiers: UInt32
    var launchAtLogin: Bool
    var appearanceMode: AppearanceMode
    var hudDisplayMode: HUDDisplayMode
    var globalAutoSubmitMode: AutoSubmitMode
    var globalSilenceTimeout: Double
    var transcriptPostProcessingMode: TranscriptPostProcessingMode
    var llmPostProcessingPrompt: String
    var globalCommonTerms: String
    var rewritePromptTemplate: String
    var rewritePromptTemplateValidationError: String?
    var localLLMContextSize: Int
    var appBehaviorOverrides: [String: AppBehaviorOverride]
    var supportedApps: [SupportedAppBehavior]
    var usageStats: UsageStatsSnapshot
    var isRecordingHotkey: Bool = false
    @ObservationIgnored var rewriteTemplateValidationTask: Task<Void, Never>?

    init(settings: AppSettingsProtocol) {
        self.asrProvider = settings.asrProvider
        self.serverEndpoint = settings.serverEndpoint
        self.serverPassword = settings.customServerPassword
        self.hotkeyCode = settings.hotkeyCode
        self.hotkeyModifiers = settings.hotkeyModifiers
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.appearanceMode = settings.appearanceMode
        self.hudDisplayMode = settings.hudDisplayMode
        self.globalAutoSubmitMode = settings.globalAutoSubmitMode
        self.globalSilenceTimeout = settings.globalSilenceTimeout
        self.transcriptPostProcessingMode = settings.globalTranscriptPostProcessingMode
        self.llmPostProcessingPrompt = settings.globalLLMPostProcessingPrompt
        self.globalCommonTerms = settings.globalCommonTerms

        let activeRewriteTemplate = TranscriptRewritePrompt.activeTemplate(settings: settings)
        self.rewritePromptTemplate = activeRewriteTemplate
        self.rewritePromptTemplateValidationError = TranscriptRewritePrompt.validateTemplate(activeRewriteTemplate)

        self.localLLMContextSize = settings.localLLMContextSize
        self.appBehaviorOverrides = AppBehaviorSettings.loadOverrides(settings: settings)
        self.supportedApps = AppBehaviorSettings.supportedApps(settings: settings)
        self.usageStats = UsageStatsStore.current()
    }
}
