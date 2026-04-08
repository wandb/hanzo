import Testing
@testable import HanzoCore

@Suite("TextInsertionPolicy")
struct TextInsertionPolicyTests {
    @Test("unknown apps use the default pasteboard-only policy")
    func unknownAppsUseDefaultPolicy() {
        let policy = TextInsertionPolicy.resolved(for: "com.example.UnknownApp")

        #expect(policy == .defaultPolicy)
        #expect(policy.preferredMethod == .pasteboard)
        #expect(policy.allowsPermissivePasteFallback == false)
    }

    @Test("nil bundle identifier uses the default pasteboard-only policy")
    func nilBundleIdentifierUsesDefaultPolicy() {
        let policy = TextInsertionPolicy.resolved(for: nil)

        #expect(policy == .defaultPolicy)
    }

    @Test("Claude enables the app-specific fallback policy")
    func claudeUsesAppSpecificPolicy() {
        let policy = TextInsertionPolicy.resolved(for: "com.anthropic.claudefordesktop")

        #expect(policy.preferredMethod == .accessibilityValueReplacement)
        #expect(policy.allowsPermissivePasteFallback == true)
    }

    @Test("Warp enables permissive paste fallback without AX value replacement")
    func warpUsesPasteboardFallbackPolicy() {
        let policy = TextInsertionPolicy.resolved(for: "dev.warp.Warp-Stable")

        #expect(policy.preferredMethod == .pasteboard)
        #expect(policy.allowsPermissivePasteFallback == true)
    }
}
