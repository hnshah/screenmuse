import Foundation

// MARK: - Video Metadata

/// Metadata extracted from a video file via ffprobe.
public struct VideoMetadata: Codable, Sendable {
    public let path: String
    public let duration: Double          // seconds
    public let fileSizeBytes: Int64
    public var fileSizeMB: Double { Double(fileSizeBytes) / 1_048_576 }
    public let width: Int
    public let height: Int
    public let fps: Double
    public let bitrateBPS: Int64
    public var bitrateMBPS: Double { Double(bitrateBPS) / 1_000_000 }
    public let codec: String
    public let hasAudio: Bool
    public let audioCodec: String?

    enum CodingKeys: String, CodingKey {
        case path
        case duration
        case fileSizeBytes = "file_size_bytes"
        case fileSizeMB = "file_size_mb"
        case width
        case height
        case fps
        case bitrateBPS = "bitrate_bps"
        case bitrateMBPS = "bitrate_mbps"
        case codec
        case hasAudio = "has_audio"
        case audioCodec = "audio_codec"
    }

    public init(
        path: String,
        duration: Double,
        fileSizeBytes: Int64,
        width: Int,
        height: Int,
        fps: Double,
        bitrateBPS: Int64,
        codec: String,
        hasAudio: Bool,
        audioCodec: String?
    ) {
        self.path = path
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateBPS = bitrateBPS
        self.codec = codec
        self.hasAudio = hasAudio
        self.audioCodec = audioCodec
    }
}

// MARK: - Quality Check

/// Severity levels for quality check failures.
public enum QACheckSeverity: String, Codable, Sendable {
    case critical
    case high
    case medium
    case low
}

/// Result of a single quality check.
public struct QualityCheck: Codable, Sendable {
    public let id: String
    public let name: String
    public let passed: Bool
    public let isWarning: Bool      // true = warning (passed but flagged), false = hard pass/fail
    public let severity: QACheckSeverity
    public let message: String

    enum CodingKeys: String, CodingKey {
        case id, name, passed
        case isWarning = "is_warning"
        case severity, message
    }

    public init(
        id: String,
        name: String,
        passed: Bool,
        isWarning: Bool = false,
        severity: QACheckSeverity,
        message: String
    ) {
        self.id = id
        self.name = name
        self.passed = passed
        self.isWarning = isWarning
        self.severity = severity
        self.message = message
    }
}

// MARK: - QA Report

/// Changes between original and processed video.
public struct QAChanges: Codable, Sendable {
    public let durationChangeSeconds: Double
    public let durationChangePercent: Double
    public let fileSizeChangeBytes: Int64
    public let fileSizeChangePercent: Double
    public let bitrateChangeBPS: Int64
    public let bitrateChangePercent: Double

    enum CodingKeys: String, CodingKey {
        case durationChangeSeconds = "duration_change_seconds"
        case durationChangePercent = "duration_change_percent"
        case fileSizeChangeBytes = "file_size_change_bytes"
        case fileSizeChangePercent = "file_size_change_percent"
        case bitrateChangeBPS = "bitrate_change_bps"
        case bitrateChangePercent = "bitrate_change_percent"
    }
}

/// Summary of QA analysis.
public struct QASummary: Codable, Sendable {
    public let totalChecks: Int
    public let passed: Int
    public let failed: Int
    public let warnings: Int
    public let overallStatus: String   // "passed", "warning", "failed"
    public let confidenceScore: Double // 0.0–1.0

    enum CodingKeys: String, CodingKey {
        case totalChecks = "total_checks"
        case passed, failed, warnings
        case overallStatus = "overall_status"
        case confidenceScore = "confidence_score"
    }
}

/// Full QA report produced after video processing.
public struct QAReport: Codable, Sendable {
    public let version: String
    public let timestamp: Date
    public let videos: QAVideos
    public let qualityChecks: [QualityCheck]
    public let summary: QASummary
    public let changes: QAChanges

    enum CodingKeys: String, CodingKey {
        case version, timestamp
        case videos
        case qualityChecks = "quality_checks"
        case summary, changes
    }

    public init(
        timestamp: Date = Date(),
        videos: QAVideos,
        qualityChecks: [QualityCheck],
        summary: QASummary,
        changes: QAChanges
    ) {
        self.version = "1.0"
        self.timestamp = timestamp
        self.videos = videos
        self.qualityChecks = qualityChecks
        self.summary = summary
        self.changes = changes
    }
}

/// Container for original + processed video metadata.
public struct QAVideos: Codable, Sendable {
    public let original: VideoMetadata
    public let processed: VideoMetadata

    public init(original: VideoMetadata, processed: VideoMetadata) {
        self.original = original
        self.processed = processed
    }
}
