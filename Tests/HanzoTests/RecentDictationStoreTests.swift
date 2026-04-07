import Foundation
import Testing
@testable import HanzoCore

@Suite("RecentDictationStore")
struct RecentDictationStoreTests {
    private func withDefaults<T>(_ body: (UserDefaults) -> T) -> T {
        let suiteName = "RecentDictationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return body(defaults)
    }

    @Test("append stores newest entries first")
    func appendStoresNewestFirst() {
        withDefaults { defaults in
            let logger = MockLogger()
            let store = RecentDictationStore(defaults: defaults, logger: logger)
            let older = RecentDictationEntry(
                id: UUID(),
                text: "older",
                createdAt: Date(timeIntervalSince1970: 100),
                sourceBundleIdentifier: "com.example.older",
                sourceAppName: "Older",
                insertOutcome: .inserted
            )
            let newer = RecentDictationEntry(
                id: UUID(),
                text: "newer",
                createdAt: Date(timeIntervalSince1970: 200),
                sourceBundleIdentifier: "com.example.newer",
                sourceAppName: "Newer",
                insertOutcome: .failed
            )

            store.append(older)
            store.append(newer)

            let loaded = store.load()
            #expect(loaded.map(\.text) == ["newer", "older"])
        }
    }

    @Test("append enforces rolling max entry count")
    func appendEnforcesRollingMaxCount() {
        withDefaults { defaults in
            let logger = MockLogger()
            let store = RecentDictationStore(defaults: defaults, logger: logger)

            for index in 0..<25 {
                store.append(
                    RecentDictationEntry(
                        id: UUID(),
                        text: "entry-\(index)",
                        createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        sourceBundleIdentifier: nil,
                        sourceAppName: nil,
                        insertOutcome: .inserted
                    )
                )
            }

            let loaded = store.load()
            #expect(loaded.count == Constants.recentDictationsMaxCount)
            #expect(loaded.first?.text == "entry-24")
            #expect(loaded.last?.text == "entry-5")
        }
    }

    @Test("clear removes persisted entries")
    func clearRemovesPersistedEntries() {
        withDefaults { defaults in
            let logger = MockLogger()
            let store = RecentDictationStore(defaults: defaults, logger: logger)
            store.append(
                RecentDictationEntry(
                    id: UUID(),
                    text: "to-clear",
                    createdAt: Date(),
                    sourceBundleIdentifier: nil,
                    sourceAppName: nil,
                    insertOutcome: .inserted
                )
            )

            store.clear()

            #expect(store.load().isEmpty)
        }
    }

    @Test("persisted entries decode with full field fidelity")
    func persistedEntriesDecodeWithFieldFidelity() {
        withDefaults { defaults in
            let logger = MockLogger()
            let store = RecentDictationStore(defaults: defaults, logger: logger)
            let expected = RecentDictationEntry(
                id: UUID(),
                text: "roundtrip",
                createdAt: Date(timeIntervalSince1970: 999),
                sourceBundleIdentifier: "com.example.roundtrip",
                sourceAppName: "Roundtrip App",
                insertOutcome: .failed
            )

            store.append(expected)

            let loaded = store.load()
            #expect(loaded.first == expected)
        }
    }
}
