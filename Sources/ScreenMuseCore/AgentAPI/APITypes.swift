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

// MARK: - POST /trim

public struct TrimRequest: Codable, Sendable {
    /// Video path or "last" to use the most recent recording.
    public let source: String?
    /// Trim start time in seconds (default: 0 = beginning of video).
    public let start: Double?
    /// Trim end time in seconds (default: nil = end of video).
    public let end: Double?
    /// Force re-encode instead of stream copy (slower but accurate).
    public let reencode: Bool?
    /// Custom output path. Defaults to auto-generated path in Exports/.
    public let output: String?
}

// MARK: - POST /speedramp

public struct SpeedRampRequest: Codable, Sendable {
    /// Video path or "last" to use the most recent recording.
    public let source: String?
    /// Seconds of inactivity before a section is considered idle (default: 2.0).
    public let idleThresholdSec: Double?
    /// Playback speed for idle sections (default: 4.0, minimum: 1.0).
    public let idleSpeed: Double?
    /// Playback speed for active sections (default: 1.0, minimum: 0.1).
    public let activeSpeed: Double?
    /// Custom output path. Defaults to auto-generated path in Exports/.
    public let output: String?

    enum CodingKeys: String, CodingKey {
        case source
        case idleThresholdSec = "idle_threshold_sec"
        case idleSpeed = "idle_speed"
        case activeSpeed = "active_speed"
        case output
    }
}

// MARK: - POST /chapter

public struct ChapterRequest: Codable, Sendable {
    /// Chapter name/label (default: "Chapter").
    public let name: String?
}

// MARK: - POST /highlight

/// POST /highlight takes no required fields — no Codable request type needed.
/// The handler flags the next click for enhanced visual effects.
public struct HighlightResponse: Codable, Sendable {
    public let ok: Bool
    /// Recording elapsed time when the highlight flag was set.
    public let timestamp: Double
}

// MARK: - POST /note

public struct NoteRequest: Codable, Sendable {
    /// The text to add as a session note. Required.
    public let text: String?
    /// Alias for text (backward compatibility).
    public let note: String?
}

// MARK: - POST /qa

public struct QARequest: Codable, Sendable {
    /// Absolute path to the original (pre-processing) video.
    public let original: String
    /// Absolute path to the processed (output) video.
    public let processed: String
    /// Whether to save the qa-report.json beside the processed video. Default: true.
    public let save: Bool?
}

// MARK: - POST /diff

public struct DiffRequest: Codable, Sendable {
    /// Absolute path to video A.
    public let a: String
    /// Absolute path to video B.
    public let b: String
}

public struct DiffResponse: Codable, Sendable {
    public struct VideoInfo: Codable, Sendable {
        public let path: String
        public let duration: Double
        public let fileSizeBytes: Int64
        public let fileSizeMB: Double
        public let width: Int
        public let height: Int
        public let fps: Double
        public let bitrateBPS: Int64
        public let codec: String
        public let hasAudio: Bool

        enum CodingKeys: String, CodingKey {
            case path, duration
            case fileSizeBytes = "file_size_bytes"
            case fileSizeMB = "file_size_mb"
            case width, height, fps
            case bitrateBPS = "bitrate_bps"
            case codec
            case hasAudio = "has_audio"
        }
    }

    public struct Delta: Codable, Sendable {
        public let durationSeconds: Double
        public let durationPercent: Double
        public let fileSizeBytes: Int64
        public let fileSizePercent: Double
        public let bitrateBPS: Int64
        public let resolutionChanged: Bool
        public let fpsChanged: Bool
        public let codecChanged: Bool

        enum CodingKeys: String, CodingKey {
            case durationSeconds = "duration_seconds"
            case durationPercent = "duration_percent"
            case fileSizeBytes = "file_size_bytes"
            case fileSizePercent = "file_size_percent"
            case bitrateBPS = "bitrate_bps"
            case resolutionChanged = "resolution_changed"
            case fpsChanged = "fps_changed"
            case codecChanged = "codec_changed"
        }
    }

    public let a: VideoInfo
    public let b: VideoInfo
    public let delta: Delta
    public let requestID: Int?

    enum CodingKeys: String, CodingKey {
        case a, b, delta
        case requestID = "request_id"
    }
}
