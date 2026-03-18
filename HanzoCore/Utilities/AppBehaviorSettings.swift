import Foundation

struct SupportedAppBehavior: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String
    let isBuiltIn: Bool

    var id: String { bundleIdentifier }
}

private struct StoredCustomAppBehavior: Codable, Equatable {
    let bundleIdentifier: String
    let displayName: String
}

struct AppBehaviorOverride: Codable, Equatable {
    var autoSubmitMode: AutoSubmitMode?
    var silenceTimeout: Double?
    var postProcessingMode: TranscriptPostProcessingMode?
    var llmPostProcessingPrompt: String?

    init(
        autoSubmitMode: AutoSubmitMode? = nil,
        silenceTimeout: Double? = nil,
        postProcessingMode: TranscriptPostProcessingMode? = nil,
        llmPostProcessingPrompt: String? = nil
    ) {
        self.autoSubmitMode = autoSubmitMode
        self.silenceTimeout = silenceTimeout
        self.postProcessingMode = postProcessingMode
        self.llmPostProcessingPrompt = llmPostProcessingPrompt
    }

    var hasOverrides: Bool {
        autoSubmitMode != nil || silenceTimeout != nil || postProcessingMode != nil || llmPostProcessingPrompt != nil
    }
}

struct ResolvedAppBehavior {
    let autoSubmitMode: AutoSubmitMode
    let silenceTimeout: Double
    let postProcessingMode: TranscriptPostProcessingMode
    let llmPostProcessingPrompt: String
    let isUsingAppOverride: Bool
}

enum AppBehaviorSettings {
    enum AddCustomAppResult {
        case added
        case updated
        case alreadyExists
        case invalidBundleIdentifier
    }

    private static let builtInApps: [SupportedAppBehavior] = [
        SupportedAppBehavior(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack", isBuiltIn: true),
        SupportedAppBehavior(bundleIdentifier: "com.openai.chat", displayName: "ChatGPT", isBuiltIn: true),
        SupportedAppBehavior(bundleIdentifier: "com.anthropic.claudefordesktop", displayName: "Claude", isBuiltIn: true),
        SupportedAppBehavior(bundleIdentifier: "com.conductor.app", displayName: "Conductor", isBuiltIn: true),
        SupportedAppBehavior(bundleIdentifier: "com.microsoft.VSCode", displayName: "VS Code", isBuiltIn: true),
        SupportedAppBehavior(bundleIdentifier: "com.todesktop.230313mzl4w4u92", displayName: "Cursor", isBuiltIn: true),
        SupportedAppBehavior(bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode", isBuiltIn: true),
        SupportedAppBehavior(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal", isBuiltIn: true),
        SupportedAppBehavior(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm2", isBuiltIn: true),
        SupportedAppBehavior(bundleIdentifier: "dev.warp.Warp-Stable", displayName: "Warp", isBuiltIn: true)
    ]
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static var supportedApps: [SupportedAppBehavior] {
        supportedApps(defaults: .standard)
    }

    static func supportedApps(defaults: UserDefaults = .standard) -> [SupportedAppBehavior] {
        builtInApps + loadCustomApps(defaults: defaults).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func isSupported(bundleIdentifier: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let bundleIdentifier else { return false }
        return supportedApps(defaults: defaults).contains { $0.bundleIdentifier == bundleIdentifier }
    }

    @discardableResult
    static func addCustomApp(
        bundleIdentifier: String,
        displayName: String,
        defaults: UserDefaults = .standard
    ) -> AddCustomAppResult {
        let cleanedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedBundleIdentifier.isEmpty else {
            return .invalidBundleIdentifier
        }

        let cleanedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDisplayName = cleanedName.isEmpty ? cleanedBundleIdentifier : cleanedName

        guard !builtInApps.contains(where: { $0.bundleIdentifier == cleanedBundleIdentifier }) else {
            return .alreadyExists
        }

        var customApps = loadStoredCustomApps(defaults: defaults)
        if let existingIndex = customApps.firstIndex(where: { $0.bundleIdentifier == cleanedBundleIdentifier }) {
            if customApps[existingIndex].displayName != finalDisplayName {
                customApps[existingIndex] = StoredCustomAppBehavior(
                    bundleIdentifier: cleanedBundleIdentifier,
                    displayName: finalDisplayName
                )
                saveStoredCustomApps(customApps, defaults: defaults)
                return .updated
            }

            return .alreadyExists
        }

        customApps.append(
            StoredCustomAppBehavior(
                bundleIdentifier: cleanedBundleIdentifier,
                displayName: finalDisplayName
            )
        )
        saveStoredCustomApps(customApps, defaults: defaults)
        return .added
    }

    @discardableResult
    static func removeCustomApp(
        bundleIdentifier: String,
        removeOverride: Bool = true,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var customApps = loadStoredCustomApps(defaults: defaults)
        let originalCount = customApps.count
        customApps.removeAll { $0.bundleIdentifier == bundleIdentifier }

        guard customApps.count != originalCount else {
            return false
        }

        saveStoredCustomApps(customApps, defaults: defaults)
        if removeOverride {
            saveOverride(nil, for: bundleIdentifier, defaults: defaults)
        }

        return true
    }

    static func globalAutoSubmitMode(defaults: UserDefaults = .standard) -> AutoSubmitMode {
        if let raw = defaults.string(forKey: Constants.autoSubmitKey) {
            return AutoSubmitMode(rawValue: raw) ?? Constants.defaultAutoSubmitMode
        }
        return Constants.defaultAutoSubmitMode
    }

    static func globalSilenceTimeout(defaults: UserDefaults = .standard) -> Double {
        let storedTimeout = defaults.object(forKey: Constants.silenceTimeoutKey)
        return storedTimeout != nil
            ? defaults.double(forKey: Constants.silenceTimeoutKey)
            : Constants.defaultSilenceTimeout
    }

    static func setGlobalAutoSubmitMode(_ mode: AutoSubmitMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Constants.autoSubmitKey)
    }

    static func setGlobalSilenceTimeout(_ timeout: Double, defaults: UserDefaults = .standard) {
        defaults.set(timeout, forKey: Constants.silenceTimeoutKey)
    }

    static func globalPostProcessingMode(defaults: UserDefaults = .standard) -> TranscriptPostProcessingMode {
        if let raw = defaults.string(forKey: Constants.transcriptPostProcessingModeKey) {
            if let mode = TranscriptPostProcessingMode(rawValue: raw) {
                return mode
            }
        }
        return Constants.defaultTranscriptPostProcessingMode
    }

    static func setGlobalPostProcessingMode(
        _ mode: TranscriptPostProcessingMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: Constants.transcriptPostProcessingModeKey)
    }

    static func globalLLMPostProcessingPrompt(defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: Constants.llmPostProcessingPromptKey)
        return stored?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? Constants.defaultLLMPostProcessingPrompt
    }

    static func setGlobalLLMPostProcessingPrompt(
        _ prompt: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Constants.llmPostProcessingPromptKey
        )
    }

    static func loadOverrides(defaults: UserDefaults = .standard) -> [String: AppBehaviorOverride] {
        guard let data = defaults.data(forKey: Constants.appBehaviorOverridesKey) else {
            return [:]
        }

        guard let decoded = try? decoder.decode([String: AppBehaviorOverride].self, from: data) else {
            return [:]
        }

        return decoded
    }

    static func override(for bundleIdentifier: String, defaults: UserDefaults = .standard) -> AppBehaviorOverride? {
        loadOverrides(defaults: defaults)[bundleIdentifier]
    }

    static func shouldPersistHUDSettingsToAppOverride(
        for bundleIdentifier: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let bundleIdentifier,
              isSupported(bundleIdentifier: bundleIdentifier, defaults: defaults),
              let appOverride = override(for: bundleIdentifier, defaults: defaults) else {
            return false
        }

        return appOverride.hasOverrides
    }

    static func saveOverride(
        _ appOverride: AppBehaviorOverride?,
        for bundleIdentifier: String,
        defaults: UserDefaults = .standard
    ) {
        var overrides = loadOverrides(defaults: defaults)

        if let appOverride, appOverride.hasOverrides {
            overrides[bundleIdentifier] = appOverride
        } else {
            overrides.removeValue(forKey: bundleIdentifier)
        }

        saveOverrides(overrides, defaults: defaults)
    }

    static func resolvedBehavior(
        for bundleIdentifier: String?,
        defaults: UserDefaults = .standard
    ) -> ResolvedAppBehavior {
        let globalAutoSubmitMode = globalAutoSubmitMode(defaults: defaults)
        let globalSilenceTimeout = globalSilenceTimeout(defaults: defaults)
        let globalPostProcessing = globalPostProcessingMode(defaults: defaults)
        let globalLLMPrompt = globalLLMPostProcessingPrompt(defaults: defaults)

        guard let bundleIdentifier,
              isSupported(bundleIdentifier: bundleIdentifier, defaults: defaults),
              let appOverride = override(for: bundleIdentifier, defaults: defaults) else {
            return ResolvedAppBehavior(
                autoSubmitMode: globalAutoSubmitMode,
                silenceTimeout: globalSilenceTimeout,
                postProcessingMode: globalPostProcessing,
                llmPostProcessingPrompt: globalLLMPrompt,
                isUsingAppOverride: false
            )
        }

        let resolvedAutoSubmitMode = appOverride.autoSubmitMode ?? globalAutoSubmitMode
        let resolvedSilenceTimeout = appOverride.silenceTimeout ?? globalSilenceTimeout
        let resolvedPostProcessing = appOverride.postProcessingMode ?? globalPostProcessing
        let resolvedLLMPrompt = appOverride.llmPostProcessingPrompt ?? globalLLMPrompt
        let isUsingAppOverride = appOverride.autoSubmitMode != nil
            || appOverride.silenceTimeout != nil
            || appOverride.postProcessingMode != nil
            || appOverride.llmPostProcessingPrompt != nil

        return ResolvedAppBehavior(
            autoSubmitMode: resolvedAutoSubmitMode,
            silenceTimeout: resolvedSilenceTimeout,
            postProcessingMode: resolvedPostProcessing,
            llmPostProcessingPrompt: resolvedLLMPrompt,
            isUsingAppOverride: isUsingAppOverride
        )
    }

    private static func saveOverrides(
        _ overrides: [String: AppBehaviorOverride],
        defaults: UserDefaults
    ) {
        guard !overrides.isEmpty else {
            defaults.removeObject(forKey: Constants.appBehaviorOverridesKey)
            return
        }

        if let encoded = try? encoder.encode(overrides) {
            defaults.set(encoded, forKey: Constants.appBehaviorOverridesKey)
        }
    }

    private static func loadCustomApps(defaults: UserDefaults = .standard) -> [SupportedAppBehavior] {
        loadStoredCustomApps(defaults: defaults).map {
            SupportedAppBehavior(
                bundleIdentifier: $0.bundleIdentifier,
                displayName: $0.displayName,
                isBuiltIn: false
            )
        }
    }

    private static func loadStoredCustomApps(defaults: UserDefaults) -> [StoredCustomAppBehavior] {
        guard let data = defaults.data(forKey: Constants.appBehaviorCustomAppsKey) else {
            return []
        }

        guard let decoded = try? decoder.decode([StoredCustomAppBehavior].self, from: data) else {
            return []
        }

        return decoded
    }

    private static func saveStoredCustomApps(
        _ customApps: [StoredCustomAppBehavior],
        defaults: UserDefaults
    ) {
        guard !customApps.isEmpty else {
            defaults.removeObject(forKey: Constants.appBehaviorCustomAppsKey)
            return
        }

        if let encoded = try? encoder.encode(customApps) {
            defaults.set(encoded, forKey: Constants.appBehaviorCustomAppsKey)
        }
    }
}
