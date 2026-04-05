import Foundation

// MARK: - FFProbe Metadata Extractor

/// Extracts video metadata using ffprobe.
///
/// Uses the JSON output format for reliable parsing.
public struct FFProbeExtractor: Sendable {

    public init() {}

    // Prefer bundled binary; fall back to Homebrew path
    public static let ffprobePath: String = {
        let candidates = [
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("ffprobe")
                .path ?? "",
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/opt/homebrew/bin/ffprobe"
    }()

    // MARK: - Public API

    /// Extract metadata from a video file using ffprobe.
    ///
    /// - Parameter url: Path to the video file.
    /// - Returns: `VideoMetadata` with all extracted fields.
    /// - Throws: `QAError` on failure.
    public func extract(from url: URL) throws -> VideoMetadata {
        let path = url.path

        // Verify file exists
        guard FileManager.default.fileExists(atPath: path) else {
            throw QAError.fileNotFound(path)
        }

        // Get file size from filesystem (faster than ffprobe)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        // Run ffprobe with JSON output
        let json = try runFFProbe(path: path)

        return try parse(json: json, path: path, fileSize: fileSize)
    }

    // MARK: - Private helpers

    private func runFFProbe(path: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FFProbeExtractor.ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw QAError.ffprobeUnavailable(FFProbeExtractor.ffprobePath)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw QAError.corruptedFile(path)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw QAError.parseError("Empty or invalid ffprobe output for \(path)")
        }
        return json
    }

    private func parse(json: [String: Any], path: String, fileSize: Int64) throws -> VideoMetadata {
        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any] ?? [:]

        // Extract duration
        let durationStr = (format["duration"] as? String)
            ?? streams.first(where: { $0["codec_type"] as? String == "video" })?["duration"] as? String
            ?? "0"
        let duration = Double(durationStr) ?? 0.0

        // Bitrate
        let bitrateStr = format["bit_rate"] as? String ?? "0"
        let bitrate = Int64(bitrateStr) ?? 0

        // Find video stream
        guard let videoStream = streams.first(where: { $0["codec_type"] as? String == "video" }) else {
            throw QAError.noVideoStream(path)
        }

        let width = videoStream["width"] as? Int ?? 0
        let height = videoStream["height"] as? Int ?? 0
        let codec = videoStream["codec_name"] as? String ?? "unknown"

        // FPS: stored as "num/den" rational string in r_frame_rate
        let fpsStr = videoStream["r_frame_rate"] as? String ?? "0/1"
        let fps = parseRationalFPS(fpsStr)

        // Audio
        let audioStream = streams.first(where: { $0["codec_type"] as? String == "audio" })
        let hasAudio = audioStream != nil
        let audioCodec = audioStream?["codec_name"] as? String

        return VideoMetadata(
            path: path,
            duration: duration,
            fileSizeBytes: fileSize,
            width: width,
            height: height,
            fps: fps,
            bitrateBPS: bitrate,
            codec: codec,
            hasAudio: hasAudio,
            audioCodec: audioCodec
        )
    }

    /// Parse "30000/1001" → 29.97, "60/1" → 60.0
    internal func parseRationalFPS(_ rational: String) -> Double {
        let parts = rational.split(separator: "/")
        guard parts.count == 2,
              let num = Double(parts[0]),
              let den = Double(parts[1]),
              den > 0
        else { return 0 }
        return num / den
    }

    // MARK: - File validity check (fast path)

    /// Returns true if ffprobe can open and read the file without errors.
    public func isValid(url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FFProbeExtractor.ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_format", "-show_streams",
            url.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - QA Errors

public enum QAError: Error, LocalizedError {
    case fileNotFound(String)
    case corruptedFile(String)
    case noVideoStream(String)
    case ffprobeUnavailable(String)
    case parseError(String)
    case analysisTimeout

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "File not found: \(p)"
        case .corruptedFile(let p): return "Corrupted or unplayable file: \(p)"
        case .noVideoStream(let p): return "No video stream found in: \(p)"
        case .ffprobeUnavailable(let p): return "ffprobe not available at: \(p)"
        case .parseError(let m): return "Parse error: \(m)"
        case .analysisTimeout: return "QA analysis timed out"
        }
    }
}
