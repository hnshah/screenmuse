import Foundation

/// Thread-safe job tracker for async endpoint execution.
///
/// Long-running endpoints (/export, /speedramp, /ocr, /annotate, /validate, /concat, /crop, /frames)
/// can accept `"async": true` to return immediately with a job ID. Poll GET /job/:id for status.
public actor JobQueue {
    public static let shared = JobQueue()

    public enum JobStatus: String, Codable, Sendable {
        case pending, running, completed, failed
    }

    // @unchecked Sendable: result stores [String: Any] which is not Sendable-safe,
    // but Job values only cross actor boundaries as immutable snapshots via get().
    public struct Job: @unchecked Sendable {
        public let id: String
        public let endpoint: String
        public let createdAt: Date
        public var status: JobStatus
        public var result: [String: Any]?
        public var error: String?
        public var completedAt: Date?

        // Sendable-safe dictionary representation
        public func asDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "id": id,
                "endpoint": endpoint,
                "status": status.rawValue,
                "created_at": ISO8601DateFormatter().string(from: createdAt)
            ]

            let elapsedMs: Int
            if let completed = completedAt {
                elapsedMs = Int(completed.timeIntervalSince(createdAt) * 1000)
            } else {
                elapsedMs = Int(Date().timeIntervalSince(createdAt) * 1000)
            }
            dict["elapsed_ms"] = elapsedMs

            if let completed = completedAt {
                dict["completed_at"] = ISO8601DateFormatter().string(from: completed)
            }
            if let result {
                dict["result"] = result
            }
            if let error {
                dict["error"] = error
            }
            return dict
        }
    }

    private var jobs: [String: Job] = [:]

    public func create(endpoint: String) -> String {
        let id = UUID().uuidString.lowercased().prefix(8).description
        jobs[id] = Job(id: id, endpoint: endpoint, createdAt: Date(), status: .pending)
        return id
    }

    public func setRunning(_ id: String) {
        jobs[id]?.status = .running
    }

    public func complete(_ id: String, result: [String: Any]) {
        jobs[id]?.status = .completed
        jobs[id]?.result = result
        jobs[id]?.completedAt = Date()
    }

    public func fail(_ id: String, error: String) {
        jobs[id]?.status = .failed
        jobs[id]?.error = error
        jobs[id]?.completedAt = Date()
    }

    public func get(_ id: String) -> Job? {
        jobs[id]
    }

    public func list() -> [Job] {
        jobs.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Remove completed/failed jobs older than the given interval (default 1 hour).
    public func cleanup(olderThan interval: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-interval)
        for (id, job) in jobs {
            if job.status == .completed || job.status == .failed,
               job.createdAt < cutoff {
                jobs.removeValue(forKey: id)
            }
        }
    }
}
