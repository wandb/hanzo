import Foundation

// Sendable is unchecked because `fileHandle` is mutable but every read/write is
// serialized through `queue`. Keep info/warn/error synchronous so they can be
// called from sync contexts (audio tap callbacks, HotKey handlers, deinit).
final class LoggingService: LoggingServiceProtocol, @unchecked Sendable {
    static let shared = LoggingService()

    private let queue = DispatchQueue(label: "com.hanzo.logging")
    private let logURL: URL
    private var fileHandle: FileHandle?

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        logURL = logsDir.appendingPathComponent(Constants.logFileName)

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
    }

    func info(_ message: String) { log("INFO", message) }
    func warn(_ message: String) { log("WARN", message) }
    func error(_ message: String) { log("ERROR", message) }

    private func log(_ level: String, _ message: String) {
        queue.async { [self] in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: Date())
            let line = "[\(timestamp)] [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            fileHandle?.write(data)

            rotateIfNeeded()
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > UInt64(Constants.maxLogFileSizeMB * 1024 * 1024) else { return }

        fileHandle?.closeFile()
        let backupURL = logURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: logURL, to: backupURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logURL)
    }
}
