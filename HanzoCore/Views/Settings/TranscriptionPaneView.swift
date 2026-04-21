import SwiftUI

struct TranscriptionPaneView: View {
    @Bindable var form: SettingsFormState
    var appState: AppState
    let settings: AppSettingsProtocol
    let silenceTimeoutOptions: [Double]
    let segmentedInputWidth: CGFloat
    let menuInputWidth: CGFloat
    var onSave: (() -> Void)?

    private enum Field { case endpoint, serverPassword }
    @FocusState private var focusedField: Field?

    private let postProcessingHelpText = "Automatically edits transcribed text using your local model. Per-app instructions and common terms override the global template variables."
    private let instructionsHelpText = "Global auto edit instructions inserted into the system template as {{instructions}}. Used when an app does not define its own instructions."
    private let commonTermsHelpText = "Preferred vocabulary for rewrite. One term per line. Injected only when your template includes {{common_terms}}."
    private let rewriteTemplateHelpText = "System prompt template used to guide the local auto edit model. The transcript is sent separately as the user message."
    private let localLLMContextHelpText = "Maximum context window for local auto edit inference. If the app is using too much memory, try lowering this setting."
    private let silenceTimeoutHelpText = "Stop recording after this much silence. Off disables it."
    private let autoSubmitHelpText = "Press Enter or Cmd+Enter automatically after insert."

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSectionHeader(
                title: "Transcription",
                subtitle: "Choose your provider and configure dictation auto edit defaults."
            )

            HStack {
                Text("Provider")
                    .font(.system(.body, design: .rounded))
                Spacer()
                Picker("", selection: $form.asrProvider) {
                    ForEach(ASRProvider.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: segmentedInputWidth, alignment: .trailing)
                .onChange(of: form.asrProvider) {
                    appState.asrProvider = form.asrProvider
                    saveTranscriptionSettings()
                }
            }

            if form.asrProvider == .server {
                TextField("Custom server endpoint", text: $form.serverEndpoint)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($focusedField, equals: .endpoint)
                    .onChange(of: form.serverEndpoint) { saveTranscriptionSettings() }

                SecureField("Server password", text: $form.serverPassword)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($focusedField, equals: .serverPassword)
                    .onChange(of: form.serverPassword) { saveTranscriptionSettings() }
            }

            appBehaviorDefaultsContent
        }
    }

    private var appBehaviorDefaultsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                SettingLabel(title: "Silence timeout", helpText: silenceTimeoutHelpText)
                Spacer()
                Picker("", selection: $form.globalSilenceTimeout) {
                    ForEach(silenceTimeoutOptions, id: \.self) { timeout in
                        Text(SettingsFormatting.silenceTimeoutLabel(timeout)).tag(timeout)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: menuInputWidth, alignment: .trailing)
            }
            .onChange(of: form.globalSilenceTimeout) {
                AppBehaviorSettings.setGlobalSilenceTimeout(form.globalSilenceTimeout, settings: settings)
                if appState.activeTargetBundleIdentifier == nil {
                    appState.silenceTimeout = form.globalSilenceTimeout
                }
                onSave?()
            }

            HStack(alignment: .top) {
                SettingLabel(title: "Submit after insert", helpText: autoSubmitHelpText)
                Spacer()
                Picker("", selection: $form.globalAutoSubmitMode) {
                    ForEach(AutoSubmitMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: menuInputWidth, alignment: .trailing)
            }
            .onChange(of: form.globalAutoSubmitMode) {
                AppBehaviorSettings.setGlobalAutoSubmitMode(form.globalAutoSubmitMode, settings: settings)
                if appState.activeTargetBundleIdentifier == nil {
                    appState.autoSubmitMode = form.globalAutoSubmitMode
                }
                onSave?()
            }

            Divider()

            SettingsSectionHeader(title: "Auto edit", subtitle: postProcessingHelpText)

            HStack(alignment: .top) {
                SettingLabel(title: "Enabled", helpText: nil)
                Spacer()
                HStack(spacing: 8) {
                    Text(form.transcriptPostProcessingMode == .llm ? "On" : "Off")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: llmPostProcessingEnabledBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            .onChange(of: form.transcriptPostProcessingMode) {
                AppBehaviorSettings.setGlobalPostProcessingMode(
                    form.transcriptPostProcessingMode,
                    settings: settings
                )
                onSave?()
            }

            if form.transcriptPostProcessingMode == .llm {
                rewriteTemplateSection
                instructionsSection
                commonTermsSection
            }

            if form.asrProvider == .local {
                HStack(alignment: .top) {
                    SettingLabel(title: "Context", helpText: localLLMContextHelpText)
                    Spacer()
                    Picker("", selection: $form.localLLMContextSize) {
                        ForEach(Constants.supportedLocalLLMContextSizes, id: \.self) { size in
                            Text("\(size) tokens").tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: menuInputWidth, alignment: .trailing)
                }
                .onChange(of: form.localLLMContextSize) {
                    saveTranscriptionSettings()
                }
            }
        }
    }

    private var rewriteTemplateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingLabel(title: "Template", helpText: rewriteTemplateHelpText)

            TextEditor(text: $form.rewritePromptTemplate)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 160)
                .padding(8)
                .background(.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Template")
                .onChange(of: form.rewritePromptTemplate) {
                    scheduleRewriteTemplateValidation()
                }

            Text("Placeholders: {{instructions}}, {{target_app}}, {{common_terms}}, {{#instructions}}...{{/instructions}}, {{#target_app}}...{{/target_app}}, {{#common_terms}}...{{/common_terms}}")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if shouldShowCommonTermsTemplateWarning {
                Text("This custom template does not include {{common_terms}}, so Common terms will be ignored.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = form.rewritePromptTemplateValidationError {
                Text(error)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Template is valid.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Reset template") {
                    resetRewritePromptTemplate()
                }
                .font(.system(.caption, design: .rounded))
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingLabel(title: "Instructions", helpText: instructionsHelpText)
            TextEditor(text: $form.llmPostProcessingPrompt)
                .font(.system(.body, design: .rounded))
                .scrollContentBackground(.hidden)
                .frame(height: 80)
                .padding(8)
                .background(.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Instructions")
        }
        .onChange(of: form.llmPostProcessingPrompt) {
            AppBehaviorSettings.setGlobalLLMPostProcessingPrompt(form.llmPostProcessingPrompt, settings: settings)
            onSave?()
        }
    }

    private var commonTermsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingLabel(title: "Common terms", helpText: commonTermsHelpText)
            TextEditor(text: $form.globalCommonTerms)
                .font(.system(.body, design: .rounded))
                .scrollContentBackground(.hidden)
                .frame(height: 100)
                .padding(8)
                .background(.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Common terms")
        }
        .onChange(of: form.globalCommonTerms) {
            AppBehaviorSettings.setGlobalCommonTerms(form.globalCommonTerms, settings: settings)
            onSave?()
        }
    }

    private var llmPostProcessingEnabledBinding: Binding<Bool> {
        Binding {
            form.transcriptPostProcessingMode == .llm
        } set: { isEnabled in
            form.transcriptPostProcessingMode = isEnabled ? .llm : .off
        }
    }

    private var shouldShowCommonTermsTemplateWarning: Bool {
        let normalizedCurrentTemplate = form.rewritePromptTemplate.replacingOccurrences(of: "\r\n", with: "\n")
        let normalizedDefaultTemplate = TranscriptRewritePrompt.defaultTemplate().replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )
        let isCustomTemplate = normalizedCurrentTemplate != normalizedDefaultTemplate
            || TranscriptRewritePrompt.customTemplate(settings: settings) != nil

        guard isCustomTemplate else { return false }
        return !TranscriptRewritePrompt.templateIncludesCommonTermsPlaceholder(form.rewritePromptTemplate)
    }

    private func scheduleRewriteTemplateValidation() {
        form.rewriteTemplateValidationTask?.cancel()
        form.rewriteTemplateValidationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            validateAndPersistRewriteTemplate()
        }
    }

    private func validateAndPersistRewriteTemplate() {
        form.rewritePromptTemplateValidationError = TranscriptRewritePrompt.validateTemplate(form.rewritePromptTemplate)

        guard form.rewritePromptTemplateValidationError == nil else { return }

        TranscriptRewritePrompt.setCustomTemplate(form.rewritePromptTemplate, settings: settings)
        onSave?()
    }

    private func resetRewritePromptTemplate() {
        form.rewriteTemplateValidationTask?.cancel()
        form.rewritePromptTemplate = TranscriptRewritePrompt.defaultTemplate()
        form.rewritePromptTemplateValidationError = nil
        TranscriptRewritePrompt.setCustomTemplate(nil, settings: settings)
        onSave?()
    }

    private func saveTranscriptionSettings() {
        settings.asrProvider = form.asrProvider
        settings.serverEndpoint = form.serverEndpoint
        settings.customServerPassword = form.serverPassword
        settings.localLLMContextSize = form.localLLMContextSize
        appState.asrProvider = form.asrProvider
        onSave?()
    }
}
