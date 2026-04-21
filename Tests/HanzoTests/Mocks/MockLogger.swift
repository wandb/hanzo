@testable import HanzoCore
import Foundation

final class MockLogger: LoggingServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _infoMessages: [String] = []
    private var _warnMessages: [String] = []
    private var _errorMessages: [String] = []

    var infoMessages: [String] {
        withLock { _infoMessages }
    }

    var warnMessages: [String] {
        withLock { _warnMessages }
    }

    var errorMessages: [String] {
        withLock { _errorMessages }
    }

    func info(_ message: String) {
        withLock { _infoMessages.append(message) }
    }

    func warn(_ message: String) {
        withLock { _warnMessages.append(message) }
    }

    func error(_ message: String) {
        withLock { _errorMessages.append(message) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
