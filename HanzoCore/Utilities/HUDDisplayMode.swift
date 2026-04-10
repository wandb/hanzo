import AppKit

enum HUDDisplayMode: String, CaseIterable {
    case full
    case standard
    case compact

    var displayName: String {
        switch self {
        case .full:
            return "Full"
        case .standard:
            return "Standard"
        case .compact:
            return "Compact"
        }
    }
}

enum HUDLayout {
    static let fullPanelWidth: CGFloat = 480
    static let standardPanelWidth: CGFloat = 200
    static let compactPanelWidth: CGFloat = 120
    static let fallbackMaxHeight: CGFloat = 760
    static let fullInitialPanelHeight: CGFloat = 60
    static let standardInitialPanelHeight: CGFloat = 114
    static let compactInitialPanelHeight: CGFloat = 94
    static let cornerRadius: CGFloat = 22

    static func maxHeight(for screen: NSScreen? = NSScreen.main) -> CGFloat {
        guard let screen else { return fallbackMaxHeight }
        return max(480, screen.visibleFrame.height * 0.9)
    }

    static func panelWidth(
        for displayMode: HUDDisplayMode,
        dictationState: DictationState,
        hasErrorMessage: Bool
    ) -> CGFloat {
        if dictationState == .error, hasErrorMessage {
            return fullPanelWidth
        }

        switch displayMode {
        case .full:
            return fullPanelWidth
        case .standard:
            return standardPanelWidth
        case .compact:
            return compactPanelWidth
        }
    }

    static func initialPanelSize(for displayMode: HUDDisplayMode) -> NSSize {
        switch displayMode {
        case .full:
            return NSSize(width: fullPanelWidth, height: fullInitialPanelHeight)
        case .standard:
            return NSSize(width: standardPanelWidth, height: standardInitialPanelHeight)
        case .compact:
            return NSSize(width: compactPanelWidth, height: compactInitialPanelHeight)
        }
    }
}
