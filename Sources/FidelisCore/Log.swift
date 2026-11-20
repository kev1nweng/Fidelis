import Foundation
import os

/// Logs to the unified log (subsystem dev.fidelis) and keeps the last lines in memory for the UI's
/// diagnostics view. Thread-safe.
public final class Log: @unchecked Sendable {
    public enum Level: String, Sendable { case debug, info, warn, error }
    public struct Line: Identifiable, Sendable {
        public let id: Int
        public let date: Date
        public let level: Level
        public let text: String
    }

    private let logger = Logger(subsystem: "dev.fidelis", category: "engine")
    private let lock = NSLock()
    private var lines: [Line] = []
    private var counter = 0
    private let capacity = 500
    /// Called (on an arbitrary thread) for each new line.
    public var onLine: (@Sendable (Line) -> Void)?

    public init() {}

    public func debug(_ s: String) { add(.debug, s) }
    public func info(_ s: String) { add(.info, s) }
    public func warn(_ s: String) { add(.warn, s) }
    public func error(_ s: String) { add(.error, s) }

    public var recent: [Line] { lock.withLock { lines } }

    private func add(_ level: Level, _ text: String) {
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .warn: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        let line: Line = lock.withLock {
            counter += 1
            let l = Line(id: counter, date: Date(), level: level, text: text)
            lines.append(l)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
            return l
        }
        if ProcessInfo.processInfo.environment["FIDELIS_STDERR_LOG"] != nil {
            FileHandle.standardError.write("[\(level.rawValue)] \(text)\n".data(using: .utf8)!)
        }
        onLine?(line)
    }
}
