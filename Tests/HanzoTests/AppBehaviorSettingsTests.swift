import Foundation
import Testing
@testable import HanzoCore

@Suite("AppBehaviorSettings")
struct AppBehaviorSettingsTests {
    private func withDefaults<T>(_ body: (UserDefaults) -> T) -> T {
        let suiteName = "AppBehaviorSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return body(defaults)
    }

    @Test("resolvedBehavior uses global defaults when no values are set")
    func resolvedBehaviorUsesGlobalDefaults() {
        withDefaults { defaults in
            let resolved = AppBehaviorSettings.resolvedBehavior(
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )
            #expect(resolved.autoSubmitMode == Constants.defaultAutoSubmitMode)
            #expect(resolved.silenceTimeout == Constants.defaultSilenceTimeout)
            #expect(resolved.isUsingAppOverride == false)
        }
    }

    @Test("resolvedBehavior applies app override and falls back per field")
    func resolvedBehaviorMergesAppOverrideWithGlobalDefaults() {
        withDefaults { defaults in
            AppBehaviorSettings.setGlobalAutoSubmitMode(.cmdEnter, defaults: defaults)
            AppBehaviorSettings.setGlobalSilenceTimeout(3, defaults: defaults)
            AppBehaviorSettings.saveOverride(
                AppBehaviorOverride(autoSubmitMode: .enter, silenceTimeout: nil),
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )

            let resolved = AppBehaviorSettings.resolvedBehavior(
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )
            #expect(resolved.autoSubmitMode == .enter)
            #expect(resolved.silenceTimeout == 3)
            #expect(resolved.isUsingAppOverride == true)
        }
    }

    @Test("resolvedBehavior ignores overrides for unsupported bundle identifiers")
    func resolvedBehaviorIgnoresUnsupportedOverrides() {
        withDefaults { defaults in
            let unsupportedBundleIdentifier = "com.example.UnsupportedApp"
            AppBehaviorSettings.setGlobalAutoSubmitMode(.off, defaults: defaults)
            AppBehaviorSettings.setGlobalSilenceTimeout(5, defaults: defaults)
            AppBehaviorSettings.saveOverride(
                AppBehaviorOverride(autoSubmitMode: .enter, silenceTimeout: 1),
                for: unsupportedBundleIdentifier,
                defaults: defaults
            )

            let resolved = AppBehaviorSettings.resolvedBehavior(
                for: unsupportedBundleIdentifier,
                defaults: defaults
            )
            #expect(resolved.autoSubmitMode == .off)
            #expect(resolved.silenceTimeout == 5)
            #expect(resolved.isUsingAppOverride == false)
        }
    }

    @Test("saveOverride removes entry when override is empty")
    func saveOverrideRemovesEntryWhenEmpty() {
        withDefaults { defaults in
            let bundleIdentifier = "com.tinyspeck.slackmacgap"
            AppBehaviorSettings.saveOverride(
                AppBehaviorOverride(autoSubmitMode: .enter, silenceTimeout: 2),
                for: bundleIdentifier,
                defaults: defaults
            )
            #expect(AppBehaviorSettings.override(for: bundleIdentifier, defaults: defaults) != nil)

            AppBehaviorSettings.saveOverride(
                AppBehaviorOverride(autoSubmitMode: nil, silenceTimeout: nil),
                for: bundleIdentifier,
                defaults: defaults
            )
            #expect(AppBehaviorSettings.override(for: bundleIdentifier, defaults: defaults) == nil)
        }
    }

    @Test("addCustomApp makes bundle supported for overrides")
    func addCustomAppMakesBundleSupported() {
        withDefaults { defaults in
            let result = AppBehaviorSettings.addCustomApp(
                bundleIdentifier: "com.example.CustomApp",
                displayName: "Custom App",
                defaults: defaults
            )
            #expect(result == .added)
            #expect(AppBehaviorSettings.isSupported(bundleIdentifier: "com.example.CustomApp", defaults: defaults))
        }
    }

    @Test("resolvedBehavior returns global post-processing mode when no override exists")
    func resolvedBehaviorUsesGlobalPostProcessingMode() {
        withDefaults { defaults in
            AppBehaviorSettings.setGlobalPostProcessingMode(.llm, defaults: defaults)

            let resolved = AppBehaviorSettings.resolvedBehavior(
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )
            #expect(resolved.postProcessingMode == .llm)
        }
    }

    @Test("resolvedBehavior returns overridden post-processing mode when set")
    func resolvedBehaviorUsesOverriddenPostProcessingMode() {
        withDefaults { defaults in
            AppBehaviorSettings.setGlobalPostProcessingMode(.llm, defaults: defaults)
            AppBehaviorSettings.saveOverride(
                AppBehaviorOverride(postProcessingMode: .off),
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )

            let resolved = AppBehaviorSettings.resolvedBehavior(
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )
            #expect(resolved.postProcessingMode == .off)
            #expect(resolved.isUsingAppOverride == true)
        }
    }

    @Test("resolvedBehavior falls back to global post-processing mode when override is nil")
    func resolvedBehaviorFallsBackToGlobalPostProcessingMode() {
        withDefaults { defaults in
            AppBehaviorSettings.setGlobalPostProcessingMode(.llm, defaults: defaults)
            AppBehaviorSettings.saveOverride(
                AppBehaviorOverride(autoSubmitMode: .enter, postProcessingMode: nil),
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )

            let resolved = AppBehaviorSettings.resolvedBehavior(
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )
            #expect(resolved.postProcessingMode == .llm)
            #expect(resolved.autoSubmitMode == .enter)
        }
    }

    @Test("hasOverrides returns true when only postProcessingMode is set")
    func hasOverridesWithOnlyPostProcessingMode() {
        let override = AppBehaviorOverride(postProcessingMode: .off)
        #expect(override.hasOverrides == true)
    }

    @Test("resolvedBehavior uses per-app LLM prompt when set")
    func resolvedBehaviorUsesPerAppLLMPrompt() {
        withDefaults { defaults in
            AppBehaviorSettings.setGlobalPostProcessingMode(.llm, defaults: defaults)
            AppBehaviorSettings.setGlobalLLMPostProcessingPrompt("Global prompt", defaults: defaults)
            AppBehaviorSettings.saveOverride(
                AppBehaviorOverride(llmPostProcessingPrompt: "Slack-specific prompt"),
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )

            let resolved = AppBehaviorSettings.resolvedBehavior(
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )
            #expect(resolved.llmPostProcessingPrompt == "Slack-specific prompt")
            #expect(resolved.isUsingAppOverride == true)
        }
    }

    @Test("resolvedBehavior falls back to global LLM prompt when per-app prompt is nil")
    func resolvedBehaviorFallsBackToGlobalLLMPrompt() {
        withDefaults { defaults in
            AppBehaviorSettings.setGlobalLLMPostProcessingPrompt("Global prompt", defaults: defaults)
            AppBehaviorSettings.saveOverride(
                AppBehaviorOverride(autoSubmitMode: .enter),
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )

            let resolved = AppBehaviorSettings.resolvedBehavior(
                for: "com.tinyspeck.slackmacgap",
                defaults: defaults
            )
            #expect(resolved.llmPostProcessingPrompt == "Global prompt")
        }
    }

    @Test("Conductor bundle identifier is supported")
    func conductorBundleIdentifierIsSupported() {
        withDefaults { defaults in
            #expect(AppBehaviorSettings.isSupported(bundleIdentifier: "com.conductor.app", defaults: defaults))
        }
    }

    @Test("removeCustomApp removes custom app and its override")
    func removeCustomAppRemovesOverride() {
        withDefaults { defaults in
            let bundleIdentifier = "com.example.CustomApp"
            _ = AppBehaviorSettings.addCustomApp(
                bundleIdentifier: bundleIdentifier,
                displayName: "Custom App",
                defaults: defaults
            )
            AppBehaviorSettings.saveOverride(
                AppBehaviorOverride(autoSubmitMode: .enter, silenceTimeout: 2),
                for: bundleIdentifier,
                defaults: defaults
            )

            let removed = AppBehaviorSettings.removeCustomApp(
                bundleIdentifier: bundleIdentifier,
                defaults: defaults
            )

            #expect(removed)
            #expect(!AppBehaviorSettings.isSupported(bundleIdentifier: bundleIdentifier, defaults: defaults))
            #expect(AppBehaviorSettings.override(for: bundleIdentifier, defaults: defaults) == nil)
        }
    }
}
