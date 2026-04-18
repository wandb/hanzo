import Testing
import Foundation
@testable import HanzoCore

/// Tests the fire-and-forget `Task.launched` helper. Fire-and-forget code
/// previously silently dropped errors on the floor — this helper guarantees
/// they reach the logger instead.
@Suite("TaskLaunched")
struct TaskLaunchedTests {

    private struct SampleError: Error, Equatable {
        let tag: String
    }

    @Test("Successful operation does not log an error")
    func successfulOperationLogsNothing() async {
        let logger = MockLogger()
        let task = Task.launched(name: "prewarm", logger: logger) {
            // succeeds
        }
        await task.value

        #expect(logger.errorMessages.isEmpty)
        #expect(logger.warnMessages.isEmpty)
    }

    @Test("Thrown error is captured with the task name in the error log")
    func thrownErrorIsLogged() async {
        let logger = MockLogger()
        let task = Task.launched(name: "prewarm", logger: logger) {
            throw SampleError(tag: "boom")
        }
        await task.value

        #expect(logger.errorMessages.count == 1)
        let logged = logger.errorMessages.first ?? ""
        #expect(logged.contains("[prewarm]"))
        #expect(logged.contains("boom"))
    }
}
