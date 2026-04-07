import Foundation

enum TranscriptRewritePrompt {
    private static let resourceBundleName = "Hanzo_HanzoCore.bundle"
    private static let fallbackTemplate = """
    You are a real-time transcript rewriter. Return only polished transcript text with meaning and factual content preserved. Apply the user's instructions exactly. If a style or tone is specified, ensure the output clearly reflects it.

    Follow these guidelines:
    - Remove verbal pauses (e.g., um, uh, like, you know).
    - Preserve tokens starting with @, /, or #.
    - When intent is explicit, follow app-specific patterns for mentions, commands, and channels.
    - Do not add @mentions, /commands, or #channels if intent is unclear.
    - Return only the rewritten text with no analysis or commentary.
    - The user message contains the raw transcript text to rewrite.

    Rewrite context:
    {{#target_app}}App: {{target_app}}
    {{/target_app}}{{#instructions}}Instructions:
    {{instructions}}
    {{/instructions}}{{#common_terms}}Common terms:
    {{common_terms}}
    {{/common_terms}}
    """
    private static let allowedInterpolationKeys: Set<String> = [
        "instructions",
        "target_app",
        "common_terms"
    ]
    private static let allowedConditionalKeys: Set<String> = [
        "instructions",
        "target_app",
        "common_terms"
    ]
    private final class BundleLocator {}

    static func defaultTemplate() -> String {
        loadTemplate("rewrite")
    }

    static func activeTemplate(settings: AppSettingsProtocol) -> String {
        if let customTemplate = customTemplate(settings: settings) {
            return customTemplate
        }
        return defaultTemplate()
    }

    static func activeTemplate(defaults: UserDefaults = .standard) -> String {
        activeTemplate(settings: settings(from: defaults))
    }

    static func customTemplate(settings: AppSettingsProtocol) -> String? {
        guard let template = settings.customRewritePromptTemplate else {
            return nil
        }

        guard validateTemplate(template) == nil else {
            settings.customRewritePromptTemplate = nil
            return nil
        }

        return template
    }

    static func customTemplate(defaults: UserDefaults = .standard) -> String? {
        customTemplate(settings: settings(from: defaults))
    }

    static func setCustomTemplate(_ template: String?, settings: AppSettingsProtocol) {
        guard let template else {
            settings.customRewritePromptTemplate = nil
            return
        }

        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            settings.customRewritePromptTemplate = nil
            return
        }

        let normalizedTemplate = template.replacingOccurrences(of: "\r\n", with: "\n")
        let normalizedDefault = defaultTemplate().replacingOccurrences(of: "\r\n", with: "\n")
        if normalizedTemplate == normalizedDefault {
            settings.customRewritePromptTemplate = nil
            return
        }

        settings.customRewritePromptTemplate = template
    }

    static func setCustomTemplate(_ template: String?, defaults: UserDefaults = .standard) {
        setCustomTemplate(template, settings: settings(from: defaults))
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
        }

        if let openSection = sectionStack.last {
            return "Missing closing section tag for '{{#\(openSection)}}'."
        }

        let withoutTokens = tokenRegex.stringByReplacingMatches(in: template, range: nsRange, withTemplate: "")
        if withoutTokens.contains("{{") || withoutTokens.contains("}}") {
            return "Template has malformed placeholder braces."
        }

        let renderedWithAllVariables = renderTemplate(
            template,
            variables: [
                "instructions": "Use a concise style.",
                "target_app": "Slack",
                "common_terms": "LLM\nPyTorch"
            ]
        )
        let renderedWithoutOptionalVariables = renderTemplate(
            template,
            variables: [:]
        )

        if renderedWithAllVariables.contains("{{")
            || renderedWithAllVariables.contains("}}")
            || renderedWithoutOptionalVariables.contains("{{")
            || renderedWithoutOptionalVariables.contains("}}") {
            return "Template has unresolved placeholders after rendering."
        }

        if renderedWithoutOptionalVariables.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Template must render non-empty system instructions."
        }

        return nil
    }

    /// Renders the rewrite prompt template as the system message.
    static func render(
        instructions: String? = nil,
        targetApp: String? = nil,
        commonTerms: [String] = [],
        templateOverride: String? = nil,
        settings: AppSettingsProtocol
    ) -> String {
        let normalizedInstructions = (instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommonTerms = commonTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var vars: [String: String] = [:]
        if !normalizedInstructions.isEmpty {
            vars["instructions"] = normalizedInstructions
        }
        if let targetApp, !targetApp.isEmpty {
            vars["target_app"] = targetApp
        }
        if !normalizedCommonTerms.isEmpty {
            vars["common_terms"] = normalizedCommonTerms.joined(separator: "\n")
        }

        let candidateTemplate = templateOverride ?? activeTemplate(settings: settings)
        let template = validateTemplate(candidateTemplate) == nil ? candidateTemplate : defaultTemplate()
        let rendered = renderTemplate(template, variables: vars)

        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func render(
        instructions: String? = nil,
        targetApp: String? = nil,
        commonTerms: [String] = [],
        templateOverride: String? = nil,
        defaults: UserDefaults = .standard
    ) -> String {
        render(
            instructions: instructions,
            targetApp: targetApp,
            commonTerms: commonTerms,
            templateOverride: templateOverride,
            settings: settings(from: defaults)
        )
    }

    static func templateIncludesCommonTermsPlaceholder(_ template: String) -> Bool {
        let tokenPattern = #"\{\{([^{}]+)\}\}"#
        guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern) else {
            return false
        }

        let nsRange = NSRange(template.startIndex..., in: template)
        return tokenRegex.matches(in: template, range: nsRange).contains { match in
            guard let tokenRange = Range(match.range(at: 1), in: template) else {
                return false
            }
            let token = String(template[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return token == "common_terms"
        }
    }

    // MARK: - Template Loading

    private static func loadTemplate(_ name: String) -> String {
        guard let bundle = resourceBundle(),
              let url = bundle.url(forResource: name, withExtension: "txt") else {
            NSLog("Hanzo: missing prompt template \(name).txt; using fallback.")
            return fallbackTemplate
        }
        guard let template = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("Hanzo: failed to read prompt template \(name).txt; using fallback.")
            return fallbackTemplate
        }
        return template
    }

    private static func settings(from defaults: UserDefaults) -> AppSettingsProtocol {
        AppSettings(store: UserDefaultsAppSettingsStore(defaults: defaults))
    }

    static func resourceBundle(
        mainBundle: Bundle = .main,
        containingBundle: Bundle = Bundle(for: BundleLocator.self),
        fileManager: FileManager = .default
    ) -> Bundle? {
        let roots = resourceBundleCandidateRoots(mainBundle: mainBundle, containingBundle: containingBundle)

        if let bundleURL = resolveResourceBundleURL(candidateRoots: roots, fileManager: fileManager) {
            return Bundle(url: bundleURL)
        }

        return (Bundle.allBundles + Bundle.allFrameworks).first {
            $0.bundleURL.lastPathComponent == resourceBundleName
        }
    }

    static func resolveResourceBundleURL(
        candidateRoots: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        for root in candidateRoots {
            let candidate = root.appendingPathComponent(resourceBundleName, isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private static func resourceBundleCandidateRoots(
        mainBundle: Bundle,
        containingBundle: Bundle
    ) -> [URL] {
        var roots: [URL] = []
        var seen: Set<String> = []

        func append(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                roots.append(standardized)
            }
        }

        append(mainBundle.resourceURL)
        append(mainBundle.bundleURL)
        append(mainBundle.bundleURL.deletingLastPathComponent())
        append(containingBundle.resourceURL)
        append(containingBundle.bundleURL)
        append(containingBundle.bundleURL.deletingLastPathComponent())

        return roots
    }

    // MARK: - Mustache-style Rendering

    /// Supports `{{var}}` for interpolation, `{{#var}}...{{/var}}` for conditional sections.
    private static func renderTemplate(_ template: String, variables: [String: String]) -> String {
        var result = template

        // Conditional sections: {{#key}}...{{/key}} — kept only when key resolves to non-empty text.
        let sectionPattern = #"\{\{#(\w+)\}\}(.*?)\{\{/\1\}\}"#
        while let regex = try? NSRegularExpression(pattern: sectionPattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) {
            let keyRange = Range(match.range(at: 1), in: result)!
            let bodyRange = Range(match.range(at: 2), in: result)!
            let fullRange = Range(match.range, in: result)!
            let key = String(result[keyRange])
            let body = String(result[bodyRange])

            if let value = variables[key], !value.isEmpty {
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
