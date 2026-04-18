import SwiftUI
import Carbon
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    var appState: AppState
    let settings: AppSettingsProtocol
    var onSave: (() -> Void)?
    var onHotkeyChanged: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var form: SettingsFormState
    @State private var selectedSection: SettingsSection = .general

    private let silenceTimeoutOptions: [Double] = [0, 1, 2, 3, 5]
    private let segmentedInputWidth: CGFloat = 220
    private let menuInputWidth: CGFloat = 180

    enum SettingsSection: Hashable {
        case general
        case transcription
        case app(String) // bundleIdentifier
    }

    init(
        appState: AppState,
        settings: AppSettingsProtocol = AppSettings.live,
        onSave: (() -> Void)? = nil,
        onHotkeyChanged: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.appState = appState
        self.settings = settings
        self.onSave = onSave
        self.onHotkeyChanged = onHotkeyChanged
        self.onClose = onClose
        _form = State(initialValue: SettingsFormState(settings: settings))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(width: 680, height: 520)
        .hudBackground(colorScheme: appState.preferredColorScheme)
        .background(form.isRecordingHotkey ? HotkeyRecorderView(onKeyCombo: { keyCode, modifiers in
            form.hotkeyCode = keyCode
            form.hotkeyModifiers = modifiers
            form.isRecordingHotkey = false
            saveHotkey()
        }).frame(width: 0, height: 0) : nil)
        .onAppear {
            refreshUsageStats()
        }
        .onChange(of: selectedSection) {
            if selectedSection == .general {
                refreshUsageStats()
            }
        }
        .onDisappear {
            form.rewriteTemplateValidationTask?.cancel()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
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
                    ForEach(form.supportedApps) { app in
                        appSidebarButton(for: app)
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)
                .padding(.horizontal, 12)

            Button {
                presentAppPickerForCustomBehavior()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("Add New App")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
        }
        .frame(width: 160)
        .padding(.top, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedSection {
                    case .general:
                        GeneralPaneView(
                            form: form,
                            appState: appState,
                            settings: settings,
                            menuInputWidth: menuInputWidth
                        )
                    case .transcription:
                        TranscriptionPaneView(
                            form: form,
                            appState: appState,
                            settings: settings,
                            silenceTimeoutOptions: silenceTimeoutOptions,
                            segmentedInputWidth: segmentedInputWidth,
                            menuInputWidth: menuInputWidth,
                            onSave: onSave
                        )
                    case .app(let bundleIdentifier):
                        if let app = form.supportedApps.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                            AppBehaviorPaneView(
                                app: app,
                                form: form,
                                settings: settings,
                                silenceTimeoutOptions: silenceTimeoutOptions,
                                menuInputWidth: menuInputWidth,
                                onSave: onSave,
                                onRemoved: { selectedSection = .general }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

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

    // MARK: - Actions

    private func saveHotkey() {
        settings.hotkeyCode = form.hotkeyCode
        settings.hotkeyModifiers = form.hotkeyModifiers
        onHotkeyChanged?()
    }

    private func refreshUsageStats() {
        form.usageStats = UsageStatsStore.current()
    }

    @MainActor
    private func presentAppPickerForCustomBehavior() {
        let panel = NSOpenPanel()
        panel.title = "Add App"
        panel.message = "Choose an app to configure custom Hanzo behavior."
        panel.prompt = "Add App"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.resolvesAliases = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let appURL = panel.url else { return }
                addCustomAppFromSelection(at: appURL)
            }
            return
        }

        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        addCustomAppFromSelection(at: appURL)
    }

    @MainActor
    private func addCustomAppFromSelection(at appURL: URL) {
        guard appURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: appURL),
              let bundleIdentifier = bundle.bundleIdentifier else {
            LoggingService.shared.warn("Unable to add app from selection: \(appURL.path)")
            return
        }

        if bundleIdentifier == Bundle.main.bundleIdentifier {
            LoggingService.shared.warn("Ignoring request to add Hanzo itself as a custom app: \(bundleIdentifier)")
            return
        }

        let displayNameCandidates = [
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        ]
        let appName = displayNameCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? appURL.deletingPathExtension().lastPathComponent

        let result = AppBehaviorSettings.addCustomApp(
            bundleIdentifier: bundleIdentifier,
            displayName: appName,
            settings: settings
        )
        form.supportedApps = AppBehaviorSettings.supportedApps(settings: settings)

        switch result {
        case .added, .updated:
            selectedSection = .app(bundleIdentifier)
            onSave?()
        case .alreadyExists:
            selectedSection = .app(bundleIdentifier)
        case .invalidBundleIdentifier:
            LoggingService.shared.warn("AppBehaviorSettings rejected invalid bundle identifier from selection: \(appURL.path)")
            break
        }
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
