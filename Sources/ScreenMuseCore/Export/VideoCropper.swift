@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Crops a rectangular region from an existing video file.
///
/// Uses AVMutableVideoComposition with a translation transform to offset
/// the source content so the crop region appears at (0,0). Requires
/// re-encoding (unlike trim which uses stream copy).
///
/// API: POST /crop
/// {
///   "source":  "last" | "/path/to/video.mp4"   (default: "last")
///   "region":  {"x":100,"y":50,"width":1280,"height":720}  (required)
///   "quality": "medium"                         (low/medium/high/max, default: medium)
/// }
public final class VideoCropper {

    public enum CropError: Error, LocalizedError {
        case noSource
        case sourceNotFound(String)
        case missingRegion
        case invalidRegion(String)
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noSource: return "No source video specified"
            case .sourceNotFound(let p): return "Source not found: \(p)"
            case .missingRegion: return "'region' is required: {x, y, width, height}"
            case .invalidRegion(let m): return "Invalid region: \(m)"
            case .exportFailed(let m): return "Crop export failed: \(m)"
            }
        }
    }

    public struct CropResult: Sendable {
        public let outputURL: URL
        public let cropRect: CGRect
        public let duration: Double
        public let fileSizeMB: Double
    }

    public func crop(
        sourceURL: URL,
        region: CGRect,
        outputURL: URL,
        quality: RecordingConfig.Quality = .medium,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> CropResult {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CropError.sourceNotFound(sourceURL.path)
        }
        guard region.width > 0, region.height > 0 else {
            throw CropError.invalidRegion("width and height must be > 0")
        }

        smLog.info("VideoCropper: crop \(Int(region.width))×\(Int(region.height)) at (\(Int(region.origin.x)),\(Int(region.origin.y))) from \(sourceURL.lastPathComponent)", category: .recording)

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Get natural video size
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw CropError.exportFailed("No video track found")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)

        // Validate crop region fits within video
        let videoWidth = naturalSize.width
        let videoHeight = naturalSize.height
        let clampedX = max(0, min(region.origin.x, videoWidth - 1))
        let clampedY = max(0, min(region.origin.y, videoHeight - 1))
        let clampedW = min(region.width, videoWidth - clampedX)
        let clampedH = min(region.height, videoHeight - clampedY)
        let clampedRect = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)

        if clampedRect != region {
            smLog.warning("VideoCropper: region clamped to \(Int(clampedW))×\(Int(clampedH)) (video is \(Int(videoWidth))×\(Int(videoHeight)))", category: .recording)
        }

        // Build video composition
        let composition = AVMutableVideoComposition()
        // Even dimensions required by H.264
        let outputW = Int(clampedW) & ~1
        let outputH = Int(clampedH) & ~1
        composition.renderSize = CGSize(width: outputW, height: outputH)
        composition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        // Combine preferred transform with crop translation
        let cropTranslation = CGAffineTransform(translationX: -clampedX, y: -clampedY)
        let finalTransform = preferredTransform.concatenating(cropTranslation)
        layerInstruction.setTransform(finalTransform, at: .zero)

        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        // Export with composition (requires re-encode — passthrough can't apply transforms)
        let presetName = qualityToPreset(quality)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw CropError.exportFailed("Could not create export session with preset \(presetName)")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = composition

        let progressTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                progress?(Double(exportSession.progress))
            }
        }

        await exportSession.export()
        progressTimer.cancel()

        guard exportSession.status == .completed else {
            throw CropError.exportFailed(exportSession.error?.localizedDescription ?? "export failed")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let sizeMB = Double(fileSize) / 1_048_576

        smLog.info("VideoCropper: ✅ \(outputW)×\(outputH) \(String(format:"%.1f",durationSeconds))s \(String(format:"%.1f",sizeMB))MB → \(outputURL.lastPathComponent)", category: .recording)
        smLog.usage("CROP", details: [
            "region": "\(outputW)x\(outputH)",
            "duration": "\(String(format:"%.1f",durationSeconds))s",
            "size": "\(String(format:"%.1f",sizeMB))MB"
        ])

        return CropResult(outputURL: outputURL, cropRect: clampedRect, duration: durationSeconds, fileSizeMB: sizeMB)
    }

    private func qualityToPreset(_ quality: RecordingConfig.Quality) -> String {
        switch quality {
        case .low:    return AVAssetExportPresetMediumQuality
        case .medium: return AVAssetExportPresetHighestQuality
        case .high:   return AVAssetExportPresetHighestQuality
        case .max:    return AVAssetExportPresetHighestQuality
        }
    }
}
