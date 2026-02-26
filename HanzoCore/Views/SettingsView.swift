import SwiftUI
import Carbon
import ServiceManagement

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
    @State private var localServerEndpoint: String = UserDefaults.standard.string(forKey: Constants.localServerEndpointKey) ?? Constants.defaultLocalServerEndpoint
    @State private var localASRModelPreset: LocalASRModelPreset = {
        if let raw = UserDefaults.standard.string(forKey: Constants.localASRModelPresetKey) {
            return LocalASRModelPreset(rawValue: raw) ?? Constants.defaultLocalASRModelPreset
        }
        return Constants.defaultLocalASRModelPreset
    }()
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
    @State private var isRecordingHotkey = false
    @FocusState private var focusedField: Field?

    private enum Field { case endpoint, serverPassword }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: { onClose?() }) {
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

                Toggle("Open at startup", isOn: $launchAtLogin)
                    .font(.system(.body, design: .rounded))
                    .toggleStyle(.switch)
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
                } else if asrProvider == .local {
                    HStack {
                        Text("Model")
                            .font(.system(.body, design: .rounded))
                        Spacer()
                        Picker("", selection: $localASRModelPreset) {
                            ForEach(LocalASRModelPreset.allCases, id: \.rawValue) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: localASRModelPreset) { saveTranscriptionSettings() }
                    }
                } else {
                    Text("Hosted runs on Hanzo's managed ASR service. Credentials are managed by the app.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
                .padding(.vertical, 16)

            // Hotkey section
            VStack(alignment: .leading, spacing: 12) {
                Text("Hotkey")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack {
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

                Text("Press this combination anywhere to start/stop dictation.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

        }
        .padding(24)
        .frame(width: 420, height: 460)
        .hudBackground(colorScheme: appState.preferredColorScheme)
        .background(isRecordingHotkey ? HotkeyRecorderView(onKeyCombo: { keyCode, modifiers in
            hotkeyCode = keyCode
            hotkeyModifiers = modifiers
            isRecordingHotkey = false
            saveHotkey()
        }) .frame(width: 0, height: 0) : nil)
    }

    private func saveTranscriptionSettings() {
        UserDefaults.standard.set(asrProvider.rawValue, forKey: Constants.asrProviderKey)
        UserDefaults.standard.set(serverEndpoint, forKey: Constants.serverEndpointKey)
        UserDefaults.standard.set(serverPassword, forKey: Constants.customServerPasswordKey)
        UserDefaults.standard.set(localServerEndpoint, forKey: Constants.localServerEndpointKey)
        UserDefaults.standard.set(localASRModelPreset.rawValue, forKey: Constants.localASRModelPresetKey)
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
