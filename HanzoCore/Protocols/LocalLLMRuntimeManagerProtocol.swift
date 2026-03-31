import Foundation

protocol LocalLLMRuntimeManagerProtocol {
    func ensureRunning() async throws
    func prepareModel() async throws
    func postProcess(text: String, prompt: String, targetApp: String?, commonTerms: [String]) async throws -> String
    func stop() async
}
