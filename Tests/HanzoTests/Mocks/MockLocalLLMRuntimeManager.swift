import Foundation
@testable import HanzoCore

final class MockLocalLLMRuntimeManager: LocalLLMRuntimeManagerProtocol {
    var ensureRunningCallCount = 0
    var prepareModelCallCount = 0
    var stopCallCount = 0
    var postProcessCallCount = 0

    var lastInputText: String?
    var lastPrompt: String?

    var ensureRunningError: Error?
    var prepareModelError: Error?
    var postProcessResult: Result<String, Error> = .success("")
    var postProcessDelayNanoseconds: UInt64?

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

    func postProcess(text: String, prompt: String) async throws -> String {
        postProcessCallCount += 1
        lastInputText = text
        lastPrompt = prompt
        if let postProcessDelayNanoseconds {
            try await Task.sleep(nanoseconds: postProcessDelayNanoseconds)
        }
        return try postProcessResult.get()
    }

    func stop() async {
        stopCallCount += 1
    }
}
