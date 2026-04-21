@testable import HanzoCore
import Foundation

/// Manually advanced clock for tests. Replaces wall-clock time in
/// silence detection and audio-chunk timestamps so tests can simulate
/// elapsed durations without `Task.sleep`.
///
/// Thread-safety: `now()` and `advance(by:)` may be called from any
/// context. Swift's non-Sendable warning is suppressed via the
/// `@unchecked Sendable` conformance — justification: all mutable state
/// is guarded by an `NSLock`.
final class TestClock: ClockProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime: Date

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.currentTime = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    /// Advance the clock by `interval` seconds. Mirrors the wall-clock
    /// duration a production component would have observed.
    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        currentTime = currentTime.addingTimeInterval(interval)
    }

    /// Set the clock to an exact date (used for test setup).
    func set(to date: Date) {
        lock.lock()
        defer { lock.unlock() }
        currentTime = date
    }
}
