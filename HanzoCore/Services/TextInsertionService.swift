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

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostBundleIdentifier = frontmostApplication?.bundleIdentifier
        let insertionPolicy = TextInsertionPolicy.resolved(for: frontmostBundleIdentifier)
        let focusedElement = focusedElement()
            ?? focusedElementForFrontmostApplication(frontmostApplication)

        guard let focusedElement else {
            if insertionPolicy.allowsPermissivePasteFallback {
                logger.warn(
                    "No focused accessibility element for \(frontmostBundleIdentifier ?? "unknown app"); " +
                        "attempting permissive paste fallback"
                )
                return await pasteViaClipboard(text)
            }

            logger.warn("Text insertion failed: no focused accessibility element")
            return .failed(.noFocusedElement)
        }

        guard isEditable(element: focusedElement) else {
            if insertionPolicy.allowsPermissivePasteFallback {
                logger.warn(
                    "Focused element not editable for \(frontmostBundleIdentifier ?? "unknown app"); " +
                        "attempting permissive paste fallback"
                )
                return await pasteViaClipboard(text)
            }

            logger.warn("Text insertion failed: focused element is not editable")
            return .failed(.focusedElementNotEditable)
        }

        if insertionPolicy.preferredMethod == .accessibilityValueReplacement,
           insertTextViaAXValue(text, into: focusedElement) {
            logger.info("Text inserted via accessibility value replacement (\(text.count) chars)")
            return .inserted
        }

        return await pasteViaClipboard(text)
    }

    private func pasteViaClipboard(_ text: String) async -> TextInsertionResult {
        guard !text.isEmpty else { return .inserted }

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

        postKeyEvents(keyDown: keyDown, keyUp: keyUp)
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

        postKeyEvents(keyDown: keyDown, keyUp: keyUp)
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

        postKeyEvents(keyDown: keyDown, keyUp: keyUp)
        return true
    }

    private func postKeyEvents(keyDown: CGEvent, keyUp: CGEvent) {
        if let pid = frontmostProcessIdentifier() {
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
            return
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func frontmostProcessIdentifier() -> pid_t? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return pid_t(frontmostApplication.processIdentifier)
    }

    private func focusedElementForFrontmostApplication(_ app: NSRunningApplication?) -> AXUIElement? {
        guard let app else { return nil }
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElementValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )

        guard result == .success, let focusedElementValue else { return nil }
        guard CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focusedElementValue, to: AXUIElement.self)
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
        // AppKit fields usually expose AXValue as settable; web/electron editors
        // often expose editability via text-range or editable-ancestor attributes.
        if isAttributeSettable(element: element, attribute: kAXValueAttribute as CFString) {
            return true
        }
        if isAttributeSettable(element: element, attribute: kAXSelectedTextRangeAttribute as CFString) {
            return true
        }
        if hasAXUIElementAttribute(element: element, attribute: "AXEditableAncestor" as CFString) {
            return true
        }
        if hasAXUIElementAttribute(element: element, attribute: "AXHighestEditableAncestor" as CFString) {
            return true
        }
        return false
    }

    private func isAttributeSettable(element: AXUIElement, attribute: CFString) -> Bool {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return result == .success && isSettable.boolValue
    }

    private func hasAXUIElementAttribute(element: AXUIElement, attribute: CFString) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return false }
        return CFGetTypeID(value) == AXUIElementGetTypeID()
    }

    private func insertTextViaAXValue(_ text: String, into element: AXUIElement) -> Bool {
        guard isAttributeSettable(element: element, attribute: kAXValueAttribute as CFString),
              let currentValue = stringAttribute(element: element, attribute: kAXValueAttribute as CFString),
              let selectedRange = selectedTextRange(element: element) else {
            return false
        }

        guard selectedRange.location >= 0, selectedRange.length >= 0 else {
            return false
        }

        let currentNSString = currentValue as NSString
        let replacementLocation = selectedRange.location
        let replacementLength = selectedRange.length
        guard replacementLocation <= currentNSString.length,
              replacementLocation + replacementLength <= currentNSString.length else {
            return false
        }

        let replacementRange = NSRange(location: replacementLocation, length: replacementLength)
        let updatedValue = currentNSString.replacingCharacters(in: replacementRange, with: text)
        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFString
        )
        guard setResult == .success else {
            return false
        }

        let caretLocation = replacementLocation + (text as NSString).length
        setSelectedTextRange(element: element, location: caretLocation, length: 0)
        return true
    }

    private func stringAttribute(element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as? String)
    }

    private func selectedTextRange(element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func setSelectedTextRange(element: AXUIElement, location: Int, length: Int) {
        var range = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        )
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
