import AppKit
import CoreGraphics

final class TextInsertionService: TextInsertionProtocol {
    private let logger = LoggingService.shared

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let savedContents = savePasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure pasteboard is ready
        usleep(50_000) // 50ms

        simulatePaste()

        // Restore clipboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            restorePasteboard(pasteboard, contents: savedContents)
            logger.info("Clipboard restored after text insertion")
        }

        logger.info("Text inserted (\(text.count) chars)")
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Text copied to clipboard (\(text.count) chars)")
    }

    // MARK: - Private

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key code 9 = V key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            logger.error("Failed to create CGEvent for paste")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
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
