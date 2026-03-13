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
    @State private var verbalPauseFilterEnabled: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Constants.verbalPauseFilterEnabledKey) != nil {
            return defaults.bool(forKey: Constants.verbalPauseFilterEnabledKey)
        }
        return Constants.defaultVerbalPauseFilterEnabled
    }()
    @State private var appBehaviorOverrides: [String: AppBehaviorOverride] = AppBehaviorSettings.loadOverrides()
    @State private var supportedApps: [SupportedAppBehavior] = AppBehaviorSettings.supportedApps
    @State private var isDetectingApp = false
    @State private var detectCountdown: Int?
    @State private var detectCurrentAppTask: Task<Void, Never>?

    @State private var isRecordingHotkey = false
    @FocusState private var focusedField: Field?
    private let silenceTimeoutOptions: [Double] = [0, 1, 2, 3, 5]

    private enum Field { case endpoint, serverPassword }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Close button
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
                .padding(.bottom, 8)

                // General section
                VStack(alignment: .leading, spacing: 12) {
                    Text("General")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)

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

                        Spacer()

                        Button(isRecordingHotkey ? "Cancel" : "Change") {
                            isRecordingHotkey.toggle()
                        }
                        .font(.system(.body, design: .rounded))
                        .buttonStyle(.borderless)
                    }

                }

                Divider()
                    .padding(.vertical, 16)

                // Transcription section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcription")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)

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
                        .frame(width: 300)
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

                    HStack {
                        Text("Filter verbal pauses")
                            .font(.system(.body, design: .rounded))
                        Spacer()
                        Toggle("", isOn: $verbalPauseFilterEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .accessibilityLabel("Filter verbal pauses")
                    }
                    .onChange(of: verbalPauseFilterEnabled) {
                        UserDefaults.standard.set(
                            verbalPauseFilterEnabled,
                            forKey: Constants.verbalPauseFilterEnabledKey
                        )
                        onSave?()
                    }
                }

                Divider()
                    .padding(.vertical, 16)

                // App-specific behavior section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Auto Submit and Silence Timer")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("App")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Silence timeout")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .trailing)
                        Text("Auto-submit")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .trailing)
                    }

                    HStack {
                        Text("Default")
                            .font(.system(.body, design: .rounded, weight: .medium))
                        Spacer()

                        Picker("", selection: $globalSilenceTimeout) {
                            ForEach(silenceTimeoutOptions, id: \.self) { timeout in
                                Text(silenceTimeoutLabel(timeout)).tag(timeout)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150, alignment: .trailing)

                        Picker("", selection: $globalAutoSubmitMode) {
                            ForEach(AutoSubmitMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150, alignment: .trailing)
                    }
                    .onChange(of: globalAutoSubmitMode) {
                        AppBehaviorSettings.setGlobalAutoSubmitMode(globalAutoSubmitMode)
                        if appState.activeTargetBundleIdentifier == nil {
                            appState.autoSubmitMode = globalAutoSubmitMode
                        }
                        onSave?()
                    }
                    .onChange(of: globalSilenceTimeout) {
                        AppBehaviorSettings.setGlobalSilenceTimeout(globalSilenceTimeout)
                        if appState.activeTargetBundleIdentifier == nil {
                            appState.silenceTimeout = globalSilenceTimeout
                        }
                        onSave?()
                    }

                    ForEach(supportedApps) { app in
                        HStack {
                            Text(app.displayName)
                                .font(.system(.body, design: .rounded))
                            Spacer()

                            Picker("", selection: silenceTimeoutBinding(for: app)) {
                                Text("Default").tag(nil as Double?)
                                ForEach(silenceTimeoutOptions, id: \.self) { timeout in
                                    Text(silenceTimeoutLabel(timeout)).tag(Optional(timeout))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 150, alignment: .trailing)

                            Picker("", selection: autoSubmitBinding(for: app)) {
                                Text("Default").tag(nil as AutoSubmitMode?)
                                ForEach(AutoSubmitMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(Optional(mode))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 150, alignment: .trailing)

                            if !app.isBuiltIn {
                                Button {
                                    removeCustomApp(app)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove custom app")
                            }
                        }
                    }

                    Divider()
                        .padding(.vertical, 8)

                    Text("Click Add New App, then switch to the app you want to add before the countdown ends.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button(detectButtonTitle) {
                            detectCurrentApp()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDetectingApp)
                    }
                }

            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 540, height: 640)
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

    private func silenceTimeoutLabel(_ timeout: Double) -> String {
        if timeout == 0 {
            return "Off"
        }

        if timeout.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(timeout))s"
        }

        return "\(timeout)s"
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
