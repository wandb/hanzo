import AppKit
import CoreGraphics
import ApplicationServices

struct AXValueInsertionContext: Equatable {
    let currentValue: String
    let selectedRange: NSRange
}

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
        let targetProcessIdentifier = frontmostApplication.map { pid_t($0.processIdentifier) }
        let insertionPolicy = TextInsertionPolicy.resolved(for: frontmostBundleIdentifier)
        let focusedElement = resolvedFocusedElement(
            targetProcessIdentifier: targetProcessIdentifier,
            frontmostApplication: frontmostApplication
        )

        guard let focusedElement else {
            if insertionPolicy.allowsPermissivePasteFallback {
                logger.warn(
                    "No focused accessibility element for \(frontmostBundleIdentifier ?? "unknown app"); " +
                        "attempting permissive paste fallback"
                )
                return await pasteViaClipboard(text, targetProcessIdentifier: targetProcessIdentifier)
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
                return await pasteViaClipboard(text, targetProcessIdentifier: targetProcessIdentifier)
            }

            logger.warn("Text insertion failed: focused element is not editable")
            return .failed(.focusedElementNotEditable)
        }

        if insertionPolicy.preferredMethod == .accessibilityValueReplacement,
           insertTextViaAXValue(text, into: focusedElement, policy: insertionPolicy) {
            logger.info("Text inserted via accessibility value replacement (\(text.count) chars)")
            return .inserted
        }

        return await pasteViaClipboard(text, targetProcessIdentifier: targetProcessIdentifier)
    }

    private func pasteViaClipboard(_ text: String, targetProcessIdentifier: pid_t?) async -> TextInsertionResult {
        guard !text.isEmpty else { return .inserted }

        let pasteboard = NSPasteboard.general
        let savedContents = savePasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure pasteboard is ready.
        try? await Task.sleep(for: Constants.textInsertionPasteboardReadyDelay)

        guard simulatePaste(targetProcessIdentifier: targetProcessIdentifier) else {
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

    private func simulatePaste(targetProcessIdentifier: pid_t?) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key code 9 = V key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            logger.error("Failed to create CGEvent for paste")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        postKeyEvents(keyDown: keyDown, keyUp: keyUp, targetProcessIdentifier: targetProcessIdentifier)
        return true
    }

    private func postKeyEvents(
        keyDown: CGEvent,
        keyUp: CGEvent,
        targetProcessIdentifier: pid_t? = nil
    ) {
        if let pid = targetProcessIdentifier {
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
            return
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
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

    private func resolvedFocusedElement(
        targetProcessIdentifier: pid_t?,
        frontmostApplication: NSRunningApplication?
    ) -> AXUIElement? {
        guard let systemWideFocusedElement = focusedElement() else {
            return focusedElementForFrontmostApplication(frontmostApplication)
        }

        guard let targetProcessIdentifier else {
            return systemWideFocusedElement
        }

        guard processIdentifier(for: systemWideFocusedElement) == targetProcessIdentifier else {
            logger.warn("System-wide focused element PID mismatched frontmost app; retrying app-scoped lookup")
            return focusedElementForFrontmostApplication(frontmostApplication)
        }

        return systemWideFocusedElement
    }

    private func processIdentifier(for element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        let result = AXUIElementGetPid(element, &processIdentifier)
        guard result == .success else { return nil }
        return processIdentifier
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

    private func insertTextViaAXValue(
        _ text: String,
        into element: AXUIElement,
        policy: TextInsertionPolicy
    ) -> Bool {
        guard isAttributeSettable(element: element, attribute: kAXValueAttribute as CFString),
              let currentValue = stringAttribute(element: element, attribute: kAXValueAttribute as CFString),
              let selectedRange = selectedTextRange(element: element) else {
            return false
        }

        let placeholderValue = stringAttribute(element: element, attribute: kAXPlaceholderValueAttribute as CFString)
        let numberOfCharacters = integerAttribute(element: element, attribute: kAXNumberOfCharactersAttribute as CFString)
        let insertionContext = Self.normalizedAXValueInsertionContext(
            currentValue: currentValue,
            selectedRange: selectedRange,
            placeholderValue: placeholderValue,
            numberOfCharacters: numberOfCharacters,
            placeholderSentinels: policy.placeholderSentinels
        )

        if insertionContext.currentValue.isEmpty,
           !currentValue.isEmpty,
           placeholderValue == currentValue {
            logger.info("Treating placeholder accessibility value as empty before replacement")
        }

        let currentNSString = insertionContext.currentValue as NSString
        let replacementLocation = insertionContext.selectedRange.location
        let replacementLength = insertionContext.selectedRange.length
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

    static func normalizedAXValueInsertionContext(
        currentValue: String,
        selectedRange: CFRange,
        placeholderValue: String?,
        numberOfCharacters: Int?,
        placeholderSentinels: Set<String>
    ) -> AXValueInsertionContext {
        let sanitizedRange = NSRange(
            location: max(0, selectedRange.location),
            length: max(0, selectedRange.length)
        )

        guard shouldTreatPlaceholderAsEmpty(
            currentValue: currentValue,
            placeholderValue: placeholderValue,
            numberOfCharacters: numberOfCharacters,
            placeholderSentinels: placeholderSentinels
        ) else {
            return AXValueInsertionContext(
                currentValue: currentValue,
                selectedRange: sanitizedRange
            )
        }

        return AXValueInsertionContext(
            currentValue: "",
            selectedRange: NSRange(location: 0, length: 0)
        )
    }

    private static func shouldTreatPlaceholderAsEmpty(
        currentValue: String,
        placeholderValue: String?,
        numberOfCharacters: Int?,
        placeholderSentinels: Set<String>
    ) -> Bool {
        let normalizedCurrentValue = normalizedPlaceholderCandidate(currentValue)

        if let placeholderValue,
           normalizedCurrentValue == normalizedPlaceholderCandidate(placeholderValue) {
            return placeholderCharacterCountLooksEmpty(
                numberOfCharacters,
                placeholderLength: currentValue.count
            )
        }

        guard !placeholderSentinels.isEmpty else {
            return false
        }

        let currentIsSentinel = placeholderSentinels.contains {
            normalizedCurrentValue == normalizedPlaceholderCandidate($0)
        }
        guard currentIsSentinel else {
            return false
        }

        guard let numberOfCharacters else {
            return true
        }
        return placeholderCharacterCountLooksEmpty(
            numberOfCharacters,
            placeholderLength: currentValue.count
        )
    }

    private static func placeholderCharacterCountLooksEmpty(
        _ numberOfCharacters: Int?,
        placeholderLength: Int
    ) -> Bool {
        guard let numberOfCharacters else {
            return true
        }
        return numberOfCharacters == 0 || numberOfCharacters == placeholderLength
    }

    private static func normalizedPlaceholderCandidate(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .lowercased()
    }

    private func stringAttribute(element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as? String)
    }

    private func integerAttribute(element: AXUIElement, attribute: CFString) -> Int? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }

        var number: Int = 0
        guard CFNumberGetValue(
            unsafeBitCast(value, to: CFNumber.self),
            .intType,
            &number
        ) else {
            return nil
        }

        return number
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
