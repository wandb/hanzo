import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppBehaviorPaneView: View {
    let app: SupportedAppBehavior
    @Bindable var form: SettingsFormState
    let settings: AppSettingsProtocol
    let silenceTimeoutOptions: [Double]
    let menuInputWidth: CGFloat
    var onSave: (() -> Void)?
    var onRemoved: (() -> Void)?

    private let silenceTimeoutHelpText = "Stop recording after this much silence. Off disables it."
    private let autoSubmitHelpText = "Press Enter or Cmd+Enter automatically after insert."
    private let appCommonTermsHelpText = "Per-app terms are merged after global terms. One term per line."

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSectionHeader(
                title: app.displayName,
                subtitle: "Configure app-specific transcription and auto edit behavior."
            )

            SettingsSectionHeader(
                title: "Transcription",
                subtitle: "Override global transcription behavior for this app."
            )

            HStack(alignment: .top) {
                SettingLabel(title: "Silence timeout", helpText: silenceTimeoutHelpText)
                Spacer()
                Picker("", selection: silenceTimeoutBinding) {
                    Text("Default").tag(nil as Double?)
                    ForEach(silenceTimeoutOptions, id: \.self) { timeout in
                        Text(SettingsFormatting.silenceTimeoutLabel(timeout)).tag(Optional(timeout))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: menuInputWidth, alignment: .trailing)
            }

            HStack(alignment: .top) {
                SettingLabel(title: "Submit after insert", helpText: autoSubmitHelpText)
                Spacer()
                Picker("", selection: autoSubmitBinding) {
                    Text("Default").tag(nil as AutoSubmitMode?)
                    ForEach(AutoSubmitMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(Optional(mode))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: menuInputWidth, alignment: .trailing)
            }

            Divider()

            SettingsSectionHeader(
                title: "Auto edit",
                subtitle: "App instructions and common terms override the global template variables for this app."
            )

            HStack(alignment: .top) {
                SettingLabel(
                    title: "Override",
                    helpText: "Default follows the global setting. On and Off override for this app."
                )
                Spacer()
                Picker("", selection: postProcessingModeBinding) {
                    Text("Default").tag(nil as TranscriptPostProcessingMode?)
                    Text("On").tag(Optional(TranscriptPostProcessingMode.llm))
                    Text("Off").tag(Optional(TranscriptPostProcessingMode.off))
                }
                .pickerStyle(.menu)
                .frame(width: menuInputWidth, alignment: .trailing)
            }

            if resolvedPostProcessingMode == .llm {
                VStack(alignment: .leading, spacing: 6) {
                    SettingLabel(title: "Instructions", helpText: appInstructionsHelpText)
                    TextEditor(text: llmPromptBinding)
                        .font(.system(.body, design: .rounded))
                        .scrollContentBackground(.hidden)
                        .frame(height: 80)
                        .padding(8)
                        .background(.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Instructions for \(app.displayName)")

                    if form.appBehaviorOverrides[app.bundleIdentifier]?.llmPostProcessingPrompt != nil {
                        HStack {
                            Spacer()
                            Button("Reset to default") {
                                var appOverride = form.appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
                                appOverride.llmPostProcessingPrompt = nil
                                persistOverride(appOverride)
                            }
                            .font(.system(.caption, design: .rounded))
                            .buttonStyle(.borderless)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SettingLabel(title: "Common terms", helpText: appCommonTermsHelpText)
                    TextEditor(text: appCommonTermsBinding)
                        .font(.system(.body, design: .rounded))
                        .scrollContentBackground(.hidden)
                        .frame(height: 100)
                        .padding(8)
                        .background(.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Common terms for \(app.displayName)")
                }
            }

            if !app.isBuiltIn {
                HStack {
                    Spacer()
                    Button("Remove App") {
                        removeCustomApp()
                    }
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.red)
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Bindings

    private var resolvedPostProcessingMode: TranscriptPostProcessingMode {
        form.appBehaviorOverrides[app.bundleIdentifier]?.postProcessingMode ?? form.transcriptPostProcessingMode
    }

    private var autoSubmitBinding: Binding<AutoSubmitMode?> {
        Binding {
            form.appBehaviorOverrides[app.bundleIdentifier]?.autoSubmitMode
        } set: { newValue in
            var appOverride = form.appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
            appOverride.autoSubmitMode = newValue
            persistOverride(appOverride)
        }
    }

    private var silenceTimeoutBinding: Binding<Double?> {
        Binding {
            form.appBehaviorOverrides[app.bundleIdentifier]?.silenceTimeout
        } set: { newValue in
            var appOverride = form.appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
            appOverride.silenceTimeout = newValue
            persistOverride(appOverride)
        }
    }

    private var postProcessingModeBinding: Binding<TranscriptPostProcessingMode?> {
        Binding {
            form.appBehaviorOverrides[app.bundleIdentifier]?.postProcessingMode
        } set: { newValue in
            var appOverride = form.appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
            appOverride.postProcessingMode = newValue
            persistOverride(appOverride)
        }
    }

    private var llmPromptBinding: Binding<String> {
        Binding {
            resolvedLLMPrompt
        } set: { newValue in
            var appOverride = form.appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
            appOverride.llmPostProcessingPrompt = newValue
            persistOverride(appOverride)
        }
    }

    private var appCommonTermsBinding: Binding<String> {
        Binding {
            form.appBehaviorOverrides[app.bundleIdentifier]?.commonTerms ?? ""
        } set: { newValue in
            var appOverride = form.appBehaviorOverrides[app.bundleIdentifier] ?? AppBehaviorOverride()
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appOverride.commonTerms = nil
            } else {
                appOverride.commonTerms = newValue
            }
            persistOverride(appOverride)
        }
    }

    private var resolvedLLMPrompt: String {
        form.appBehaviorOverrides[app.bundleIdentifier]?.llmPostProcessingPrompt ?? form.llmPostProcessingPrompt
    }

    private var appInstructionsHelpText: String {
        "App instructions override the global instructions variable. If not set, this app uses the global value."
    }

    // MARK: - Actions

    private func persistOverride(_ appOverride: AppBehaviorOverride) {
        if appOverride.hasOverrides {
            form.appBehaviorOverrides[app.bundleIdentifier] = appOverride
            AppBehaviorSettings.saveOverride(appOverride, for: app.bundleIdentifier, settings: settings)
        } else {
            form.appBehaviorOverrides.removeValue(forKey: app.bundleIdentifier)
            AppBehaviorSettings.saveOverride(nil, for: app.bundleIdentifier, settings: settings)
        }

        onSave?()
    }

    private func removeCustomApp() {
        guard !app.isBuiltIn else { return }

        _ = AppBehaviorSettings.removeCustomApp(
            bundleIdentifier: app.bundleIdentifier,
            settings: settings
        )
        form.appBehaviorOverrides.removeValue(forKey: app.bundleIdentifier)
        form.supportedApps = AppBehaviorSettings.supportedApps(settings: settings)
        onSave?()
        onRemoved?()
    }
}

enum SettingsFormatting {
    static func silenceTimeoutLabel(_ timeout: Double) -> String {
        if timeout == 0 { return "Off" }
        if timeout.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(timeout))s"
        }
        return "\(timeout)s"
    }
}
