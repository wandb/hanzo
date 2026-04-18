import SwiftUI
import ServiceManagement

struct GeneralPaneView: View {
    @Bindable var form: SettingsFormState
    var appState: AppState
    let settings: AppSettingsProtocol
    let menuInputWidth: CGFloat

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            usageStatsContent

            SettingsSectionHeader(
                title: "General",
                subtitle: "Control startup behavior, appearance, HUD presentation, and hotkey capture."
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hotkey")
                        .font(.system(.body, design: .rounded))
                    Spacer()

                    trailingControl {
                        Button {
                            form.isRecordingHotkey.toggle()
                        } label: {
                            if form.isRecordingHotkey {
                                Text("Press a key combo...")
                                    .font(.system(.body, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.blue.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                Text(HotkeyService.displayString(keyCode: form.hotkeyCode, modifiers: form.hotkeyModifiers))
                                    .font(.system(.body, design: .rounded, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.primary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(form.isRecordingHotkey ? "Cancel hotkey recording" : "Set hotkey")
                    }
                }

                Text("Tap to start or stop. Hold to dictate, then release to stop.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Style")
                    .font(.system(.body, design: .rounded))
                Spacer()
                trailingControl {
                    Picker("", selection: $form.hudDisplayMode) {
                        ForEach(HUDDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Style")
                }
            }
            .onChange(of: form.hudDisplayMode) {
                settings.hudDisplayMode = form.hudDisplayMode
                appState.hudDisplayMode = form.hudDisplayMode
            }

            HStack {
                Text("Appearance")
                    .font(.system(.body, design: .rounded))
                Spacer()
                trailingControl {
                    Picker("", selection: $form.appearanceMode) {
                        Text("System").tag(AppearanceMode.system)
                        Text("Light").tag(AppearanceMode.light)
                        Text("Dark").tag(AppearanceMode.dark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Appearance")
                }
            }
            .onChange(of: form.appearanceMode) {
                settings.appearanceMode = form.appearanceMode
                appState.appearanceMode = form.appearanceMode
            }

            HStack {
                Text("Open at startup")
                    .font(.system(.body, design: .rounded))
                Spacer()
                trailingControl {
                    Toggle("", isOn: $form.launchAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .accessibilityLabel("Open at startup")
                }
            }
            .onChange(of: form.launchAtLogin) {
                do {
                    if form.launchAtLogin {
                        try SMAppService.mainApp.register()
                        settings.launchAtLoginDisabledByUser = false
                    } else {
                        try SMAppService.mainApp.unregister()
                        settings.launchAtLoginDisabledByUser = true
                    }
                } catch {
                    LoggingService.shared.warn("Launch-at-login failed: \(error)")
                    form.launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

            Divider()

            Text("Version \(appVersion) | Build \(appBuild)")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ReleaseNotesSectionView(
                title: "What's New",
                subtitle: "Bundled release notes for this installed build.",
                changelog: ReleaseNotesProvider.loadChangelog(),
                entries: ReleaseNotesProvider.loadEntries()
            )
        }
    }

    // MARK: - Subviews

    private var usageStatsContent: some View {
        HStack(spacing: 10) {
            usageStatCard(value: form.usageStats.wordsAllTime.formatted(), label: "Words transcribed")
            usageStatCard(value: minutesDictatedDisplay, label: "Minutes dictated")
            usageStatCard(value: form.usageStats.averageWordsPerMinute.formatted(), label: "Words per min")
            usageStatCard(value: form.usageStats.autoSubmitsAllTime.formatted(), label: "Auto submits")
        }
    }

    private func usageStatCard(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text(label)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var minutesDictatedDisplay: String {
        let minutes = form.usageStats.minutesDictatedAllTime
        guard minutes > 0 else { return "0" }
        if minutes < 10 {
            return minutes.formatted(.number.precision(.fractionLength(1)))
        }
        return Int(minutes.rounded()).formatted()
    }

    private func trailingControl<Control: View>(@ViewBuilder _ control: () -> Control) -> some View {
        control().frame(width: menuInputWidth, alignment: .trailing)
    }
}
