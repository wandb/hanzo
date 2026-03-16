import Foundation

enum TranscriptRewritePrompt {
    /// Renders the rewrite prompt template, returning (systemMessage, userMessage).
    static func render(
        transcript: String,
        userPrompt: String? = nil,
        targetApp: String? = nil
    ) -> (system: String, user: String) {
        let promptInstruction = (userPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var vars: [String: String] = [
            "transcript": transcript
        ]
        if !promptInstruction.isEmpty {
            vars["user_prompt"] = promptInstruction
        }
        if let targetApp, !targetApp.isEmpty {
            vars["target_app"] = targetApp
        }

        let rendered = renderTemplate(loadTemplate("rewrite"), variables: vars)

        // Split on the first blank line — everything before is the system message,
        // everything after is the user message.
        let parts = rendered.components(separatedBy: "\n\n")
        let system = parts.first ?? ""
        let user = parts.dropFirst().joined(separator: "\n\n")

        return (system.trimmingCharacters(in: .whitespacesAndNewlines),
                user.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Template Loading

    private static func loadTemplate(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
            fatalError("Missing prompt template: \(name).txt")
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Mustache-style Rendering

    /// Supports `{{var}}` for interpolation, `{{#var}}...{{/var}}` for conditional sections.
    private static func renderTemplate(_ template: String, variables: [String: String]) -> String {
        var result = template

        // Conditional sections: {{#key}}...{{/key}} — kept if key is present, removed otherwise
        let sectionPattern = #"\{\{#(\w+)\}\}(.*?)\{\{/\1\}\}"#
        while let regex = try? NSRegularExpression(pattern: sectionPattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) {
            let keyRange = Range(match.range(at: 1), in: result)!
            let bodyRange = Range(match.range(at: 2), in: result)!
            let fullRange = Range(match.range, in: result)!
            let key = String(result[keyRange])
            let body = String(result[bodyRange])

            if variables[key] != nil {
                result.replaceSubrange(fullRange, with: body)
            } else {
                result.replaceSubrange(fullRange, with: "")
            }
        }

        // Variable interpolation: {{key}}
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        return result
    }
}
