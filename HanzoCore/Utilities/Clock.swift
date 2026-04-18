import Foundation

/// Abstracts wall-clock access so components with time-dependent logic
/// (silence detection, hold-to-speak activation) can be driven by a
/// manually advanced clock in tests.
protocol ClockProtocol: Sendable {
    func now() -> Date
}

struct SystemClock: ClockProtocol {
    func now() -> Date { Date() }
}
