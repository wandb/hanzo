import Foundation
import Testing
@testable import HanzoCore

@Suite("ReleaseNotesProvider")
struct ReleaseNotesProviderTests {
    @Test("parseEntries returns versioned changelog entries in order")
    func parseEntriesReturnsVersionedEntries() {
        let changelog = """
        # Changelog

        ## [1.1.1] - 2026-04-04

        ### Highlights

        - Added a full changelog window.

        ## [1.1.0] - 2026-03-18

        - Older release.
        """

        let entries = ReleaseNotesProvider.parseEntries(from: changelog)

        #expect(entries.count == 2)
        #expect(entries[0].version == "1.1.1")
        #expect(entries[0].date == "2026-04-04")
        #expect(entries[0].body.contains("Highlights"))
        #expect(entries[1].version == "1.1.0")
    }

    @Test("parseEntries trims surrounding blank lines from entry body")
    func parseEntriesTrimsEntryBody() {
        let changelog = """
        ## [1.1.1] - 2026-04-04


        - Added a full changelog window.


        """

        let entries = ReleaseNotesProvider.parseEntries(from: changelog)

        #expect(entries.count == 1)
        #expect(entries[0].body == "- Added a full changelog window.")
    }

    @Test("parseEntries supports entries without a date suffix")
    func parseEntriesSupportsEntriesWithoutDate() {
        let changelog = """
        ## [1.1.1]

        - Added a full changelog window.
        """

        let entries = ReleaseNotesProvider.parseEntries(from: changelog)

        #expect(entries.count == 1)
        #expect(entries[0].date == nil)
    }

    @Test("resolveChangelogURL finds packaged app resources")
    func resolveChangelogURLFindsPackagedResources() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReleaseNotesProviderTests.\(UUID().uuidString)", isDirectory: true)
        let resourceRoot = tempRoot
            .appendingPathComponent("Hanzo.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let changelogURL = resourceRoot.appendingPathComponent("CHANGELOG.md", isDirectory: false)

        try FileManager.default.createDirectory(at: resourceRoot, withIntermediateDirectories: true)
        try Data("# Changelog".utf8).write(to: changelogURL)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let resolved = ReleaseNotesProvider.resolveChangelogURL(candidateRoots: [resourceRoot])

        #expect(resolved?.standardizedFileURL == changelogURL.standardizedFileURL)
    }
}
