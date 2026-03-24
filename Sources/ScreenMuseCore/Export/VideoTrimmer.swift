import AVFoundation
import Foundation

/// Trim a video to a time range using AVFoundation.
///
/// Default path: stream copy (AVAssetExportPresetPassthrough) — no re-encode,
/// near-instantaneous, zero quality loss. Trim point snaps to nearest keyframe.
///
/// Re-encode path (reencode: true): frame-accurate trim with
/// AVAssetExportPresetHighestQuality. Slower but exact.
public final class VideoTrimmer {

    // MARK: - Types

    public struct Config: Sendable {
        /// Start time in seconds. Default 0.
        public var start: Double = 0
        /// End time in seconds. nil = full video duration.
        public var end: Double? = nil
        /// Re-encode for frame accuracy (slower). Default false = fast stream copy.
        public var reencode: Bool = false
        /// Output path. nil = auto-generated next to source.
        public var outputPath: String? = nil

        public init() {}
    }

    public struct TrimResult: Sendable {
        public let outputURL: URL
        public let originalDuration: Double
        public let trimmedDuration: Double
        public let start: Double
        public let end: Double
        public let fileSize: Int
        public var sizeMB: Double { Double(fileSize) / 1_048_576 }

        public func asDictionary() -> [String: Any] {
            [
                "path": outputURL.path,
                "original_duration": (originalDuration * 10).rounded() / 10,
                "trimmed_duration": (trimmedDuration * 10).rounded() / 10,
                "start": start,
                "end": end,
                "size": fileSize,
                "size_mb": (sizeMB * 100).rounded() / 100
            ]
        }
    }

    public enum TrimError: Error, LocalizedError {
        case noVideoSource
        case invalidRange(String)
        case exportFailed(String)
        case exportCancelled

        public var errorDescription: String? {
            switch self {
            case .noVideoSource:
                return "No video available. Record something first, or pass 'source' with a file path."
            case .invalidRange(let msg):
                return msg
            case .exportFailed(let msg):
                return "Trim failed: \(msg)"
            case .exportCancelled:
                return "Trim was cancelled."
            }
        }
    }

    // MARK: - Trim

    public func trim(
        sourceURL: URL,
        outputURL: URL,
        config: Config
    ) async throws -> TrimResult {
        smLog.info("VideoTrimmer: trim start=\(config.start) end=\(config.end.map{String($0)} ?? "full") reencode=\(config.reencode) source=\(sourceURL.lastPathComponent)", category: .recording)

        let asset = AVURLAsset(url: sourceURL)

        // Load duration
        let assetDuration: CMTime
        do {
            assetDuration = try await asset.load(.duration)
        } catch {
            throw TrimError.exportFailed("Could not load asset duration: \(error.localizedDescription)")
        }
        let totalSeconds = CMTimeGetSeconds(assetDuration)

        // Validate and clamp range
        let startSec = config.start
        let endSec = config.end ?? totalSeconds

        guard startSec >= 0 else {
            throw TrimError.invalidRange("start (\(startSec)s) must be >= 0")
        }
        guard endSec > startSec else {
            throw TrimError.invalidRange("end (\(endSec)s) must be greater than start (\(startSec)s)")
        }
        guard startSec < totalSeconds else {
            throw TrimError.invalidRange("start (\(startSec)s) exceeds video duration (\(String(format:"%.1f",totalSeconds))s)")
        }
        guard endSec <= totalSeconds else {
            throw TrimError.invalidRange("end (\(endSec)s) exceeds video duration (\(String(format:"%.1f",totalSeconds))s). Pass end=\(String(format:"%.1f",totalSeconds)) or omit it.")
        }

        // Build CMTimeRange
        let startTime = CMTime(seconds: startSec, preferredTimescale: 600)
        let endTime = CMTime(seconds: endSec, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        // Choose export preset
        let presetName = config.reencode
            ? AVAssetExportPresetHighestQuality
            : AVAssetExportPresetPassthrough

        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw TrimError.exportFailed("Could not create AVAssetExportSession with preset '\(presetName)'")
        }

        // Remove existing output file if present
        try? FileManager.default.removeItem(at: outputURL)

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.timeRange = timeRange

        smLog.info("VideoTrimmer: exporting \(String(format:"%.1f",startSec))s–\(String(format:"%.1f",endSec))s (\(String(format:"%.1f",endSec-startSec))s) preset=\(presetName)", category: .recording)

        // Export
        await session.export()

        switch session.status {
        case .completed:
            break
        case .cancelled:
            throw TrimError.exportCancelled
        case .failed:
            let msg = session.error?.localizedDescription ?? "unknown error"
            smLog.error("VideoTrimmer: export failed — \(msg)", category: .recording)
            throw TrimError.exportFailed(msg)
        default:
            throw TrimError.exportFailed("Unexpected export status: \(session.status.rawValue)")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let trimmedDuration = endSec - startSec
        let result = TrimResult(
            outputURL: outputURL,
            originalDuration: totalSeconds,
            trimmedDuration: trimmedDuration,
            start: startSec,
            end: endSec,
            fileSize: fileSize
        )

        smLog.info("VideoTrimmer: ✅ trim done — \(outputURL.lastPathComponent) \(String(format:"%.1f",trimmedDuration))s \(String(format:"%.2f",result.sizeMB))MB", category: .recording)
        smLog.usage("TRIM", details: [
            "file": outputURL.lastPathComponent,
            "range": "\(String(format:"%.1f",startSec))–\(String(format:"%.1f",endSec))s",
            "duration": "\(String(format:"%.1f",trimmedDuration))s",
            "size": "\(String(format:"%.2f",result.sizeMB))MB"
        ])

        return result
    }

    // MARK: - Output URL Helper

    public static func defaultOutputURL(for sourceURL: URL, exportsDir: URL) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let filename = "\(stem).trimmed.mp4"
        return exportsDir.appendingPathComponent(filename)
    }
}
