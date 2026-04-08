import Foundation

enum PreferredTextInsertionMethod: String, Equatable {
    case pasteboard
    case accessibilityValueReplacement
}

struct TextInsertionPolicy: Equatable {
    let preferredMethod: PreferredTextInsertionMethod
    let allowsPermissivePasteFallback: Bool

    static let defaultPolicy = TextInsertionPolicy(
        preferredMethod: .pasteboard,
        allowsPermissivePasteFallback: false
    )

    private static let appOverrides: [String: TextInsertionPolicy] = [
        "com.anthropic.claudefordesktop": TextInsertionPolicy(
            preferredMethod: .accessibilityValueReplacement,
            allowsPermissivePasteFallback: true
        ),
        "dev.warp.Warp-Stable": TextInsertionPolicy(
            preferredMethod: .pasteboard,
            allowsPermissivePasteFallback: true
        )
    ]

    static func resolved(for bundleIdentifier: String?) -> TextInsertionPolicy {
        guard let bundleIdentifier else { return defaultPolicy }
        return appOverrides[bundleIdentifier] ?? defaultPolicy
    }
}
