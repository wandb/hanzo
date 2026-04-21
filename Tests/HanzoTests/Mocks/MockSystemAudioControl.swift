@testable import HanzoCore
import Foundation

final class MockSystemAudioControl: SystemAudioControlProtocol {
    private let lock = NSLock()
    private var _muteCallCount = 0
    private var _restoreCallCount = 0

    var muteCallCount: Int {
        withLock { _muteCallCount }
    }

    var restoreCallCount: Int {
        withLock { _restoreCallCount }
    }

    func muteDefaultOutput() {
        withLock { _muteCallCount += 1 }
    }

    func restoreDefaultOutput() {
        withLock { _restoreCallCount += 1 }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
