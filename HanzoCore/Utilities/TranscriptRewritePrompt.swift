import Foundation

enum TranscriptRewritePrompt {
    private static let fallbackTemplate = """
    You are a real-time transcript rewriter. Always return polished transcript text. Preserve meaning and factual content. Apply the user's instruction exactly. If the user gives a style or tone instruction, the output must clearly reflect that instruction. Return only the rewritten transcript text without analysis or commentary.

    {{#user_prompt}}
    User rewrite instruction:
    {{user_prompt}}

    {{/user_prompt}}
    Clean up and rewrite the transcript for clarity while preserving meaning. Remove verbal pauses (um, uh, like, you know, etc.).{{#target_app}} The text will be inserted into {{target_app}}.{{/target_app}}

    Transcript:
    {{transcript}}
    """
    private static let allowedInterpolationKeys: Set<String> = [
        "transcript",
        "user_prompt",
        "target_app"
    ]
    private static let allowedConditionalKeys: Set<String> = [
        "user_prompt",
        "target_app"
    ]

    static func defaultTemplate() -> String {
        loadTemplate("rewrite")
    }

    static func activeTemplate(defaults: UserDefaults = .standard) -> String {
        if let customTemplate = customTemplate(defaults: defaults) {
            return customTemplate
        }
        return defaultTemplate()
    }

    static func customTemplate(defaults: UserDefaults = .standard) -> String? {
        guard let stored = defaults.string(forKey: Constants.rewritePromptTemplateKey) else {
            return nil
        }

        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : stored
    }

    static func setCustomTemplate(_ template: String?, defaults: UserDefaults = .standard) {
        guard let template else {
            defaults.removeObject(forKey: Constants.rewritePromptTemplateKey)
            return
        }

        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Constants.rewritePromptTemplateKey)
            return
        }

        let normalizedTemplate = template.replacingOccurrences(of: "\r\n", with: "\n")
        let normalizedDefault = defaultTemplate().replacingOccurrences(of: "\r\n", with: "\n")
        if normalizedTemplate == normalizedDefault {
            defaults.removeObject(forKey: Constants.rewritePromptTemplateKey)
            return
        }

        defaults.set(template, forKey: Constants.rewritePromptTemplateKey)
    }

    static func validateTemplate(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Template cannot be empty."
        }

        let tokenPattern = #"\{\{([^{}]+)\}\}"#
        guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern) else {
            return "Failed to parse template placeholders."
        }

        let nsRange = NSRange(template.startIndex..., in: template)
        let matches = tokenRegex.matches(in: template, range: nsRange)
        var sectionStack: [String] = []
        var hasTranscriptPlaceholder = false

        for match in matches {
            guard let tokenRange = Range(match.range(at: 1), in: template) else {
                continue
            }

            let token = String(template[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                return "Template contains an empty placeholder."
            }

            if token.hasPrefix("#") {
                let key = String(token.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard allowedConditionalKeys.contains(key) else {
                    return "Unsupported section '{{#\(key)}}'."
                }
                sectionStack.append(key)
                continue
            }

            if token.hasPrefix("/") {
                let key = String(token.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let openKey = sectionStack.last else {
                    return "Section '{{/\(key)}}' does not have a matching opener."
                }
                guard openKey == key else {
                    return "Section '{{/\(key)}}' does not match '{{#\(openKey)}}'."
                }
                sectionStack.removeLast()
                continue
            }

            guard allowedInterpolationKeys.contains(token) else {
                return "Unsupported placeholder '{{\(token)}}'."
            }

            if token == "transcript" {
                hasTranscriptPlaceholder = true
            }
        }

        if let openSection = sectionStack.last {
            return "Missing closing section tag for '{{#\(openSection)}}'."
        }

        guard hasTranscriptPlaceholder else {
            return "Template must include '{{transcript}}'."
        }

        let withoutTokens = tokenRegex.stringByReplacingMatches(in: template, range: nsRange, withTemplate: "")
        if withoutTokens.contains("{{") || withoutTokens.contains("}}") {
            return "Template has malformed placeholder braces."
        }

        let sampleTranscript = "Sample transcript text."
        let renderedWithAllVariables = renderTemplate(
            template,
            variables: [
                "transcript": sampleTranscript,
                "user_prompt": "Use a concise style.",
                "target_app": "Slack"
            ]
        )
        let renderedWithoutOptionalVariables = renderTemplate(
            template,
            variables: ["transcript": sampleTranscript]
        )

        if renderedWithAllVariables.contains("{{")
            || renderedWithAllVariables.contains("}}")
            || renderedWithoutOptionalVariables.contains("{{")
            || renderedWithoutOptionalVariables.contains("}}") {
            return "Template has unresolved placeholders after rendering."
        }

        if !renderedWithAllVariables.contains(sampleTranscript)
            || !renderedWithoutOptionalVariables.contains(sampleTranscript) {
            return "Template failed to insert transcript text."
        }

        let parts = renderedWithAllVariables.components(separatedBy: "\n\n")
        let system = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let user = parts.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if system.isEmpty || user.isEmpty {
            return "Template must include system and user sections separated by a blank line."
        }

        return nil
    }

    /// Renders the rewrite prompt template, returning (systemMessage, userMessage).
    static func render(
        transcript: String,
        userPrompt: String? = nil,
        targetApp: String? = nil,
        templateOverride: String? = nil,
        defaults: UserDefaults = .standard
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

        let candidateTemplate = templateOverride ?? activeTemplate(defaults: defaults)
        let template = validateTemplate(candidateTemplate) == nil ? candidateTemplate : defaultTemplate()
        let rendered = renderTemplate(template, variables: vars)

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
            NSLog("Hanzo: missing prompt template \(name).txt; using fallback.")
            return fallbackTemplate
        }
        guard let template = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("Hanzo: failed to read prompt template \(name).txt; using fallback.")
            return fallbackTemplate
        }
        return template
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
