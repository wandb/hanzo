@testable import HanzoCore

final class MockTextInsertionService: TextInsertionProtocol {
    var insertedTexts: [String] = []
    var copiedTexts: [String] = []
    var returnSimulated = false
    var cmdReturnSimulated = false

    func insertText(_ text: String) {
        insertedTexts.append(text)
    }

    func copyToClipboard(_ text: String) {
        copiedTexts.append(text)
    }

    func simulateReturn() {
        returnSimulated = true
    }

    func simulateCmdReturn() {
        cmdReturnSimulated = true
    }
}
