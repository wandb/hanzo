import Foundation

protocol LocalASRRuntimeManagerProtocol {
    func ensureRunning(baseURL: String) async throws
    func stop() async
}
