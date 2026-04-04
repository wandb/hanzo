import Foundation

struct ReleaseNotesEntry: Equatable, Identifiable {
    let version: String
    let date: String?
    let body: String

    var id: String { version }
}

enum ReleaseNotesProvider {
    private static let changelogFileName = "CHANGELOG.md"
    private final class BundleLocator {}

    static func loadEntries(
        mainBundle: Bundle = .main,
        containingBundle: Bundle = Bundle(for: BundleLocator.self),
        fileManager: FileManager = .default
    ) -> [ReleaseNotesEntry] {
        guard let changelog = loadChangelog(
            mainBundle: mainBundle,
            containingBundle: containingBundle,
            fileManager: fileManager
        ) else {
            return []
        }

        return parseEntries(from: changelog)
    }

    static func loadChangelog(
        mainBundle: Bundle = .main,
        containingBundle: Bundle = Bundle(for: BundleLocator.self),
        fileManager: FileManager = .default
    ) -> String? {
        let roots = changelogCandidateRoots(mainBundle: mainBundle, containingBundle: containingBundle)

        if let changelogURL = resolveChangelogURL(candidateRoots: roots, fileManager: fileManager) {
            return try? String(contentsOf: changelogURL, encoding: .utf8)
        }

        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            guard let resourceURL = bundle.resourceURL else { continue }
            let candidate = resourceURL.appendingPathComponent(changelogFileName, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                return try? String(contentsOf: candidate, encoding: .utf8)
            }
        }

        return nil
    }

    static func resolveChangelogURL(
        candidateRoots: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        for root in candidateRoots {
            let candidate = root.appendingPathComponent(changelogFileName, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    static func parseEntries(from markdown: String) -> [ReleaseNotesEntry] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var entries: [ReleaseNotesEntry] = []
        var currentVersion: String?
        var currentDate: String?
        var bodyLines: [String] = []

        func flushCurrentEntry() {
            guard let currentVersion else { return }

            let body = trimBody(bodyLines.joined(separator: "\n"))
            guard !body.isEmpty else { return }

            entries.append(
                ReleaseNotesEntry(
                    version: currentVersion,
                    date: currentDate,
                    body: body
                )
            )
        }

        for line in lines {
            if let heading = parseHeading(line) {
                flushCurrentEntry()
                currentVersion = heading.version
                currentDate = heading.date
                bodyLines = []
                continue
            }

            guard currentVersion != nil else { continue }
            bodyLines.append(line)
        }

        flushCurrentEntry()
        return entries
    }

    private static func changelogCandidateRoots(
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

    private static func parseHeading(_ line: String) -> (version: String, date: String?)? {
        guard line.hasPrefix("## [") else { return nil }

        let remainder = line.dropFirst(4)
        guard let closingBracket = remainder.firstIndex(of: "]") else { return nil }

        let version = remainder[..<closingBracket].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return nil }

        let suffixStart = remainder.index(after: closingBracket)
        let suffix = remainder[suffixStart...]
        let date: String?

        if suffix.hasPrefix(" - ") {
            let value = suffix.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
            date = value.isEmpty ? nil : value
        } else {
            date = nil
        }

        return (version, date)
    }

    private static func trimBody(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
