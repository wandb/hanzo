@testable import HanzoCore

final class MockLogger: LoggingServiceProtocol {
    var infoMessages: [String] = []
    var warnMessages: [String] = []
    var errorMessages: [String] = []

    func info(_ message: String) { infoMessages.append(message) }
    func warn(_ message: String) { warnMessages.append(message) }
    func error(_ message: String) { errorMessages.append(message) }
}
