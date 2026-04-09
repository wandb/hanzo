import Foundation

final class AppSettings: AppSettingsProtocol {
    static let live: AppSettingsProtocol = AppSettings()

    private let store: AppSettingsStoreProtocol

    init(store: AppSettingsStoreProtocol = UserDefaultsAppSettingsStore()) {
        self.store = store
    }

    var appearanceMode: AppearanceMode {
        get {
            if let raw = store.string(forKey: Constants.appearanceModeKey) {
                return AppearanceMode(rawValue: raw) ?? Constants.defaultAppearanceMode
            }
            return Constants.defaultAppearanceMode
        }
        set {
            store.set(newValue.rawValue, forKey: Constants.appearanceModeKey)
        }
    }

    var hudDisplayMode: HUDDisplayMode {
        get {
            if let raw = store.string(forKey: Constants.hudDisplayModeKey) {
                return HUDDisplayMode(rawValue: raw) ?? Constants.defaultHUDDisplayMode
            }
            return Constants.defaultHUDDisplayMode
        }
        set {
            store.set(newValue.rawValue, forKey: Constants.hudDisplayModeKey)
        }
    }

    var asrProvider: ASRProvider {
        get {
            if let raw = store.string(forKey: Constants.asrProviderKey) {
                return ASRProvider(rawValue: raw) ?? Constants.defaultASRProvider
            }
            return Constants.defaultASRProvider
        }
        set {
            store.set(newValue.rawValue, forKey: Constants.asrProviderKey)
        }
    }

    var serverEndpoint: String {
        get {
            store.string(forKey: Constants.serverEndpointKey) ?? Constants.defaultServerEndpoint
        }
        set {
            store.set(newValue, forKey: Constants.serverEndpointKey)
        }
    }

    var customServerPassword: String {
        get {
            store.string(forKey: Constants.customServerPasswordKey) ?? Constants.defaultCustomServerPassword
        }
        set {
            store.set(newValue, forKey: Constants.customServerPasswordKey)
        }
    }

    var hotkeyCode: UInt32 {
        get {
            let configured = store.integer(forKey: Constants.hotkeyCodeKey)
            return configured != 0 ? UInt32(configured) : Constants.defaultHotkeyCode
        }
        set {
            store.set(Int(newValue), forKey: Constants.hotkeyCodeKey)
        }
    }

    var hotkeyModifiers: UInt32 {
        get {
            let configured = store.integer(forKey: Constants.hotkeyModifiersKey)
            return configured != 0 ? UInt32(configured) : Constants.defaultHotkeyModifiers
        }
        set {
            store.set(Int(newValue), forKey: Constants.hotkeyModifiersKey)
        }
    }

    var onboardingComplete: Bool {
        get {
            store.bool(forKey: Constants.onboardingCompleteKey)
        }
        set {
            store.set(newValue, forKey: Constants.onboardingCompleteKey)
        }
    }

    var launchAtLoginDisabledByUser: Bool {
        get {
            store.bool(forKey: Constants.launchAtLoginDisabledByUserKey)
        }
        set {
            store.set(newValue, forKey: Constants.launchAtLoginDisabledByUserKey)
        }
    }

    var localLLMContextSize: Int {
        get {
            let configured = store.integer(forKey: Constants.localLLMContextSizeKey)
            if Constants.supportedLocalLLMContextSizes.contains(configured) {
                return configured
            }
            return Constants.defaultLocalLLMContextSize
        }
        set {
            store.set(newValue, forKey: Constants.localLLMContextSizeKey)
        }
    }

    var globalAutoSubmitMode: AutoSubmitMode {
        get {
            if let raw = store.string(forKey: Constants.autoSubmitKey) {
                return AutoSubmitMode(rawValue: raw) ?? Constants.defaultAutoSubmitMode
            }
            return Constants.defaultAutoSubmitMode
        }
        set {
            store.set(newValue.rawValue, forKey: Constants.autoSubmitKey)
        }
    }

    var globalSilenceTimeout: Double {
        get {
            let hasStoredValue = store.object(forKey: Constants.silenceTimeoutKey) != nil
            return hasStoredValue
                ? store.double(forKey: Constants.silenceTimeoutKey)
                : Constants.defaultSilenceTimeout
        }
        set {
            store.set(newValue, forKey: Constants.silenceTimeoutKey)
        }
    }

    var globalTranscriptPostProcessingMode: TranscriptPostProcessingMode {
        get {
            if let raw = store.string(forKey: Constants.transcriptPostProcessingModeKey),
               let mode = TranscriptPostProcessingMode(rawValue: raw) {
                return mode
            }
            return Constants.defaultTranscriptPostProcessingMode
        }
        set {
            store.set(newValue.rawValue, forKey: Constants.transcriptPostProcessingModeKey)
        }
    }

    var globalLLMPostProcessingPrompt: String {
        get {
            let stored = store.string(forKey: Constants.llmPostProcessingPromptKey)
            return stored?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? Constants.defaultLLMPostProcessingPrompt
        }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            store.set(normalized, forKey: Constants.llmPostProcessingPromptKey)
        }
    }

    var globalCommonTerms: String {
        get {
            store.string(forKey: Constants.commonTermsKey) ?? ""
        }
        set {
            let normalized = newValue.replacingOccurrences(of: "\r\n", with: "\n")
            if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.removeObject(forKey: Constants.commonTermsKey)
                return
            }
            store.set(normalized, forKey: Constants.commonTermsKey)
        }
    }

    var customRewritePromptTemplate: String? {
        get {
            guard let stored = store.string(forKey: Constants.rewritePromptTemplateKey) else {
                return nil
            }
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : stored
        }
        set {
            guard let newValue else {
                store.removeObject(forKey: Constants.rewritePromptTemplateKey)
                return
            }

            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                store.removeObject(forKey: Constants.rewritePromptTemplateKey)
            } else {
                store.set(newValue, forKey: Constants.rewritePromptTemplateKey)
            }
        }
    }

    var hasSeededBuiltInAppInstructionOverrides: Bool {
        get {
            store.bool(forKey: Constants.builtInAppInstructionOverridesSeededKey)
        }
        set {
            store.set(newValue, forKey: Constants.builtInAppInstructionOverridesSeededKey)
        }
    }

    var appBehaviorOverridesData: Data? {
        get {
            store.data(forKey: Constants.appBehaviorOverridesKey)
        }
        set {
            if let newValue {
                store.set(newValue, forKey: Constants.appBehaviorOverridesKey)
            } else {
                store.removeObject(forKey: Constants.appBehaviorOverridesKey)
            }
        }
    }

    var appBehaviorCustomAppsData: Data? {
        get {
            store.data(forKey: Constants.appBehaviorCustomAppsKey)
        }
        set {
            if let newValue {
                store.set(newValue, forKey: Constants.appBehaviorCustomAppsKey)
            } else {
                store.removeObject(forKey: Constants.appBehaviorCustomAppsKey)
            }
        }
    }

    var localLLMServerExecutableOverridePath: String? {
        get {
            guard let stored = store.string(forKey: Constants.localLLMServerExecutableOverrideKey) else {
                return nil
            }
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : stored
        }
        set {
            guard let newValue else {
                store.removeObject(forKey: Constants.localLLMServerExecutableOverrideKey)
                return
            }

            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                store.removeObject(forKey: Constants.localLLMServerExecutableOverrideKey)
            } else {
                store.set(newValue, forKey: Constants.localLLMServerExecutableOverrideKey)
            }
        }
    }

    var hasConfiguredASRProvider: Bool {
        store.string(forKey: Constants.asrProviderKey) != nil
    }

    var hasConfiguredTranscriptPostProcessingMode: Bool {
        store.string(forKey: Constants.transcriptPostProcessingModeKey) != nil
    }
}
