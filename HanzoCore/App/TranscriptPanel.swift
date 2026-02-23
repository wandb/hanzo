import AppKit

// MARK: - Transcript Panel

/// Floating panel that pins its bottom edge when height changes (grows upward).
class TranscriptPanel: NSPanel {
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let pinned = pinBottom(for: frameRect)
        super.setFrame(pinned, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        let pinned = pinBottom(for: frameRect)
        super.setFrame(pinned, display: displayFlag, animate: animateFlag)
    }

    override func setContentSize(_ size: NSSize) {
        let pinned = pinBottom(for: NSRect(origin: frame.origin, size: size))
        super.setFrame(pinned, display: true)
    }

    private func pinBottom(for newRect: NSRect) -> NSRect {
        guard isVisible else { return newRect }
        // Keep the bottom edge fixed — the panel grows upward
        return NSRect(
            x: newRect.origin.x,
            y: frame.origin.y,
            width: newRect.size.width,
            height: newRect.size.height
        )
    }
}
