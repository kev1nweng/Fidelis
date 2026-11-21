import Foundation
import os

/// Logs to the unified log (subsystem dev.fidelis), keeps the last lines in memory for the UI's
/// diagnostics view, and, given a file, appends there too (the unified log keeps info and debug
/// lines only in memory, so a glitch could not be looked at afterwards). Thread-safe.
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

    private let file: LogFile?

    /// ~/Library/Logs/Fidelis/Fidelis.log
    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Fidelis/Fidelis.log")
    }

    public init(file: URL? = nil) { self.file = file.map(LogFile.init) }

    /// To the file only: per-second stream statistics.
    public func trace(_ s: String) { file?.append(Date(), "trace", s) }

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
        file?.append(line.date, level.rawValue, text)
        onLine?(line)
    }
}

/// Appends lines on its own queue; at 5 MB the file moves to Fidelis.1.log and a new one starts.
final class LogFile: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "fidelis.logfile", qos: .utility)
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private static let limit: UInt64 = 5 << 20
    private let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(_ url: URL) { self.url = url }

    func append(_ date: Date, _ level: String, _ text: String) {
        queue.async { [self] in
            guard let data = "\(format.string(from: date)) [\(level)] \(text)\n".data(using: .utf8) else { return }
            if handle == nil { open() }
            guard let handle else { return }
            handle.write(data)
            size += UInt64(data.count)
            if size >= Self.limit { rotate() }
        }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        open()
    }
}
