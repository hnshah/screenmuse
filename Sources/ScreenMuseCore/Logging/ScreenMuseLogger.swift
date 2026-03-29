import os
import Foundation

/// Centralised logging for ScreenMuse.
///
/// Three sinks per log call:
///   1. os.Logger  → visible in Console.app (filter by subsystem "ai.screenmuse")
///   2. File       → ~/Movies/ScreenMuse/Logs/screenmuse-YYYY-MM-DD.log
///   3. Ring buf   → last 1000 entries, served via GET /logs
///
/// Usage:
///   smLog.info("Server started", category: .server)
///   smLog.error("Write failed: \(err)", category: .recording)
public final class ScreenMuseLogger: @unchecked Sendable {

    // MARK: - Singleton
    public static let shared = ScreenMuseLogger()

    // MARK: - Types

    public enum Level: String, Sendable, CaseIterable {
        case debug, info, warning, error

        var emoji: String {
            switch self {
            case .debug:   return "🔍"
            case .info:    return "ℹ️"
            case .warning: return "⚠️"
            case .error:   return "❌"
            }
        }

        var padded: String {
            rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
        }
    }

    public enum Category: String, Sendable, CaseIterable {
        case lifecycle    // app start/stop, permissions boot
        case server       // HTTP API requests & responses
        case recording    // SCStream, AVAssetWriter, frames
        case effects      // compositing, Metal, CoreImage
        case capture      // screenshots, window enumeration
        case permissions  // TCC, entitlements
        case general      // catch-all
    }

    public struct Entry: Sendable {
        public let id: Int
        public let timestamp: Date
        public let level: Level
        public let category: Category
        public let message: String

        var formatted: String {
            "\(isoTimestamp) [\(level.padded)] [\(category.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0))] \(message)"
        }

        private var isoTimestamp: String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate, .withTime, .withFractionalSeconds, .withColonSeparatorInTime]
            return f.string(from: timestamp)
        }

        public func asDictionary() -> [String: String] {
            [
                "id": "\(id)",
                "timestamp": isoTimestamp,
                "level": level.rawValue,
                "category": category.rawValue,
                "message": message
            ]
        }
    }

    // MARK: - Private state

    private let subsystem = "ai.screenmuse"
    private var osLoggers: [Category: os.Logger] = [:]

    private let lock = NSLock()
    private var buffer: [Entry] = []
    private let maxEntries = 1000
    private var nextID = 0

    private var logFileURL: URL?
    private var fileHandle: FileHandle?

    // MARK: - Init

    private init() {
        // Pre-create os.Logger per category
        for cat in Category.allCases {
            osLoggers[cat] = os.Logger(subsystem: subsystem, category: cat.rawValue)
        }
        setupLogFile()
        setupUsageLog()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        info("=== ScreenMuse \(version) logger initialised ===", category: .lifecycle)
        info("Log file: \(logFilePath)", category: .lifecycle)
        info("Usage log: \(usageLogFilePath)", category: .lifecycle)
        info("Console.app filter: subsystem == \"ai.screenmuse\"", category: .lifecycle)
    }

    // MARK: - File setup

    private func setupLogFile() {
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let dir = moviesURL.appendingPathComponent("ScreenMuse/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let fileName = "screenmuse-\(df.string(from: Date())).log"
        let url = dir.appendingPathComponent(fileName)
        logFileURL = url

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    // MARK: - Core log method

    public func log(_ message: String, level: Level = .info, category: Category = .general) {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()

        let entry = Entry(id: id, timestamp: Date(), level: level, category: category, message: message)

        // 1. os.Logger
        let osLog = osLoggers[category] ?? os.Logger(subsystem: subsystem, category: category.rawValue)
        let msg = "\(entry.level.emoji) \(message)"
        switch level {
        case .debug:   osLog.debug("\(msg, privacy: .public)")
        case .info:    osLog.info("\(msg, privacy: .public)")
        case .warning: osLog.warning("\(msg, privacy: .public)")
        case .error:   osLog.error("\(msg, privacy: .public)")
        }

        // 2. stdout (Xcode / dev-run.sh)
        print(entry.formatted)

        // 3. File
        let line = entry.formatted + "\n"
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }

        // 4. Ring buffer
        lock.lock()
        buffer.append(entry)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
        lock.unlock()
    }

    // MARK: - Convenience

    public func debug(_ message: String, category: Category = .general) {
        log(message, level: .debug, category: category)
    }
    public func info(_ message: String, category: Category = .general) {
        log(message, level: .info, category: category)
    }
    public func warning(_ message: String, category: Category = .general) {
        log(message, level: .warning, category: category)
    }
    public func error(_ message: String, category: Category = .general) {
        log(message, level: .error, category: category)
    }

    // MARK: - Query

    /// Returns last `limit` entries, optionally filtered by category and/or minimum level.
    public func recentEntries(
        limit: Int = 200,
        category: Category? = nil,
        minLevel: Level = .debug
    ) -> [[String: String]] {
        let levelRank: [Level: Int] = [.debug: 0, .info: 1, .warning: 2, .error: 3]
        let minRank = levelRank[minLevel] ?? 0

        lock.lock()
        defer { lock.unlock() }
        return buffer
            .filter { (category == nil || $0.category == category) && (levelRank[$0.level] ?? 0) >= minRank }
            .suffix(limit)
            .map { $0.asDictionary() }
    }

    /// Full path to today's log file.
    public var logFilePath: String { logFileURL?.path ?? "(not set)" }

    /// Full path to the clean usage log file.
    public var usageLogFilePath: String { usageFileURL?.path ?? "(not set)" }

    /// Number of entries in ring buffer.
    public var bufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    // MARK: - Clean Usage Log

    /// Separate file handle for the human-readable usage log.
    /// Only key events are written here — one line per action.
    private var usageFileURL: URL?
    private var usageFileHandle: FileHandle?

    private func setupUsageLog() {
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let dir = moviesURL.appendingPathComponent("ScreenMuse/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("screenmuse-usage-\(df.string(from: Date())).log")
        usageFileURL = url

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        usageFileHandle = try? FileHandle(forWritingTo: url)
        usageFileHandle?.seekToEndOfFile()
    }

    /// Write a clean, human-readable usage event.
    /// These are the events Vera attaches to bug reports — keep them concise and plain English.
    public func usage(_ event: String, details: [String: String] = [:]) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts = df.string(from: Date())

        var line = "[\(ts)] \(event)"
        if !details.isEmpty {
            let detailStr = details.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
            line += "  |\t\(detailStr)"
        }
        line += "\n"

        // Write to usage file
        if let data = line.data(using: .utf8) {
            usageFileHandle?.write(data)
        }

        // Also write to ring buffer as info (so GET /logs includes it)
        log("USAGE: \(event)\(details.isEmpty ? "" : " — " + details.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))",
            level: .info, category: .lifecycle)

        // Buffer usage events separately for GET /report
        lock.lock()
        usageBuffer.append(UsageEvent(timestamp: Date(), event: event, details: details))
        if usageBuffer.count > 200 {
            usageBuffer.removeFirst(usageBuffer.count - 200)
        }
        lock.unlock()
    }

    // MARK: - Usage event buffer

    public struct UsageEvent: Sendable {
        public let timestamp: Date
        public let event: String
        public let details: [String: String]

        func formatted() -> String {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            let ts = df.string(from: timestamp)
            var line = "[\(ts)] \(event)"
            if !details.isEmpty {
                let detailStr = details.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
                line += "\t| \(detailStr)"
            }
            return line
        }

        func asDictionary() -> [String: Any] {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate, .withTime, .withFractionalSeconds, .withColonSeparatorInTime]
            var d: [String: Any] = [
                "timestamp": f.string(from: timestamp),
                "event": event
            ]
            if !details.isEmpty { d["details"] = details }
            return d
        }
    }

    private var usageBuffer: [UsageEvent] = []

    public func recentUsageEvents(limit: Int = 100) -> [UsageEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(usageBuffer.suffix(limit))
    }
}

// MARK: - Global shorthand

/// Global shorthand so any file can call `smLog.info(...)` without an import dance.
/// nonisolated(unsafe) is required for Swift 6: ScreenMuseLogger is @unchecked Sendable
/// and internally synchronised with NSLock, so cross-actor access is safe.
public let smLog = ScreenMuseLogger.shared
