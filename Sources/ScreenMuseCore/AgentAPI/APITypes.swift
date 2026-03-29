import Foundation

// MARK: - Codable request/response types for the top 5 API endpoints
//
// These types document the exact JSON contract between clients and the server.
// They can be used for request decoding, response encoding, OpenAPI generation,
// and TypeScript client codegen.

// MARK: - POST /start

public struct StartRequest: Codable, Sendable {
    public let name: String?
    public let windowTitle: String?
    public let windowPid: Int?
    public let quality: String?
    public let audioSource: String?
    public let region: RegionRequest?
    public let webhook: String?

    enum CodingKeys: String, CodingKey {
        case name
        case windowTitle = "window_title"
        case windowPid = "window_pid"
        case quality
        case audioSource = "audio_source"
        case region
        case webhook
    }
}

public struct RegionRequest: Codable, Sendable {
    public let x: Double?
    public let y: Double?
    public let width: Double
    public let height: Double
}

public struct StartResponse: Codable, Sendable {
    public let sessionId: String
    public let status: String
    public let name: String
    public let quality: String
    public let windowTitle: String?
    public let windowPid: Int?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case status, name, quality
        case windowTitle = "window_title"
        case windowPid = "window_pid"
    }
}

// MARK: - POST /stop

public struct StopResponse: Codable, Sendable {
    public let path: String
    public let videoPath: String
    public let duration: Double
    public let size: Int
    public let sizeMb: Double
    public let sessionId: String
    public let chapters: [ChapterEntry]
    public let notes: [NoteEntry]
    public let resolution: Resolution?
    public let fps: Double?
    public let window: WindowInfoResponse?

    enum CodingKeys: String, CodingKey {
        case path
        case videoPath = "video_path"
        case duration, size
        case sizeMb = "size_mb"
        case sessionId = "session_id"
        case chapters, notes, resolution, fps, window
    }
}

public struct ChapterEntry: Codable, Sendable {
    public let name: String
    public let time: Double
}

public struct NoteEntry: Codable, Sendable {
    public let text: String
    public let time: Double
}

public struct Resolution: Codable, Sendable {
    public let width: Int
    public let height: Int
}

/// JSON representation of window info in API responses (distinct from WindowManager.WindowInfo).
public struct WindowInfoResponse: Codable, Sendable {
    public let app: String?
    public let pid: Int?
    public let title: String?
}

// MARK: - GET /status

public struct StatusResponse: Codable, Sendable {
    public let recording: Bool
    public let elapsed: Double
    public let sessionId: String
    public let chapters: [ChapterEntry]
    public let lastVideo: String
    public let sessionsActive: Int
    public let sessionsTotal: Int

    enum CodingKeys: String, CodingKey {
        case recording, elapsed
        case sessionId = "session_id"
        case chapters
        case lastVideo = "last_video"
        case sessionsActive = "sessions_active"
        case sessionsTotal = "sessions_total"
    }
}

// MARK: - POST /export

public struct ExportRequest: Codable, Sendable {
    public let format: String?
    public let source: String?
    public let fps: Int?
    public let scale: Int?
    public let quality: String?
    public let startTime: Double?
    public let endTime: Double?
    public let outputPath: String?

    enum CodingKeys: String, CodingKey {
        case format, source, fps, scale, quality
        case startTime = "start_time"
        case endTime = "end_time"
        case outputPath = "output_path"
    }
}

public struct ExportResponse: Codable, Sendable {
    public let path: String
    public let format: String
    public let width: Int
    public let height: Int
    public let frames: Int
    public let fps: Double
    public let duration: Double
    public let size: Int
    public let sizeMb: Double

    enum CodingKeys: String, CodingKey {
        case path, format, width, height, frames, fps, duration, size
        case sizeMb = "size_mb"
    }
}

// MARK: - POST /record (convenience)

public struct RecordRequest: Codable, Sendable {
    public let durationSeconds: Double?
    public let duration: Double?
    public let name: String?
    public let quality: String?
    public let windowTitle: String?
    public let windowPid: Int?
    public let region: RegionRequest?

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case duration, name, quality
        case windowTitle = "window_title"
        case windowPid = "window_pid"
        case region
    }
}

// POST /record uses the same StopResponse type

// MARK: - GET /health

public struct HealthResponse: Codable, Sendable {
    public let ok: Bool
    public let version: String
    public let listener: String
    public let port: Int
    public let activeConnections: Int
    public let permissions: PermissionsInfo
    public let warning: String?

    enum CodingKeys: String, CodingKey {
        case ok, version, listener, port
        case activeConnections = "active_connections"
        case permissions, warning
    }
}

public struct PermissionsInfo: Codable, Sendable {
    public let screenRecording: Bool

    enum CodingKeys: String, CodingKey {
        case screenRecording = "screen_recording"
    }
}
