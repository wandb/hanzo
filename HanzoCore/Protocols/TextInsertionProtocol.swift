protocol TextInsertionProtocol {
    func insertText(_ text: String) async
    func copyToClipboard(_ text: String)
    func simulateReturn()
    func simulateCmdReturn()
}
