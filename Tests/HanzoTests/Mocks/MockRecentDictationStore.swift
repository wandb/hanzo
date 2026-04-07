import Foundation
@testable import HanzoCore

final class MockRecentDictationStore: RecentDictationStoreProtocol {
    var entries: [RecentDictationEntry] = []
    private(set) var loadCallCount = 0
    private(set) var appendCallCount = 0
    private(set) var clearCallCount = 0

    func load() -> [RecentDictationEntry] {
        loadCallCount += 1
        return entries
    }

    func append(_ entry: RecentDictationEntry) {
        appendCallCount += 1
        entries.insert(entry, at: 0)
    }

    func clear() {
        clearCallCount += 1
        entries = []
    }
}
