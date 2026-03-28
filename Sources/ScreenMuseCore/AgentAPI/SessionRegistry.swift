import Foundation

/// Manages multiple independent recording sessions.
/// The "default" session maps to ScreenMuseServer's existing singleton state.
/// Named sessions allow agents to run background recordings while doing other work.
///
/// Usage:
///   POST /start  { "session_id": "bg-1", "name": "background capture" }
///   POST /stop   { "session_id": "bg-1" }
///   GET  /sessions              — list all sessions
///   GET  /session/<id>          — get one session's state
///   DELETE /session/<id>        — remove a completed session from the registry

@MainActor
public final class SessionRegistry {

    /// Snapshot of a single recording session's metadata.
    public struct Session: Sendable {
        public let id: String
        public var name: String
        public var startTime: Date?
        public var isRecording: Bool = false
        public var videoURL: URL?
        public var chapters: [(name: String, time: TimeInterval)] = []
        public var notes: [(text: String, time: TimeInterval)] = []
        public var highlights: [TimeInterval] = []
        public var highlightNextClick: Bool = false

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        /// Dictionary representation for JSON responses.
        public func asDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "session_id": id,
                "name": name,
                "is_recording": isRecording
            ]
            if let st = startTime {
                dict["start_time"] = ISO8601DateFormatter().string(from: st)
                dict["elapsed"] = isRecording ? Date().timeIntervalSince(st) : -1
            }
            if let url = videoURL {
                dict["video_path"] = url.path
            }
            dict["chapters"] = chapters.map { ["name": $0.name, "time": $0.time] }
            dict["notes"] = notes.map { ["text": $0.text, "time": $0.time] }
            dict["highlights"] = highlights
            dict["chapter_count"] = chapters.count
            dict["note_count"] = notes.count
            return dict
        }
    }

    // MARK: - Storage

    /// All tracked sessions, keyed by session ID.
    private var sessions: [String: Session] = [:]

    /// The session ID currently designated as "active" (default session).
    /// When API calls omit session_id, this is the one they operate on.
    public var defaultSessionID: String?

    // MARK: - CRUD

    /// Create and register a new session. Returns the session.
    @discardableResult
    public func create(id: String, name: String) -> Session {
        var session = Session(id: id, name: name)
        session.startTime = Date()
        session.isRecording = true
        sessions[id] = session
        smLog.info("SessionRegistry: created session '\(id)' name='\(name)' (total: \(sessions.count))", category: .server)
        return session
    }

    /// Retrieve a session by ID.
    public func get(_ id: String) -> Session? {
        sessions[id]
    }

    /// Update a session in place.
    public func update(_ id: String, _ mutate: (inout Session) -> Void) {
        guard var session = sessions[id] else { return }
        mutate(&session)
        sessions[id] = session
    }

    /// Remove a session from the registry.
    @discardableResult
    public func remove(_ id: String) -> Session? {
        let removed = sessions.removeValue(forKey: id)
        if removed != nil {
            smLog.info("SessionRegistry: removed session '\(id)' (remaining: \(sessions.count))", category: .server)
        }
        return removed
    }

    /// List all sessions, optionally filtering by recording state.
    public func list(recordingOnly: Bool = false) -> [Session] {
        let all = Array(sessions.values)
        if recordingOnly {
            return all.filter(\.isRecording)
        }
        return all.sorted { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
    }

    /// Number of currently active (recording) sessions.
    public var activeCount: Int {
        sessions.values.filter(\.isRecording).count
    }

    /// Total session count.
    public var count: Int {
        sessions.count
    }

    /// Remove all completed (non-recording) sessions.
    public func pruneCompleted() {
        let completed = sessions.filter { !$0.value.isRecording }
        for id in completed.keys {
            sessions.removeValue(forKey: id)
        }
        if !completed.isEmpty {
            smLog.info("SessionRegistry: pruned \(completed.count) completed sessions", category: .server)
        }
    }
}
