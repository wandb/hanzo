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

            {{#user_prompt}}Instruction: {{user_prompt}}
            {{/user_prompt}}{{#target_app}}Target app: {{target_app}}
            {{/target_app}}Transcript: {{transcript}}
            """

            #expect(TranscriptRewritePrompt.validateTemplate(customTemplate) == nil)
            TranscriptRewritePrompt.setCustomTemplate(customTemplate, defaults: defaults)

            let rendered = TranscriptRewritePrompt.render(
                transcript: "hello world",
                userPrompt: "Make this concise.",
                targetApp: "Slack",
                defaults: defaults
            )

            #expect(rendered.system == "System rewrite policy.")
            #expect(rendered.user.contains("Make this concise."))
            #expect(rendered.user.contains("Slack"))
            #expect(rendered.user.contains("hello world"))

            let withoutOptionalValues = TranscriptRewritePrompt.render(
                transcript: "hello world",
                userPrompt: nil,
                targetApp: nil,
                defaults: defaults
            )

            #expect(!withoutOptionalValues.user.contains("Instruction:"))
            #expect(!withoutOptionalValues.user.contains("Target app:"))
            #expect(withoutOptionalValues.user.contains("hello world"))
        }
    }

    @Test("render falls back to default template when stored template is invalid")
    func renderFallsBackToDefaultTemplateWhenStoredTemplateInvalid() {
        withDefaults { defaults in
            defaults.set(
                "Broken template {{#user_prompt}} {{invalid}}",
                forKey: Constants.rewritePromptTemplateKey
            )

            let rendered = TranscriptRewritePrompt.render(
                transcript: "sample text",
                userPrompt: nil,
                targetApp: nil,
                defaults: defaults
            )

            #expect(!rendered.system.isEmpty)
            #expect(rendered.user.contains("sample text"))
            #expect(!rendered.user.contains("{{"))
        }
    }
}
