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
    var commonTerms: String?

    init(
        autoSubmitMode: AutoSubmitMode? = nil,
        silenceTimeout: Double? = nil,
        postProcessingMode: TranscriptPostProcessingMode? = nil,
        llmPostProcessingPrompt: String? = nil,
        commonTerms: String? = nil
    ) {
        self.autoSubmitMode = autoSubmitMode
        self.silenceTimeout = silenceTimeout
        self.postProcessingMode = postProcessingMode
        self.llmPostProcessingPrompt = llmPostProcessingPrompt
        self.commonTerms = commonTerms
    }

    var hasOverrides: Bool {
        autoSubmitMode != nil
            || silenceTimeout != nil
            || postProcessingMode != nil
            || llmPostProcessingPrompt != nil
            || commonTerms != nil
    }

    var hasHUDOverrides: Bool {
        autoSubmitMode != nil
            || silenceTimeout != nil
            || postProcessingMode != nil
    }
}

struct ResolvedAppBehavior {
    let autoSubmitMode: AutoSubmitMode
    let silenceTimeout: Double
    let postProcessingMode: TranscriptPostProcessingMode
    let llmPostProcessingPrompt: String
    let commonTerms: [String]
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
    private static let builtInAppInstructionOverrides: [String: String] = [
        "com.tinyspeck.slackmacgap":
            "Polish into a concise Slack message. Preserve existing @mentions, /commands, and #channels. Convert clear spoken forms like \"at <name>\" to @mentions (full names can include a space, for example @John Smith), \"slash <command>\" to /commands, and \"hashtag <channel name>\" to lowercase #channel-name with no spaces.",
        "com.conductor.app":
            "Polish into a concise request for an AI coding agent. Preserve existing @mentions and /commands. Convert clear spoken forms like \"at <name>\" and \"slash <command>\" when intent is explicit.",
        "com.openai.chat":
            "Polish into a clear AI prompt. Preserve existing @mentions and /commands. Convert clear spoken forms like \"at <name>\" and \"slash <command>\" when intent is explicit.",
        "com.anthropic.claudefordesktop":
            "Polish into a clear AI prompt. Preserve existing @mentions and /commands. Convert clear spoken forms like \"at <name>\" and \"slash <command>\" when intent is explicit.",
        "com.todesktop.230313mzl4w4u92":
            "Polish into a concise coding-assistant prompt. Preserve existing @mentions and /commands. Convert clear spoken forms like \"at <name>\" and \"slash <command>\" when intent is explicit.",
        "com.microsoft.VSCode":
            "Lightly clean up dictation for clarity while preserving technical terms.",
        "com.apple.dt.Xcode":
            "Lightly clean up dictation for clarity while preserving technical terms.",
        "com.apple.Terminal":
            "Lightly clean up dictation while preserving command intent and syntax.",
        "com.googlecode.iterm2":
            "Lightly clean up dictation while preserving command intent and syntax.",
        "dev.warp.Warp-Stable":
            "Lightly clean up dictation while preserving command intent and syntax."
    ]
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static var supportedApps: [SupportedAppBehavior] {
        supportedApps(settings: AppSettings.live)
    }

    static func supportedApps(defaults: UserDefaults = .standard) -> [SupportedAppBehavior] {
        supportedApps(settings: settings(from: defaults))
    }

    static func supportedApps(settings: AppSettingsProtocol) -> [SupportedAppBehavior] {
        builtInApps + loadCustomApps(settings: settings).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func isSupported(bundleIdentifier: String?, defaults: UserDefaults = .standard) -> Bool {
        isSupported(bundleIdentifier: bundleIdentifier, settings: settings(from: defaults))
    }

    static func isSupported(bundleIdentifier: String?, settings: AppSettingsProtocol) -> Bool {
        guard let bundleIdentifier else { return false }
        return supportedApps(settings: settings).contains { $0.bundleIdentifier == bundleIdentifier }
    }

    @discardableResult
    static func addCustomApp(
        bundleIdentifier: String,
        displayName: String,
        defaults: UserDefaults = .standard
    ) -> AddCustomAppResult {
        addCustomApp(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            settings: settings(from: defaults)
        )
    }

    @discardableResult
    static func addCustomApp(
        bundleIdentifier: String,
        displayName: String,
        settings: AppSettingsProtocol
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

        var customApps = loadStoredCustomApps(settings: settings)
        if let existingIndex = customApps.firstIndex(where: { $0.bundleIdentifier == cleanedBundleIdentifier }) {
            if customApps[existingIndex].displayName != finalDisplayName {
                customApps[existingIndex] = StoredCustomAppBehavior(
                    bundleIdentifier: cleanedBundleIdentifier,
                    displayName: finalDisplayName
                )
                saveStoredCustomApps(customApps, settings: settings)
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
        saveStoredCustomApps(customApps, settings: settings)
        return .added
    }

    @discardableResult
    static func removeCustomApp(
        bundleIdentifier: String,
        removeOverride: Bool = true,
        defaults: UserDefaults = .standard
    ) -> Bool {
        removeCustomApp(
            bundleIdentifier: bundleIdentifier,
            removeOverride: removeOverride,
            settings: settings(from: defaults)
        )
    }

    @discardableResult
    static func removeCustomApp(
        bundleIdentifier: String,
        removeOverride: Bool = true,
        settings: AppSettingsProtocol
    ) -> Bool {
        var customApps = loadStoredCustomApps(settings: settings)
        let originalCount = customApps.count
        customApps.removeAll { $0.bundleIdentifier == bundleIdentifier }

        guard customApps.count != originalCount else {
            return false
        }

        saveStoredCustomApps(customApps, settings: settings)
        if removeOverride {
            saveOverride(nil, for: bundleIdentifier, settings: settings)
        }

        return true
    }

    static func globalAutoSubmitMode(defaults: UserDefaults = .standard) -> AutoSubmitMode {
        globalAutoSubmitMode(settings: settings(from: defaults))
    }

    static func globalAutoSubmitMode(settings: AppSettingsProtocol) -> AutoSubmitMode {
        settings.globalAutoSubmitMode
    }

    static func globalSilenceTimeout(defaults: UserDefaults = .standard) -> Double {
        globalSilenceTimeout(settings: settings(from: defaults))
    }

    static func globalSilenceTimeout(settings: AppSettingsProtocol) -> Double {
        settings.globalSilenceTimeout
    }

    static func setGlobalAutoSubmitMode(_ mode: AutoSubmitMode, defaults: UserDefaults = .standard) {
        setGlobalAutoSubmitMode(mode, settings: settings(from: defaults))
    }

    static func setGlobalAutoSubmitMode(_ mode: AutoSubmitMode, settings: AppSettingsProtocol) {
        settings.globalAutoSubmitMode = mode
    }

    static func setGlobalSilenceTimeout(_ timeout: Double, defaults: UserDefaults = .standard) {
        setGlobalSilenceTimeout(timeout, settings: settings(from: defaults))
    }

    static func setGlobalSilenceTimeout(_ timeout: Double, settings: AppSettingsProtocol) {
        settings.globalSilenceTimeout = timeout
    }

    static func globalPostProcessingMode(defaults: UserDefaults = .standard) -> TranscriptPostProcessingMode {
        globalPostProcessingMode(settings: settings(from: defaults))
    }

    static func globalPostProcessingMode(settings: AppSettingsProtocol) -> TranscriptPostProcessingMode {
        settings.globalTranscriptPostProcessingMode
    }

    static func setGlobalPostProcessingMode(
        _ mode: TranscriptPostProcessingMode,
        defaults: UserDefaults = .standard
    ) {
        setGlobalPostProcessingMode(mode, settings: settings(from: defaults))
    }

    static func setGlobalPostProcessingMode(
        _ mode: TranscriptPostProcessingMode,
        settings: AppSettingsProtocol
    ) {
        settings.globalTranscriptPostProcessingMode = mode
    }

    static func globalLLMPostProcessingPrompt(defaults: UserDefaults = .standard) -> String {
        globalLLMPostProcessingPrompt(settings: settings(from: defaults))
    }

    static func globalLLMPostProcessingPrompt(settings: AppSettingsProtocol) -> String {
        settings.globalLLMPostProcessingPrompt
    }

    static func setGlobalLLMPostProcessingPrompt(
        _ prompt: String,
        defaults: UserDefaults = .standard
    ) {
        setGlobalLLMPostProcessingPrompt(prompt, settings: settings(from: defaults))
    }

    static func setGlobalLLMPostProcessingPrompt(
        _ prompt: String,
        settings: AppSettingsProtocol
    ) {
        settings.globalLLMPostProcessingPrompt = prompt
    }

    static func globalCommonTerms(defaults: UserDefaults = .standard) -> String {
        globalCommonTerms(settings: settings(from: defaults))
    }

    static func globalCommonTerms(settings: AppSettingsProtocol) -> String {
        settings.globalCommonTerms
    }

    static func setGlobalCommonTerms(_ terms: String, defaults: UserDefaults = .standard) {
        setGlobalCommonTerms(terms, settings: settings(from: defaults))
    }

    static func setGlobalCommonTerms(_ terms: String, settings: AppSettingsProtocol) {
        settings.globalCommonTerms = terms
    }

    static func seedBuiltInAppInstructionOverridesIfNeeded(defaults: UserDefaults = .standard) {
        seedBuiltInAppInstructionOverridesIfNeeded(settings: settings(from: defaults))
    }

    static func seedBuiltInAppInstructionOverridesIfNeeded(settings: AppSettingsProtocol) {
        guard !settings.hasSeededBuiltInAppInstructionOverrides else {
            return
        }

        var overrides = loadOverrides(settings: settings)

        for (bundleIdentifier, instructions) in builtInAppInstructionOverrides {
            var appOverride = overrides[bundleIdentifier] ?? AppBehaviorOverride()
            guard appOverride.llmPostProcessingPrompt == nil else {
                continue
            }

            appOverride.llmPostProcessingPrompt = instructions
            overrides[bundleIdentifier] = appOverride
        }

        saveOverrides(overrides, settings: settings)
        settings.hasSeededBuiltInAppInstructionOverrides = true
    }

    static func loadOverrides(defaults: UserDefaults = .standard) -> [String: AppBehaviorOverride] {
        loadOverrides(settings: settings(from: defaults))
    }

    static func loadOverrides(settings: AppSettingsProtocol) -> [String: AppBehaviorOverride] {
        guard let data = settings.appBehaviorOverridesData else {
            return [:]
        }

        guard let decoded = try? decoder.decode([String: AppBehaviorOverride].self, from: data) else {
            return [:]
        }

        return decoded
    }

    static func override(for bundleIdentifier: String, defaults: UserDefaults = .standard) -> AppBehaviorOverride? {
        override(for: bundleIdentifier, settings: settings(from: defaults))
    }

    static func override(for bundleIdentifier: String, settings: AppSettingsProtocol) -> AppBehaviorOverride? {
        loadOverrides(settings: settings)[bundleIdentifier]
    }

    static func shouldPersistHUDSettingsToAppOverride(
        for bundleIdentifier: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldPersistHUDSettingsToAppOverride(for: bundleIdentifier, settings: settings(from: defaults))
    }

    static func shouldPersistHUDSettingsToAppOverride(
        for bundleIdentifier: String?,
        settings: AppSettingsProtocol
    ) -> Bool {
        hudSettingsOverride(for: bundleIdentifier, settings: settings) != nil
    }

    static func hudSettingsOverride(
        for bundleIdentifier: String?,
        defaults: UserDefaults = .standard
    ) -> (bundleIdentifier: String, appOverride: AppBehaviorOverride)? {
        hudSettingsOverride(for: bundleIdentifier, settings: settings(from: defaults))
    }

    static func hudSettingsOverride(
        for bundleIdentifier: String?,
        settings: AppSettingsProtocol
    ) -> (bundleIdentifier: String, appOverride: AppBehaviorOverride)? {
        guard let bundleIdentifier,
              isSupported(bundleIdentifier: bundleIdentifier, settings: settings),
              let appOverride = override(for: bundleIdentifier, settings: settings),
              appOverride.hasHUDOverrides else {
            return nil
        }

        return (bundleIdentifier, appOverride)
    }

    static func saveOverride(
        _ appOverride: AppBehaviorOverride?,
        for bundleIdentifier: String,
        defaults: UserDefaults = .standard
    ) {
        saveOverride(appOverride, for: bundleIdentifier, settings: settings(from: defaults))
    }

    static func saveOverride(
        _ appOverride: AppBehaviorOverride?,
        for bundleIdentifier: String,
        settings: AppSettingsProtocol
    ) {
        var overrides = loadOverrides(settings: settings)

        if let appOverride, appOverride.hasOverrides {
            overrides[bundleIdentifier] = appOverride
        } else {
            overrides.removeValue(forKey: bundleIdentifier)
        }

        saveOverrides(overrides, settings: settings)
    }

    static func resolvedBehavior(
        for bundleIdentifier: String?,
        defaults: UserDefaults = .standard
    ) -> ResolvedAppBehavior {
        resolvedBehavior(for: bundleIdentifier, settings: settings(from: defaults))
    }

    static func resolvedBehavior(
        for bundleIdentifier: String?,
        settings: AppSettingsProtocol
    ) -> ResolvedAppBehavior {
        let globalAutoSubmitMode = globalAutoSubmitMode(settings: settings)
        let globalSilenceTimeout = globalSilenceTimeout(settings: settings)
        let globalPostProcessing = globalPostProcessingMode(settings: settings)
        let globalLLMPrompt = globalLLMPostProcessingPrompt(settings: settings)
        let globalCommonTermsRaw = globalCommonTerms(settings: settings)

        guard let bundleIdentifier,
              isSupported(bundleIdentifier: bundleIdentifier, settings: settings) else {
            return ResolvedAppBehavior(
                autoSubmitMode: globalAutoSubmitMode,
                silenceTimeout: globalSilenceTimeout,
                postProcessingMode: globalPostProcessing,
                llmPostProcessingPrompt: globalLLMPrompt,
                commonTerms: CommonTerms.parse(globalCommonTermsRaw),
                isUsingAppOverride: false
            )
        }

        let appOverride = override(for: bundleIdentifier, settings: settings)
        let resolvedAutoSubmitMode = appOverride?.autoSubmitMode ?? globalAutoSubmitMode
        let resolvedSilenceTimeout = appOverride?.silenceTimeout ?? globalSilenceTimeout
        let resolvedPostProcessing = appOverride?.postProcessingMode ?? globalPostProcessing
        let resolvedLLMPrompt = appOverride?.llmPostProcessingPrompt ?? globalLLMPrompt
        let resolvedCommonTerms = CommonTerms.merge(
            globalRaw: globalCommonTermsRaw,
            appRaw: appOverride?.commonTerms
        )
        let isUsingAppOverride = appOverride?.hasOverrides == true

        return ResolvedAppBehavior(
            autoSubmitMode: resolvedAutoSubmitMode,
            silenceTimeout: resolvedSilenceTimeout,
            postProcessingMode: resolvedPostProcessing,
            llmPostProcessingPrompt: resolvedLLMPrompt,
            commonTerms: resolvedCommonTerms,
            isUsingAppOverride: isUsingAppOverride
        )
    }

    private static func saveOverrides(
        _ overrides: [String: AppBehaviorOverride],
        settings: AppSettingsProtocol
    ) {
        guard !overrides.isEmpty else {
            settings.appBehaviorOverridesData = nil
            return
        }

        if let encoded = try? encoder.encode(overrides) {
            settings.appBehaviorOverridesData = encoded
        }
    }

    private static func loadCustomApps(settings: AppSettingsProtocol) -> [SupportedAppBehavior] {
        loadStoredCustomApps(settings: settings).map {
            SupportedAppBehavior(
                bundleIdentifier: $0.bundleIdentifier,
                displayName: $0.displayName,
                isBuiltIn: false
            )
        }
    }

    private static func loadStoredCustomApps(settings: AppSettingsProtocol) -> [StoredCustomAppBehavior] {
        guard let data = settings.appBehaviorCustomAppsData else {
            return []
        }

        guard let decoded = try? decoder.decode([StoredCustomAppBehavior].self, from: data) else {
            return []
        }

        return decoded
    }

    private static func saveStoredCustomApps(
        _ customApps: [StoredCustomAppBehavior],
        settings: AppSettingsProtocol
    ) {
        guard !customApps.isEmpty else {
            settings.appBehaviorCustomAppsData = nil
            return
        }

        if let encoded = try? encoder.encode(customApps) {
            settings.appBehaviorCustomAppsData = encoded
        }
    }

    private static func settings(from defaults: UserDefaults) -> AppSettingsProtocol {
        AppSettings(store: UserDefaultsAppSettingsStore(defaults: defaults))
    }
}
