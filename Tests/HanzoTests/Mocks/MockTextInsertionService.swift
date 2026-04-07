@testable import HanzoCore

final class MockTextInsertionService: TextInsertionProtocol {
    var insertedTexts: [String] = []
    var copiedTexts: [String] = []
    var returnSimulated = false
    var cmdReturnSimulated = false
    var insertResult: TextInsertionResult = .inserted
    var insertionDelayNanoseconds: UInt64 = 0
    var eventLog: [String] = []

    func insertText(_ text: String) async -> TextInsertionResult {
        eventLog.append("insert:start")
        insertedTexts.append(text)
        if insertionDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: insertionDelayNanoseconds)
        }
        eventLog.append("insert:end")
        return insertResult
    }

    func copyToClipboard(_ text: String) {
        copiedTexts.append(text)
    }

    func simulateReturn() {
        eventLog.append("submit:return")
        returnSimulated = true
    }

    func simulateCmdReturn() {
        eventLog.append("submit:cmd-return")
        cmdReturnSimulated = true
    }
}
