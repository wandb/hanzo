import Foundation

enum PreferredTextInsertionMethod: String, Equatable {
    case pasteboard
    case accessibilityValueReplacement
}

struct TextInsertionPolicy: Equatable {
    let preferredMethod: PreferredTextInsertionMethod
    let allowsPermissivePasteFallback: Bool
    let placeholderSentinels: Set<String>

    static let defaultPolicy = TextInsertionPolicy(
        preferredMethod: .pasteboard,
        allowsPermissivePasteFallback: false,
        placeholderSentinels: []
    )

    private static let appOverrides: [String: TextInsertionPolicy] = [
        "com.anthropic.claudefordesktop": TextInsertionPolicy(
            preferredMethod: .accessibilityValueReplacement,
            allowsPermissivePasteFallback: true,
            placeholderSentinels: ["Reply...", "Reply…"]
        ),
        "dev.warp.Warp-Stable": TextInsertionPolicy(
            preferredMethod: .pasteboard,
            allowsPermissivePasteFallback: true,
            placeholderSentinels: []
        )
    ]

    static func resolved(for bundleIdentifier: String?) -> TextInsertionPolicy {
        guard let bundleIdentifier else { return defaultPolicy }
        return appOverrides[bundleIdentifier] ?? defaultPolicy
    }
}
