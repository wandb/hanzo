import Foundation

protocol LocalASRRuntimeManagerProtocol {
    func ensureRunning() async throws
    func prepareModel() async throws
    func stop() async
}
