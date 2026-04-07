protocol TextInsertionProtocol {
    func insertText(_ text: String) async -> TextInsertionResult
    func copyToClipboard(_ text: String)
    func simulateReturn()
    func simulateCmdReturn()
}
