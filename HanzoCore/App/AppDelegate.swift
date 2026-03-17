import AppKit
import SwiftUI
import ServiceManagement

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var transcriptPanel: NSPanel?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var stateObservationTask: Task<Void, Never>?
    private var stateObservationTimer: Timer?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    let appState = AppState()
    private lazy var orchestrator = DictationOrchestrator(appState: appState)
    private let hotkeyService = HotkeyService()
    private let logger = LoggingService.shared

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateMenuBarIcon()

        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        // Setup transcript panel
        transcriptPanel = makeTranscriptPanel()

        // Register hotkey
        hotkeyService.onToggle = { [weak self] in
            self?.orchestrator.toggle()
        }
        hotkeyService.register()

        // Monitor app deactivation to cancel recording
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Monitor escape key (local for when app is active, global for non-activating panel)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                if self?.appState.dictationState == .listening {
                    self?.orchestrator.cancel()
                    return nil
                }
            }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                if self?.appState.dictationState == .listening {
                    self?.orchestrator.cancel()
                }
            }
        }

        // Observe state changes for icon and popover updates
        startStateObservation()

        // Ensure prewarm starts at app launch instead of first dictation toggle.
        _ = orchestrator

        // Show onboarding if not completed, or if permissions were revoked
        let permissions = PermissionService.shared
        let permissionsRevoked = !permissions.hasMicrophonePermission || !permissions.hasAccessibilityPermission
        let requiresModelPreparation = !hasRequiredLocalModelsForCurrentSettings()
        if !appState.isOnboardingComplete || permissionsRevoked || requiresModelPreparation {
            showOnboarding()
        } else {
            registerLaunchAtLoginIfNeeded()
        }

        logger.info("Hanzo launched")
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        orchestrator.shutdown()
        stateObservationTask?.cancel()
        stateObservationTimer?.invalidate()
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        hotkeyService.unregister()
        logger.info("Hanzo terminated")
    }

    // MARK: - Status Item

    func updateMenuBarIcon() {
        statusItem?.button?.image = MenuBarIcon.radialWaveform()
        statusItem?.button?.alphaValue = appState.dictationState == .idle ? 0.35 : 1.0
    }

    @objc private func statusItemClicked() {
        if appState.dictationState == .listening || appState.dictationState == .forging {
            togglePanel()
        } else {
            showMenu()
        }
    }

    // MARK: - Transcript Panel

    private func makeTranscriptPanel() -> TranscriptPanel {
        let panel = TranscriptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hostingController = NSHostingController(
            rootView: TranscriptPopover(
                appState: appState,
                onSettingsChanged: { [weak self] in
                    self?.orchestrator.reloadSettings()
                }
            )
        )
        panel.contentViewController = hostingController
        return panel
    }

    private func togglePanel() {
        guard let panel = transcriptPanel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel = transcriptPanel, !panel.isVisible else { return }
        guard let screen = NSScreen.main else { return }
        panel.setContentSize(NSSize(width: 480, height: 60))
        // Position horizontally centered, ~5% from the bottom of the screen
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - 240
        let y = screenFrame.origin.y + screenFrame.height * 0.05
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        transcriptPanel?.orderOut(nil)
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()

        let statusText: String
        switch appState.dictationState {
        case .idle: statusText = "Ready"
        case .listening: statusText = "Listening..."
        case .forging: statusText = "Forging..."
        case .error: statusText = appState.errorMessage ?? "Error"
        }

        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings...",
                     action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit Hanzo",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        self.statusItem.menu = menu
        self.statusItem.button?.performClick(nil)
        self.statusItem.menu = nil
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(
            appState: appState,
            onSave: { [weak self] in
                self?.orchestrator.reloadSettings()
            },
            onHotkeyChanged: { [weak self] in
                self?.hotkeyService.reregister()
            },
            onClose: { [weak self] in
                self?.settingsWindow?.close()
                self?.settingsWindow = nil
            }
        )
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 680, height: 520))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    // MARK: - App Monitoring

    @objc private func activeAppChanged(_ notification: Notification) {
        guard appState.dictationState == .listening else { return }

        // If another app became active while we're recording, cancel
        guard let activeApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if activeApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            logger.info("App switched during recording — cancelling")
            orchestrator.cancel()
        }
    }

    // MARK: - State Observation

    private func startStateObservation() {
        // Poll state changes to update icon and panel visibility
        // Using a timer since @Observable observation from NSObject is complex
        stateObservationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateMenuBarIcon()

            let panelVisible = self.transcriptPanel?.isVisible ?? false
            if self.appState.isPopoverPresented && !panelVisible {
                self.showPanel()
            } else if !self.appState.isPopoverPresented && panelVisible {
                self.hidePanel()
            }
        }
    }

    // MARK: - Launch at Login

    private func registerLaunchAtLoginIfNeeded() {
        let status = SMAppService.mainApp.status

        // If the user re-enabled in System Settings after opting out, clear the stale flag
        if status == .enabled,
           UserDefaults.standard.bool(forKey: Constants.launchAtLoginDisabledByUserKey) {
            UserDefaults.standard.set(false, forKey: Constants.launchAtLoginDisabledByUserKey)
        }

        guard !UserDefaults.standard.bool(forKey: Constants.launchAtLoginDisabledByUserKey) else { return }

        if status != .enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                logger.error("Failed to register launch at login: \(error)")
            }
        }
    }

    // MARK: - Onboarding

    private func hasRequiredLocalModelsForCurrentSettings() -> Bool {
        let provider: ASRProvider = {
            if let raw = UserDefaults.standard.string(forKey: Constants.asrProviderKey),
               let parsed = ASRProvider(rawValue: raw) {
                return parsed
            }
            return Constants.defaultASRProvider
        }()

        let needsWhisper = provider == .local
        let needsLLM = AppBehaviorSettings.globalPostProcessingMode() == .llm

        if needsWhisper && !hasLocalWhisperModel() {
            return false
        }

        if needsLLM && !hasLocalLLMModel() {
            return false
        }

        return true
    }

    private func hasLocalWhisperModel() -> Bool {
        let fileManager = FileManager.default
        let root = LocalModelPaths.modelsRoot(fileManager: fileManager)
        let maxDepth = 6
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var queueIndex = 0

        while queueIndex < queue.count {
            let (url, depth) = queue[queueIndex]
            queueIndex += 1

            let encoderDirectory = url.appendingPathComponent("AudioEncoder.mlmodelc")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: encoderDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return true
            }

            guard depth < maxDepth else {
                continue
            }

            guard let children = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for child in children {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else {
                    continue
                }
                queue.append((child, depth + 1))
            }
        }

        return false
    }

    private func hasLocalLLMModel() -> Bool {
        let modelFile = LocalModelPaths.llmModelFile()
        return FileManager.default.fileExists(atPath: modelFile.path)
    }

    private func showOnboarding() {
        let onboardingView = OnboardingContainerView(
            appState: appState,
            onComplete: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.appState.isOnboardingComplete = true
                self?.registerLaunchAtLoginIfNeeded()
            }
        )
        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 480, height: 380))
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.onboardingWindow = window
    }
}
