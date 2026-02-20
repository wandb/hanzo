import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var onboardingWindow: NSWindow?
    private var stateObservationTask: Task<Void, Never>?

    let appState = AppState()
    private lazy var orchestrator = DictationOrchestrator(appState: appState)
    private let hotkeyService = HotkeyService()
    private let logger = LoggingService.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateMenuBarIcon()

        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        // Setup popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 120)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: TranscriptPopover(appState: appState)
        )

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

        // Monitor escape key
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                if self?.appState.dictationState == .listening {
                    self?.orchestrator.cancel()
                    return nil
                }
            }
            return event
        }

        // Observe state changes for icon and popover updates
        startStateObservation()

        // Show onboarding if needed
        if !appState.isOnboardingComplete {
            showOnboarding()
        }

        logger.info("Hanzo launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateObservationTask?.cancel()
        hotkeyService.unregister()
        logger.info("Hanzo terminated")
    }

    // MARK: - Status Item

    func updateMenuBarIcon() {
        statusItem?.button?.image = NSImage(
            systemSymbolName: appState.menuBarIconName,
            accessibilityDescription: "Hanzo"
        )
    }

    @objc private func statusItemClicked() {
        if appState.dictationState == .listening || appState.dictationState == .forging {
            togglePopover()
        } else {
            showMenu()
        }
    }

    // MARK: - Popover

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make sure the popover's window becomes key so we receive key events
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func hidePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
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
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
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
        // Poll state changes to update icon and popover
        // Using a timer since @Observable observation from NSObject is complex
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateMenuBarIcon()

            if self.appState.isPopoverPresented && !self.popover.isShown {
                self.showPopover()
            } else if !self.appState.isPopoverPresented && self.popover.isShown {
                self.hidePopover()
            }
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let onboardingView = OnboardingContainerView(
            onComplete: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.appState.isOnboardingComplete = true
            }
        )
        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Hanzo"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 360))
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.onboardingWindow = window
    }
}
