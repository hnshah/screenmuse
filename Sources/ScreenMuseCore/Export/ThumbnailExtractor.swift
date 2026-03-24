import AVFoundation
import CoreImage
import Foundation

/// Extracts a still frame from a video file at a specific timestamp.
///
/// Uses AVAssetImageGenerator with Lanczos scaling for quality output.
/// If the exact timestamp has no keyframe, AVFoundation snaps to the
/// nearest available frame and reports the actual timestamp back.
///
/// API: POST /thumbnail
/// {
///   "source":  "last" | "/path/to/video.mp4"   (default: "last")
///   "time":    5.0                              (seconds, default: middle of video)
///   "scale":   800                             (max width px, default: 800)
///   "format":  "jpeg" | "png"                  (default: jpeg)
///   "quality": 85                              (JPEG quality 0–100, default: 85)
/// }
public final class ThumbnailExtractor {

    public enum ThumbnailError: Error, LocalizedError {
        case noSource
        case sourceNotFound(String)
        case generationFailed(String)
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .noSource: return "No source video specified"
            case .sourceNotFound(let p): return "Source not found: \(p)"
            case .generationFailed(let m): return "Frame generation failed: \(m)"
            case .encodingFailed: return "Could not encode output image"
            }
        }
    }

    public struct ThumbnailResult: Sendable {
        public let outputURL: URL
        public let actualTime: Double    // seconds — may differ from requested time
        public let width: Int
        public let height: Int
        public let fileSizeBytes: Int
    }

    public func extract(
        sourceURL: URL,
        time: Double?,
        scale: Int = 800,
        format: String = "jpeg",
        quality: Double = 0.85,
        outputURL: URL
    ) async throws -> ThumbnailResult {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ThumbnailError.sourceNotFound(sourceURL.path)
        }

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Default: grab middle of video
        let requestedSeconds = time ?? (durationSeconds / 2)
        let clampedSeconds = max(0, min(requestedSeconds, durationSeconds - 0.01))
        let requestTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: CGFloat(scale), height: CGFloat(scale))

        let (cgImage, actualTime) = try await generator.image(at: requestTime)
        let actualSeconds = CMTimeGetSeconds(actualTime)
        let w = cgImage.width
        let h = cgImage.height

        // Encode
        let mutableData = NSMutableData()
        let utType = (format == "png") ? "public.png" as CFString : "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, utType, 1, nil)
        else { throw ThumbnailError.encodingFailed }

        let props: [CFString: Any] = (format != "png")
            ? [kCGImageDestinationLossyCompressionQuality: quality]
            : [:]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ThumbnailError.encodingFailed }

        let data = mutableData as Data
        try data.write(to: outputURL)

        smLog.info("ThumbnailExtractor: ✅ \(w)×\(h) at \(String(format:"%.2f",actualSeconds))s → \(outputURL.lastPathComponent)", category: .recording)
        return ThumbnailResult(outputURL: outputURL, actualTime: actualSeconds, width: w, height: h, fileSizeBytes: data.count)
    }
}
