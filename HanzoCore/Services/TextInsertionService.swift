import AppKit
import CoreGraphics
import ApplicationServices

final class TextInsertionService: TextInsertionProtocol {
    private let logger = LoggingService.shared

    func insertText(_ text: String) async -> TextInsertionResult {
        guard !text.isEmpty else { return .inserted }
        guard AXIsProcessTrusted() else {
            logger.warn("Text insertion failed: accessibility permission missing")
            return .failed(.accessibilityPermissionMissing)
        }
        guard let focusedElement = focusedElement() else {
            logger.warn("Text insertion failed: no focused accessibility element")
            return .failed(.noFocusedElement)
        }
        guard isEditable(element: focusedElement) else {
            logger.warn("Text insertion failed: focused element is not editable")
            return .failed(.focusedElementNotEditable)
        }

        let pasteboard = NSPasteboard.general
        let savedContents = savePasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure pasteboard is ready.
        try? await Task.sleep(for: Constants.textInsertionPasteboardReadyDelay)

        guard simulatePaste() else {
            restorePasteboard(pasteboard, contents: savedContents)
            logger.info("Clipboard restored after failed text insertion attempt")
            return .failed(.pasteEventCreationFailed)
        }

        // Allow target apps time to consume Cmd+V before submit keystrokes.
        try? await Task.sleep(for: Constants.textInsertionSettleDelay)
        restorePasteboard(pasteboard, contents: savedContents)
        logger.info("Clipboard restored after text insertion")

        logger.info("Text inserted (\(text.count) chars)")
        return .inserted
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Text copied to clipboard (\(text.count) chars)")
    }

    func simulateReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key code 36 = Return key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
            logger.error("Failed to create CGEvent for Return key")
            return
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        logger.info("Simulated Return key press")
    }

    func simulateCmdReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key code 36 = Return key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
            logger.error("Failed to create CGEvent for Cmd+Return")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        logger.info("Simulated Cmd+Return key press")
    }

    // MARK: - Private

    private func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key code 9 = V key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            logger.error("Failed to create CGEvent for paste")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )

        guard result == .success, let focusedElementValue else { return nil }
        guard CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focusedElementValue, to: AXUIElement.self)
    }

    private func isEditable(element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )
        return result == .success && isSettable.boolValue
    }

    private func savePasteboard(_ pb: NSPasteboard) -> [NSPasteboard.PasteboardType: Data] {
        var saved: [NSPasteboard.PasteboardType: Data] = [:]
        for item in pb.pasteboardItems ?? [] {
            for type in item.types {
                if let data = item.data(forType: type) {
                    saved[type] = data
                }
            }
        }
        return saved
    }

    private func restorePasteboard(_ pb: NSPasteboard, contents: [NSPasteboard.PasteboardType: Data]) {
        pb.clearContents()
        guard !contents.isEmpty else { return }
        let item = NSPasteboardItem()
        for (type, data) in contents {
            item.setData(data, forType: type)
        }
        pb.writeObjects([item])
    }
}
