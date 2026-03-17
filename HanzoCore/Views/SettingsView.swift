import SwiftUI
import Carbon
import ServiceManagement
import AppKit

struct SettingsView: View {
    var appState: AppState
    var onSave: (() -> Void)?
    var onHotkeyChanged: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var asrProvider: ASRProvider = {
        if let raw = UserDefaults.standard.string(forKey: Constants.asrProviderKey) {
            return ASRProvider(rawValue: raw) ?? Constants.defaultASRProvider
        }
        return Constants.defaultASRProvider
    }()
    @State private var serverEndpoint: String = UserDefaults.standard.string(forKey: Constants.serverEndpointKey) ?? Constants.defaultServerEndpoint
    @State private var serverPassword: String = UserDefaults.standard.string(forKey: Constants.customServerPasswordKey) ?? Constants.defaultCustomServerPassword
    @State private var hotkeyCode: UInt32 = {
        let val = UserDefaults.standard.integer(forKey: Constants.hotkeyCodeKey)
        return val != 0 ? UInt32(val) : Constants.defaultHotkeyCode
    }()
    @State private var hotkeyModifiers: UInt32 = {
        let val = UserDefaults.standard.integer(forKey: Constants.hotkeyModifiersKey)
        return val != 0 ? UInt32(val) : Constants.defaultHotkeyModifiers
    }()
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var appearanceMode: AppearanceMode = {
        if let raw = UserDefaults.standard.string(forKey: Constants.appearanceModeKey) {
            return AppearanceMode(rawValue: raw) ?? Constants.defaultAppearanceMode
        }
        return Constants.defaultAppearanceMode
    }()
    @State private var globalAutoSubmitMode: AutoSubmitMode = AppBehaviorSettings.globalAutoSubmitMode()
    @State private var globalSilenceTimeout: Double = AppBehaviorSettings.globalSilenceTimeout()
    @State private var transcriptPostProcessingMode: TranscriptPostProcessingMode = AppBehaviorSettings.globalPostProcessingMode()
    @State private var llmPostProcessingPrompt: String = AppBehaviorSettings.globalLLMPostProcessingPrompt()
    @State private var rewritePromptTemplate: String = TranscriptRewritePrompt.activeTemplate()
    @State private var rewritePromptTemplateValidationError: String? = TranscriptRewritePrompt.validateTemplate(
        TranscriptRewritePrompt.activeTemplate()
    )
    @State private var isPromptTemplateExpanded = false
    @State private var appBehaviorOverrides: [String: AppBehaviorOverride] = AppBehaviorSettings.loadOverrides()
    @State private var supportedApps: [SupportedAppBehavior] = AppBehaviorSettings.supportedApps
    @State private var selectedSection: SettingsSection = .general
    @State private var isDetectingApp = false
    @State private var detectCountdown: Int?
    @State private var detectCurrentAppTask: Task<Void, Never>?

    @State private var isRecordingHotkey = false
    @FocusState private var focusedField: Field?
    private let silenceTimeoutOptions: [Double] = [0, 1, 2, 3, 5]
    private let inputWidth: CGFloat = 300
    private let postProcessingHelpText = "Default rewrite mode for all apps. Individual apps can override."
    private let userPromptHelpText = "Custom instructions inserted into the template as {{user_prompt}}."
    private let rewriteTemplateHelpText = "Template used to build the rewrite request for the local model."
    private let silenceTimeoutHelpText = "Stop recording after this much silence. Off disables it."
    private let autoSubmitHelpText = "Send text automatically after insert."

    private enum Field { case endpoint, serverPassword }

    private enum SettingsSection: Hashable {
        case general
        case transcription
        case app(String) // bundleIdentifier
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                sidebarButton(label: "General", icon: "gearshape", section: .general)

                Divider()
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)

                sidebarButton(label: "Transcription", icon: "waveform", section: .transcription)

                Divider()
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)

                Text("APPS")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(supportedApps) { app in
                            appSidebarButton(for: app)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)

                Button {
                    detectCurrentApp()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                        Text(detectButtonTitle)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isDetectingApp)
                .padding(.bottom, 8)
            }
            .frame(width: 160)
            .padding(.top, 12)

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: {
                        cancelDetectCurrentAppTask()
                        onClose?()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.primary.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close settings")
                }
                .padding(.bottom, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch selectedSection {
                        case .general:
                            generalContent
                        case .transcription:
                            transcriptionContent
                        case .app(let bundleIdentifier):
                            if let app = supportedApps.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                                appBehaviorContent(for: app)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(width: 680, height: 520)
        .hudBackground(colorScheme: appState.preferredColorScheme)
        .background(isRecordingHotkey ? HotkeyRecorderView(onKeyCombo: { keyCode, modifiers in
            hotkeyCode = keyCode
            hotkeyModifiers = modifiers
            isRecordingHotkey = false
            saveHotkey()
        }) .frame(width: 0, height: 0) : nil)
        .onDisappear {
            cancelDetectCurrentAppTask()
        }
    }

    // MARK: - Sidebar

    private func sidebarButton(label: String, icon: String, section: SettingsSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(label)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selectedSection == section ? Color.accentColor.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func appSidebarButton(for app: SupportedAppBehavior) -> some View {
        Button {
            selectedSection = .app(app.bundleIdentifier)
        } label: {
            HStack(spacing: 8) {
                if let icon = appSidebarIcon(for: app.bundleIdentifier) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                        .frame(width: 16)
                } else {
                    Image(systemName: "app")
                        .font(.system(size: 12))
                        .frame(width: 16)
                }
                Text(app.displayName)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selectedSection == .app(app.bundleIdentifier) ? Color.accentColor.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func appSidebarIcon(for bundleIdentifier: String) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        let genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)
        if genericIcon.size.width > 0 && genericIcon.size.height > 0 {
            return genericIcon
        }
        return nil
    }

    // MARK: - General

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General")
                .font(.system(.title3, design: .rounded, weight: .semibold))

            HStack {
                Text("Open at startup")
                    .font(.system(.body, design: .rounded))
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .onChange(of: launchAtLogin) {
                do {
                    if launchAtLogin {
                        try SMAppService.mainApp.register()
                        UserDefaults.standard.set(false, forKey: Constants.launchAtLoginDisabledByUserKey)
                    } else {
                        try SMAppService.mainApp.unregister()
                        UserDefaults.standard.set(true, forKey: Constants.launchAtLoginDisabledByUserKey)
                    }
                } catch {
                    LoggingService.shared.warn("Launch-at-login failed: \(error)")
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

            HStack {
                Text("Appearance")
                    .font(.system(.body, design: .rounded))
                Spacer()
                Picker("", selection: $appearanceMode) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .onChange(of: appearanceMode) {
                UserDefaults.standard.set(appearanceMode.rawValue, forKey: Constants.appearanceModeKey)
                appState.appearanceMode = appearanceMode
            }

            HStack {
                Text("Hotkey")
                    .font(.system(.body, design: .rounded))
                Spacer()

                Button {
                    isRecordingHotkey.toggle()
                } label: {
                    if isRecordingHotkey {
                        Text("Press a key combo...")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.blue.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(HotkeyService.displayString(keyCode: hotkeyCode, modifiers: hotkeyModifiers))
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.primary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRecordingHotkey ? "Cancel hotkey recording" : "Set hotkey")
            }
        }
    }

    // MARK: - Transcription

    private var transcriptionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription")
                .font(.system(.title3, design: .rounded, weight: .semibold))

            HStack {
                Text("Provider")
                    .font(.system(.body, design: .rounded))
                Spacer()
                Picker("", selection: $asrProvider) {
                    ForEach(ASRProvider.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: inputWidth, alignment: .trailing)
                .onChange(of: asrProvider) {
                    appState.asrProvider = asrProvider
                    saveTranscriptionSettings()
                }
            }

            if asrProvider == .server {
                TextField("Custom server endpoint", text: $serverEndpoint)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($focusedField, equals: .endpoint)
                    .onChange(of: serverEndpoint) { saveTranscriptionSettings() }

                SecureField("Server password", text: $serverPassword)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($focusedField, equals: .serverPassword)
                    .onChange(of: serverPassword) { saveTranscriptionSettings() }
            }

            appBehaviorDefaultsContent
        }
    }

    // MARK: - App Behavior Defaults

    private var appBehaviorDefaultsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                settingLabel("Silence timeout", helpText: silenceTimeoutHelpText)
                Spacer()
                Picker("", selection: $globalSilenceTimeout) {
                    ForEach(silenceTimeoutOptions, id: \.self) { timeout in
                        Text(silenceTimeoutLabel(timeout)).tag(timeout)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: inputWidth, alignment: .trailing)
            }
            .onChange(of: globalSilenceTimeout) {
                AppBehaviorSettings.setGlobalSilenceTimeout(globalSilenceTimeout)
                if appState.activeTargetBundleIdentifier == nil {
                    appState.silenceTimeout = globalSilenceTimeout
                }
                onSave?()
            }

            HStack {
                settingLabel("Auto-submit", helpText: autoSubmitHelpText)
                Spacer()
                Picker("", selection: $globalAutoSubmitMode) {
                    ForEach(AutoSubmitMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: inputWidth, alignment: .trailing)
            }
            .onChange(of: globalAutoSubmitMode) {
                AppBehaviorSettings.setGlobalAutoSubmitMode(globalAutoSubmitMode)
                if appState.activeTargetBundleIdentifier == nil {
                    appState.autoSubmitMode = globalAutoSubmitMode
                }
                onSave?()
            }

            Text("Post-processing")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .padding(.top, 2)

            HStack {
                settingLabel("Default post-processing", helpText: postProcessingHelpText)
                Spacer()
                HStack(spacing: 8) {
                    Text(transcriptPostProcessingMode == .llm ? "On (LLM)" : "Off")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: llmPostProcessingEnabledBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            .onChange(of: transcriptPostProcessingMode) {
                AppBehaviorSettings.setGlobalPostProcessingMode(transcriptPostProcessingMode)
                onSave?()
            }

            if transcriptPostProcessingMode == .llm {
                DisclosureGroup(isExpanded: $isPromptTemplateExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $rewritePromptTemplate)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(height: 160)
                            .padding(8)
                            .background(.primary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(width: 420)
                            .accessibilityLabel("Prompt template")
                            .onChange(of: rewritePromptTemplate) {
                                validateAndPersistRewriteTemplate()
                            }

                        Text("Placeholders: {{transcript}}, {{user_prompt}}, {{target_app}}, {{#user_prompt}}...{{/user_prompt}}, {{#target_app}}...{{/target_app}}")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 420, alignment: .leading)

                        if let rewritePromptTemplateValidationError {
                            Text(rewritePromptTemplateValidationError)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.red)
                                .frame(width: 420, alignment: .leading)
                        } else {
                            Text("Template is valid.")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.green)
                                .frame(width: 420, alignment: .leading)
                        }

                        HStack {
                            Spacer()
                            Button("Reset to default template") {
                                resetRewritePromptTemplate()
                            }
                            .font(.system(.caption, design: .rounded))
                            .buttonStyle(.borderless)
                        }
                        .frame(width: 420)
                    }
                    .padding(.top, 6)
                } label: {
                    settingLabel("Prompt template", helpText: rewriteTemplateHelpText)
                }

                HStack(alignment: .top) {
                    settingLabel("User prompt", helpText: userPromptHelpText)
                        .padding(.top, 8)
                    Spacer()
                    TextEditor(text: $llmPostProcessingPrompt)
                        .font(.system(.body, design: .rounded))
                        .scrollContentBackground(.hidden)
                        .frame(height: 80)
                        .padding(8)
                        .background(.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(width: inputWidth)
                        .accessibilityLabel("User prompt")
                }
                .onChange(of: llmPostProcessingPrompt) {
                    AppBehaviorSettings.setGlobalLLMPostProcessingPrompt(llmPostProcessingPrompt)
                    onSave?()
                }
            }
        }    }

    private func appBehaviorContent(for app: SupportedAppBehavior) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.displayName)
                .font(.system(.title3, design: .rounded, weight: .semibold))

            HStack {
                settingLabel("Silence timeout", helpText: silenceTimeoutHelpText)
                Spacer()
                Picker("", selection: silenceTimeoutBinding(for: app)) {
                    Text("Default").tag(nil as Double?)
                    ForEach(silenceTimeoutOptions, id: \.self) { timeout in
                        Text(silenceTimeoutLabel(timeout)).tag(Optional(timeout))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: inputWidth, alignment: .trailing)
            }

            HStack {
                settingLabel("Auto-submit", helpText: autoSubmitHelpText)
                Spacer()
                Picker("", selection: autoSubmitBinding(for: app)) {
                    Text("Default").tag(nil as AutoSubmitMode?)
                    ForEach(AutoSubmitMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(Optional(mode))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: inputWidth, alignment: .trailing)
            }

            Text("Post-processing")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .padding(.top, 2)

            HStack {
                settingLabel("Post-processing override", helpText: "Default follows the global setting. On and Off override for this app.")
                Spacer()
                Picker("", selection: postProcessingModeBinding(for: app)) {
                    Text("Default").tag(nil as TranscriptPostProcessingMode?)
                    Text("On (LLM)").tag(Optional(TranscriptPostProcessingMode.llm))
                    Text("Off").tag(Optional(TranscriptPostProcessingMode.off))
                }
                .pickerStyle(.menu)
                .frame(width: inputWidth, alignment: .trailing)
            }

            Text("Effective: \(resolvedPostProcessingMode(for: app) == .llm ? "On (LLM)" : "Off")")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            if resolvedPostProcessingMode(for: app) == .llm {
                HStack(alignment: .top) {
                    settingLabel("User prompt", helpText: userPromptHelpText)
                        .padding(.top, 8)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        TextEditor(text: llmPromptBinding(for: app))
                            .font(.system(.body, design: .rounded))
                            .scrollContentBackground(.hidden)
                            .frame(height: 80)
                            .padding(8)
                            .background(.primary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(width: inputWidth)
                            .accessibilityLabel("User prompt for \(app.displayName)")

                        if appBehaviorOverrides[app.bundleIdentifier]?.llmPostProcessingPrompt != nil {
                            Button("Reset to default") {
                                var appOverride = appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
                                appOverride.llmPostProcessingPrompt = nil
                                persistOverride(appOverride, for: app.bundleIdentifier)
                            }
                            .font(.system(.caption, design: .rounded))
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if !app.isBuiltIn {
                HStack {
                    Spacer()
                    Button("Remove App") {
                        removeCustomApp(app)
                        selectedSection = .general
                    }
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.red)
                    .buttonStyle(.borderless)
                }
            }
        }    }

    @ViewBuilder
    private func settingLabel(_ title: String, helpText: String?) -> some View {
        if let helpText {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(.body, design: .rounded))
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("\(title) info")
                    .instantTooltip(helpText)
            }
        } else {
            Text(title)
                .font(.system(.body, design: .rounded))
        }
    }

    private func resolvedPostProcessingMode(for app: SupportedAppBehavior) -> TranscriptPostProcessingMode {
        appBehaviorOverrides[app.bundleIdentifier]?.postProcessingMode ?? transcriptPostProcessingMode
    }

    private func autoSubmitBinding(for app: SupportedAppBehavior) -> Binding<AutoSubmitMode?> {
        Binding {
            appBehaviorOverrides[app.bundleIdentifier]?.autoSubmitMode
        } set: { newValue in
            var appOverride = appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
            appOverride.autoSubmitMode = newValue
            persistOverride(appOverride, for: app.bundleIdentifier)
        }
    }

    private func silenceTimeoutBinding(for app: SupportedAppBehavior) -> Binding<Double?> {
        Binding {
            appBehaviorOverrides[app.bundleIdentifier]?.silenceTimeout
        } set: { newValue in
            var appOverride = appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
            appOverride.silenceTimeout = newValue
            persistOverride(appOverride, for: app.bundleIdentifier)
        }
    }

    private func postProcessingModeBinding(for app: SupportedAppBehavior) -> Binding<TranscriptPostProcessingMode?> {
        Binding {
            appBehaviorOverrides[app.bundleIdentifier]?.postProcessingMode
        } set: { newValue in
            var appOverride = appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
            appOverride.postProcessingMode = newValue
            persistOverride(appOverride, for: app.bundleIdentifier)
        }
    }

    private func llmPromptBinding(for app: SupportedAppBehavior) -> Binding<String> {
        Binding {
            appBehaviorOverrides[app.bundleIdentifier]?.llmPostProcessingPrompt ?? llmPostProcessingPrompt
        } set: { newValue in
            var appOverride = appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
            appOverride.llmPostProcessingPrompt = newValue
            persistOverride(appOverride, for: app.bundleIdentifier)
        }
    }

    private func silenceTimeoutLabel(_ timeout: Double) -> String {
        if timeout == 0 {
            return "Off"
        }

        if timeout.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(timeout))s"
        }

        return "\(timeout)s"
    }

    private var llmPostProcessingEnabledBinding: Binding<Bool> {
        Binding {
            transcriptPostProcessingMode == .llm
        } set: { isEnabled in
            transcriptPostProcessingMode = isEnabled ? .llm : .off
        }
    }

    private func validateAndPersistRewriteTemplate() {
        rewritePromptTemplateValidationError = TranscriptRewritePrompt.validateTemplate(rewritePromptTemplate)

        guard rewritePromptTemplateValidationError == nil else {
            return
        }

        TranscriptRewritePrompt.setCustomTemplate(rewritePromptTemplate)
        onSave?()
    }

    private func resetRewritePromptTemplate() {
        rewritePromptTemplate = TranscriptRewritePrompt.defaultTemplate()
        rewritePromptTemplateValidationError = nil
        TranscriptRewritePrompt.setCustomTemplate(nil)
        onSave?()
    }

    private func persistOverride(_ appOverride: AppBehaviorOverride, for bundleIdentifier: String) {
        if appOverride.hasOverrides {
            appBehaviorOverrides[bundleIdentifier] = appOverride
            AppBehaviorSettings.saveOverride(appOverride, for: bundleIdentifier)
        } else {
            appBehaviorOverrides.removeValue(forKey: bundleIdentifier)
            AppBehaviorSettings.saveOverride(nil, for: bundleIdentifier)
        }

        onSave?()
    }

    private var detectButtonTitle: String {
        if let detectCountdown {
            return "Adding in \(detectCountdown)s..."
        }
        return "Add New App"
    }

    private func detectCurrentApp() {
        guard !isDetectingApp else { return }
        isDetectingApp = true
        detectCurrentAppTask?.cancel()

        detectCurrentAppTask = Task {
            for remaining in stride(from: 3, through: 1, by: -1) {
                if Task.isCancelled {
                    await MainActor.run {
                        clearDetectCurrentAppState()
                    }
                    return
                }

                await MainActor.run {
                    detectCountdown = remaining
                }

                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    await MainActor.run {
                        clearDetectCurrentAppState()
                    }
                    return
                }
            }

            await MainActor.run {
                guard !Task.isCancelled else {
                    clearDetectCurrentAppState()
                    return
                }

                detectCountdown = nil
                isDetectingApp = false
                detectCurrentAppTask = nil
                captureFrontmostAppForCustomBehavior()
            }
        }
    }

    private func clearDetectCurrentAppState() {
        detectCountdown = nil
        isDetectingApp = false
        detectCurrentAppTask = nil
    }

    private func cancelDetectCurrentAppTask() {
        detectCurrentAppTask?.cancel()
        clearDetectCurrentAppState()
    }

    private func captureFrontmostAppForCustomBehavior() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontmostApp.bundleIdentifier else {
            return
        }

        if bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }

        let appName = frontmostApp.localizedName ?? bundleIdentifier
        let result = AppBehaviorSettings.addCustomApp(
            bundleIdentifier: bundleIdentifier,
            displayName: appName
        )
        supportedApps = AppBehaviorSettings.supportedApps

        switch result {
        case .added, .updated:
            onSave?()
        case .alreadyExists, .invalidBundleIdentifier:
            break
        }
    }

    private func removeCustomApp(_ app: SupportedAppBehavior) {
        guard !app.isBuiltIn else { return }

        _ = AppBehaviorSettings.removeCustomApp(bundleIdentifier: app.bundleIdentifier)
        appBehaviorOverrides.removeValue(forKey: app.bundleIdentifier)
        supportedApps = AppBehaviorSettings.supportedApps
        onSave?()
    }

    private func saveTranscriptionSettings() {
        UserDefaults.standard.set(asrProvider.rawValue, forKey: Constants.asrProviderKey)
        UserDefaults.standard.set(serverEndpoint, forKey: Constants.serverEndpointKey)
        UserDefaults.standard.set(serverPassword, forKey: Constants.customServerPasswordKey)
        appState.asrProvider = asrProvider
        onSave?()
    }

    private func saveHotkey() {
        UserDefaults.standard.set(Int(hotkeyCode), forKey: Constants.hotkeyCodeKey)
        UserDefaults.standard.set(Int(hotkeyModifiers), forKey: Constants.hotkeyModifiersKey)
        onHotkeyChanged?()
    }

}

// MARK: - Instant Tooltip

private struct InstantTooltipModifier: ViewModifier {
    let text: String
    @State private var showTooltip = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.08)) {
                    showTooltip = hovering
                }
            }
            .overlay(alignment: .topLeading) {
                if showTooltip {
                    Text(text)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.primary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.primary.opacity(0.2), lineWidth: 0.5)
                        )
                        .allowsHitTesting(false)
                        .frame(width: 220, alignment: .leading)
                        .offset(x: 16, y: -10)
                        .transition(.opacity)
                        .zIndex(20)
                }
            }
    }
}

private extension View {
    func instantTooltip(_ text: String) -> some View {
        modifier(InstantTooltipModifier(text: text))
    }
}

// MARK: - Hotkey Recorder

private struct HotkeyRecorderView: NSViewRepresentable {
    var onKeyCombo: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onKeyCombo = onKeyCombo
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.onKeyCombo = onKeyCombo
    }
}

private class HotkeyRecorderNSView: NSView {
    var onKeyCombo: ((UInt32, UInt32) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    override func removeFromSuperview() {
        stopMonitoring()
        super.removeFromSuperview()
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Require at least one modifier (Ctrl, Option, Cmd, or Shift)
        guard !modifiers.intersection([.control, .option, .command, .shift]).isEmpty else { return }

        // Ignore modifier-only key presses
        let keyCode = event.keyCode
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62] // Cmd, Shift, Option, Control variants
        guard !modifierKeyCodes.contains(keyCode) else { return }

        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }

        onKeyCombo?(UInt32(keyCode), carbonModifiers)
    }
}
