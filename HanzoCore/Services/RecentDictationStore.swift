import Foundation

final class RecentDictationStore: RecentDictationStoreProtocol {
    private let defaults: UserDefaults
    private let logger: LoggingServiceProtocol
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        logger: LoggingServiceProtocol = LoggingService.shared
    ) {
        self.defaults = defaults
        self.logger = logger
    }

    func load() -> [RecentDictationEntry] {
        guard let data = defaults.data(forKey: Constants.recentDictationsKey) else {
            return []
        }

        guard let decoded = try? decoder.decode([RecentDictationEntry].self, from: data) else {
            logger.warn("Failed to decode recent dictation history; clearing persisted value")
            defaults.removeObject(forKey: Constants.recentDictationsKey)
            return []
        }

        return Array(decoded.prefix(Constants.recentDictationsMaxCount))
    }

    func append(_ entry: RecentDictationEntry) {
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > Constants.recentDictationsMaxCount {
            entries.removeLast(entries.count - Constants.recentDictationsMaxCount)
        }
        persist(entries)
    }

    func clear() {
        defaults.removeObject(forKey: Constants.recentDictationsKey)
    }

    // MARK: - Private

    private func persist(_ entries: [RecentDictationEntry]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Constants.recentDictationsKey)
            return
        }

        guard let data = try? encoder.encode(entries) else {
            logger.warn("Failed to encode recent dictation history; keeping previous value")
            return
        }

        defaults.set(data, forKey: Constants.recentDictationsKey)
    }
}
