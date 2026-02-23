import SwiftUI
import Carbon

struct SettingsView: View {
    var onSave: (() -> Void)?
    var onHotkeyChanged: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var serverEndpoint: String = UserDefaults.standard.string(forKey: Constants.serverEndpointKey) ?? Constants.defaultServerEndpoint
    @State private var apiKey: String = UserDefaults.standard.string(forKey: Constants.apiKeyKey) ?? ""
    @State private var hotkeyCode: UInt32 = {
        let val = UserDefaults.standard.integer(forKey: Constants.hotkeyCodeKey)
        return val != 0 ? UInt32(val) : Constants.defaultHotkeyCode
    }()
    @State private var hotkeyModifiers: UInt32 = {
        let val = UserDefaults.standard.integer(forKey: Constants.hotkeyModifiersKey)
        return val != 0 ? UInt32(val) : Constants.defaultHotkeyModifiers
    }()
    @State private var isRecordingHotkey = false
    @State private var silenceTimeout: Double = UserDefaults.standard.object(forKey: Constants.silenceTimeoutKey) != nil
        ? UserDefaults.standard.double(forKey: Constants.silenceTimeoutKey)
        : Constants.defaultSilenceTimeout
    @State private var autoSubmit: Bool = UserDefaults.standard.object(forKey: Constants.autoSubmitKey) != nil
        ? UserDefaults.standard.bool(forKey: Constants.autoSubmitKey)
        : Constants.defaultAutoSubmit
    @FocusState private var focusedField: Field?

    private enum Field { case endpoint, apiKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            // Server section
            VStack(alignment: .leading, spacing: 12) {
                Text("Server")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("ASR server endpoint", text: $serverEndpoint)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($focusedField, equals: .endpoint)
                    .onChange(of: serverEndpoint) { saveServer() }

                TextField("API key", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($focusedField, equals: .apiKey)
                    .onChange(of: apiKey) { saveServer() }
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
                            .background(.white.opacity(0.08))
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

            Divider()
                .padding(.vertical, 16)

            // Silence auto-close section
            VStack(alignment: .leading, spacing: 12) {
                Text("Silence Auto-Close")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("", selection: $silenceTimeout) {
                    Text("Off").tag(0.0)
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                    Text("3s").tag(3.0)
                    Text("5s").tag(5.0)
                }
                .pickerStyle(.segmented)
                .onChange(of: silenceTimeout) { saveSilenceTimeout() }

                Text("Auto-stop recording after a pause in speech.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.vertical, 16)

            // Auto-submit section
            VStack(alignment: .leading, spacing: 12) {
                Text("Auto-Submit")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)

                Toggle(isOn: $autoSubmit) {
                    Text("Press Return after pasting")
                        .font(.system(.body, design: .rounded))
                }
                .toggleStyle(.switch)
                .onChange(of: autoSubmit) { saveAutoSubmit() }

                Text("Automatically submit text in the active app after dictation.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 420, height: 500)
        .hudBackground()
        .background(isRecordingHotkey ? HotkeyRecorderView(onKeyCombo: { keyCode, modifiers in
            hotkeyCode = keyCode
            hotkeyModifiers = modifiers
            isRecordingHotkey = false
            saveHotkey()
        }) .frame(width: 0, height: 0) : nil)
    }

    private func saveServer() {
        UserDefaults.standard.set(serverEndpoint, forKey: Constants.serverEndpointKey)
        UserDefaults.standard.set(apiKey, forKey: Constants.apiKeyKey)
        onSave?()
    }

    private func saveHotkey() {
        UserDefaults.standard.set(Int(hotkeyCode), forKey: Constants.hotkeyCodeKey)
        UserDefaults.standard.set(Int(hotkeyModifiers), forKey: Constants.hotkeyModifiersKey)
        onHotkeyChanged?()
    }

    private func saveSilenceTimeout() {
        UserDefaults.standard.set(silenceTimeout, forKey: Constants.silenceTimeoutKey)
        onSave?()
    }

    private func saveAutoSubmit() {
        UserDefaults.standard.set(autoSubmit, forKey: Constants.autoSubmitKey)
        onSave?()
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
