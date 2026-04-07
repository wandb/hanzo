import Foundation

protocol RecentDictationStoreProtocol {
    func load() -> [RecentDictationEntry]
    func append(_ entry: RecentDictationEntry)
    func clear()
}
