import Foundation
@testable import HanzoCore

final class MockLocalASRRuntimeManager: LocalASRRuntimeManagerProtocol {
    var ensureRunningCallCount = 0
    var prepareModelCallCount = 0
    var stopCallCount = 0

    var ensureRunningError: Error?
    var prepareModelError: Error?

    func ensureRunning() async throws {
        ensureRunningCallCount += 1
        if let ensureRunningError {
            throw ensureRunningError
        }
    }

    func prepareModel() async throws {
        prepareModelCallCount += 1
        if let prepareModelError {
            throw prepareModelError
        }
    }

    func stop() async {
        stopCallCount += 1
    }
}
