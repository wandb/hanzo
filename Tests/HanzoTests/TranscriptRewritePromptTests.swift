import Foundation
import Testing
@testable import HanzoCore

@Suite("TranscriptRewritePrompt")
struct TranscriptRewritePromptTests {
    private func withDefaults<T>(_ body: (UserDefaults) -> T) -> T {
        let suiteName = "TranscriptRewritePromptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return body(defaults)
    }

    @Test("default rewrite template validates")
    func defaultTemplateValidates() {
        let validationError = TranscriptRewritePrompt.validateTemplate(
            TranscriptRewritePrompt.defaultTemplate()
        )
        #expect(validationError == nil)
    }

    @Test("default rewrite template includes syntax token guidance")
    func defaultTemplateIncludesSyntaxTokenGuidance() {
        let template = TranscriptRewritePrompt.defaultTemplate()
        #expect(template.contains("Rewrite context:"))
        #expect(template.contains("Preserve tokens starting with @, /, or #."))
        #expect(template.contains("follow app-specific patterns for mentions, commands, and channels"))
        #expect(template.contains("Do not add @mentions, /commands, or #channels if intent is unclear."))
    }

    @Test("resource bundle resolver finds packaged app resources")
    func resourceBundleResolverFindsPackagedAppResources() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranscriptRewritePromptTests.\(UUID().uuidString)", isDirectory: true)
        let resourceRoot = tempRoot
            .appendingPathComponent("Hanzo.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let bundleURL = resourceRoot.appendingPathComponent("Hanzo_HanzoCore.bundle", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = TranscriptRewritePrompt.resolveResourceBundleURL(candidateRoots: [resourceRoot])

        #expect(resolved?.standardizedFileURL == bundleURL.standardizedFileURL)
    }

    @Test("resource bundle resolver finds SwiftPM sibling bundle")
    func resourceBundleResolverFindsSwiftPMSiblingBundle() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranscriptRewritePromptTests.\(UUID().uuidString)", isDirectory: true)
        let debugRoot = tempRoot.appendingPathComponent("debug", isDirectory: true)
        let xctestRoot = debugRoot.appendingPathComponent("HanzoPackageTests.xctest", isDirectory: true)
        let bundleURL = debugRoot.appendingPathComponent("Hanzo_HanzoCore.bundle", isDirectory: true)

        try FileManager.default.createDirectory(at: xctestRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = TranscriptRewritePrompt.resolveResourceBundleURL(
            candidateRoots: [xctestRoot, xctestRoot.deletingLastPathComponent()]
        )

        #expect(resolved?.standardizedFileURL == bundleURL.standardizedFileURL)
    }

    @Test("validation fails when transcript placeholder is missing")
    func validationFailsWhenTranscriptPlaceholderMissing() {
        let template = """
        System instructions.

        Rewrite without transcript variable.
        """

        let validationError = TranscriptRewritePrompt.validateTemplate(template)
        #expect(validationError == "Template must include '{{transcript}}'.")
    }

    @Test("validation fails for unsupported placeholder")
    func validationFailsForUnsupportedPlaceholder() {
        let template = """
        System instructions.

        Transcript: {{transcript}}
        Foo: {{foo}}
        """

        let validationError = TranscriptRewritePrompt.validateTemplate(template)
        #expect(validationError == "Unsupported placeholder '{{foo}}'.")
    }

    @Test("render uses saved custom template and inserts dynamic values")
    func renderUsesSavedCustomTemplate() {
        withDefaults { defaults in
            let customTemplate = """
            System rewrite policy.

            {{#instructions}}Instruction: {{instructions}}
            {{/instructions}}{{#target_app}}Target app: {{target_app}}
            {{/target_app}}Transcript: {{transcript}}
            """

            #expect(TranscriptRewritePrompt.validateTemplate(customTemplate) == nil)
            TranscriptRewritePrompt.setCustomTemplate(customTemplate, defaults: defaults)

            let rendered = TranscriptRewritePrompt.render(
                transcript: "hello world",
                instructions: "Make this concise.",
                targetApp: "Slack",
                defaults: defaults
            )

            #expect(rendered.system == "System rewrite policy.")
            #expect(rendered.user.contains("Make this concise."))
            #expect(rendered.user.contains("Slack"))
            #expect(rendered.user.contains("hello world"))

            let withoutOptionalValues = TranscriptRewritePrompt.render(
                transcript: "hello world",
                instructions: nil,
                targetApp: nil,
                defaults: defaults
            )

            #expect(!withoutOptionalValues.user.contains("Instruction:"))
            #expect(!withoutOptionalValues.user.contains("Target app:"))
            #expect(withoutOptionalValues.user.contains("hello world"))
        }
    }

    @Test("validation fails for legacy user_prompt placeholder")
    func validationFailsForLegacyUserPromptPlaceholder() {
        let legacyTemplate = """
        System rewrite policy.

        {{#user_prompt}}Instruction: {{user_prompt}}{{/user_prompt}}
        Transcript: {{transcript}}
        """

        let validationError = TranscriptRewritePrompt.validateTemplate(legacyTemplate)
        #expect(validationError == "Unsupported section '{{#user_prompt}}'.")
    }

    @Test("render falls back to default template when stored template is invalid")
    func renderFallsBackToDefaultTemplateWhenStoredTemplateInvalid() {
        withDefaults { defaults in
            defaults.set(
                "Broken template {{#instructions}} {{invalid}}",
                forKey: Constants.rewritePromptTemplateKey
            )

            let rendered = TranscriptRewritePrompt.render(
                transcript: "sample text",
                instructions: nil,
                targetApp: nil,
                defaults: defaults
            )

            #expect(!rendered.system.isEmpty)
            #expect(rendered.user.contains("sample text"))
            #expect(!rendered.user.contains("{{"))
        }
    }
}
