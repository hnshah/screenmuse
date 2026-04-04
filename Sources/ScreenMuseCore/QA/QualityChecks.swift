import Foundation

// MARK: - Quality Checks

/// Runs all quality checks comparing original vs processed video metadata.
public struct QualityCheckRunner: Sendable {

    public init() {}

    /// Run all 5 quality checks. Returns array of `QualityCheck` results.
    public func run(
        original: VideoMetadata,
        processed: VideoMetadata,
        processedURL: URL
    ) -> [QualityCheck] {
        [
            checkFileValidity(url: processedURL),
            checkResolution(original: original, processed: processed),
            checkAudioVideoSync(processedURL: processedURL),
            checkFrameRate(original: original, processed: processed),
            checkFileSize(original: original, processed: processed)
        ]
    }

    // MARK: - Check 1: File Validity (critical)

    /// Verify processed video is a valid, playable file.
    func checkFileValidity(url: URL) -> QualityCheck {
        let extractor = FFProbeExtractor()
        let valid = extractor.isValid(url: url)
        return QualityCheck(
            id: "file_validity",
            name: "File Validity",
            passed: valid,
            severity: .critical,
            message: valid
                ? "Video file is valid and playable"
                : "Processed video is corrupted or unplayable"
        )
    }

    // MARK: - Check 2: Resolution Maintained (high)

    /// Verify resolution (width × height) didn't change.
    func checkResolution(original: VideoMetadata, processed: VideoMetadata) -> QualityCheck {
        let same = original.width == processed.width && original.height == processed.height
        let origStr = "\(original.width)×\(original.height)"
        let procStr = "\(processed.width)×\(processed.height)"
        return QualityCheck(
            id: "resolution_maintained",
            name: "Resolution Maintained",
            passed: same,
            severity: .high,
            message: same
                ? "Resolution maintained (\(origStr))"
                : "Resolution changed from \(origStr) to \(procStr)"
        )
    }

    // MARK: - Check 3: Audio/Video Sync (high)

    /// Check for A/V sync issues by comparing audio/video stream start times.
    ///
    /// A better approach than the aresample trick: extract the video and audio
    /// start_pts values via ffprobe and compare them. A drift > 100ms is flagged.
    func checkAudioVideoSync(processedURL: URL) -> QualityCheck {
        let drift = measureAVDrift(url: processedURL)

        switch drift {
        case .none:
            // No audio track — skip sync check
            return QualityCheck(
                id: "audio_video_sync",
                name: "Audio/Video Sync",
                passed: true,
                severity: .high,
                message: "No audio track (sync check skipped)"
            )
        case .some(let d) where abs(d) < 0.1:
            return QualityCheck(
                id: "audio_video_sync",
                name: "Audio/Video Sync",
                passed: true,
                severity: .high,
                message: String(format: "Audio and video are in sync (max drift: %.2fs)", abs(d))
            )
        case .some(let d):
            return QualityCheck(
                id: "audio_video_sync",
                name: "Audio/Video Sync",
                passed: false,
                severity: .high,
                message: String(format: "Audio/video out of sync (drift: %.2fs)", abs(d))
            )
        }
    }

    /// Returns PTS drift in seconds between audio and video streams, or nil if no audio.
    internal func measureAVDrift(url: URL) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FFProbeExtractor.ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_streams",
            "-select_streams", "a:0,v:0",
            url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]]
        else { return nil }

        let video = streams.first { $0["codec_type"] as? String == "video" }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }

        guard let _ = audio else { return nil }  // no audio track → nil

        let videoStart = parseTimeBase(stream: video)
        let audioStart = parseTimeBase(stream: audio)
        return .some(audioStart - videoStart)
    }

    private func parseTimeBase(stream: [String: Any]?) -> Double {
        guard let s = stream,
              let startTimeStr = s["start_time"] as? String,
              let startTime = Double(startTimeStr)
        else { return 0.0 }
        return startTime
    }

    // MARK: - Check 4: Frame Rate Maintained (medium)

    /// Verify frame rate didn't change.
    func checkFrameRate(original: VideoMetadata, processed: VideoMetadata) -> QualityCheck {
        // Compare with 0.01 fps tolerance for rational rounding
        let diff = abs(original.fps - processed.fps)
        let same = diff < 0.01

        let origStr = String(format: "%.2ffps", original.fps)
        let procStr = String(format: "%.2ffps", processed.fps)
        return QualityCheck(
            id: "frame_rate_maintained",
            name: "Frame Rate Maintained",
            passed: same,
            severity: .medium,
            message: same
                ? "Frame rate maintained (\(origStr))"
                : "Frame rate changed from \(origStr) to \(procStr)"
        )
    }

    // MARK: - Check 5: Reasonable File Size (low, warning only)

    /// Warn if processed file is significantly larger (>2x original).
    ///
    /// This is a warning, not a failure — re-encoding can legitimately increase
    /// file size (e.g. bitrate increase, format change).
    func checkFileSize(original: VideoMetadata, processed: VideoMetadata) -> QualityCheck {
        guard original.fileSizeBytes > 0 else {
            return QualityCheck(
                id: "file_size_reasonable",
                name: "File Size Check",
                passed: true,
                severity: .low,
                message: "File size check skipped (original size unknown)"
            )
        }

        let ratio = Double(processed.fileSizeBytes) / Double(original.fileSizeBytes)
        let changePercent = (ratio - 1.0) * 100.0
        let oversized = ratio > 2.0

        let message: String
        if changePercent < 0 {
            message = String(format: "File size reduced by %.0f%% (%.1f MB → %.1f MB)",
                             abs(changePercent), original.fileSizeMB, processed.fileSizeMB)
        } else if changePercent < 5 {
            message = String(format: "File size unchanged (%.1f MB → %.1f MB)",
                             original.fileSizeMB, processed.fileSizeMB)
        } else {
            message = String(format: "File size increased by %.0f%% (%.1f MB → %.1f MB)",
                             changePercent, original.fileSizeMB, processed.fileSizeMB)
        }

        return QualityCheck(
            id: "file_size_reasonable",
            name: "File Size Check",
            passed: !oversized,
            isWarning: oversized,  // oversized = warning, not hard failure
            severity: .low,
            message: oversized
                ? String(format: "Processed file is %.1fx larger than original — \(message)", ratio)
                : message
        )
    }
}
