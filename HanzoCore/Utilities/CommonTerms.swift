import Foundation

enum CommonTerms {
    static func parse(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }

        var seen: Set<String> = []
        var terms: [String] = []

        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            terms.append(trimmed)
        }

        return terms
    }

    static func merge(globalRaw: String, appRaw: String?) -> [String] {
        let globalTerms = parse(globalRaw)
        let appTerms = parse(appRaw ?? "")

        var seen: Set<String> = []
        var merged: [String] = []

        for term in globalTerms + appTerms where seen.insert(term).inserted {
            merged.append(term)
        }

        return merged
    }
}
