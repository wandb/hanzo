import Foundation

extension Task where Success == Void, Failure == Never {
    // Use for fire-and-forget async work that can throw. Any error is logged
    // instead of being silently dropped on the floor. Prefer an inline
    // do/catch when the call site needs a specific log level or bespoke
    // recovery; use this when "log it and move on" is the right answer.
    @discardableResult
    static func launched(
        name: String,
        logger: LoggingServiceProtocol,
        operation: @Sendable @escaping () async throws -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                try await operation()
            } catch {
                logger.error("[\(name)] fire-and-forget task failed: \(error)")
            }
        }
    }
}
