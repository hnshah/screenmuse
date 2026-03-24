import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Exports a recorded video as an animated GIF or WebP.
///
/// GIF/WebP are the primary shareable formats for agent-generated demos:
/// they embed in PRs, Slack, Notion, and tweets without requiring a player.
///
/// Uses AVAssetImageGenerator for frame extraction (no full re-encode)
/// and CGImageDestination for GIF/WebP assembly.
///
/// GIF notes:
///   - macOS supports animated GIF via ImageIO (CGImageDestination)
///   - Per-frame delay is set via kCGImagePropertyGIFDelayTime
///   - Quality affects color quantization: low=128 colors, medium/high=256 colors
///
/// WebP notes:
///   - macOS 14+ supports animated WebP natively via ImageIO
///   - ~30% smaller than equivalent GIF at the same quality
///   - kUTTypeWebP / UTType.webP

public final class GIFExporter {

    // MARK: - Types

    public struct Config: Sendable {
        /// Frames per second for the exported animation. Default 10.
        public var fps: Double = 10
        /// Maximum width in pixels. Height scales proportionally. Default 800.
        public var scale: Int = 800
        /// Color/quality level. Default .medium.
        public var quality: Quality = .medium
        /// Optional time range in seconds. nil = full video.
        public var timeRange: ClosedRange<Double>? = nil
        /// Output format. Default .gif.
        public var format: Format = .gif

        public init() {}

        public enum Quality: String, Sendable {
            case low, medium, high
            var colorCount: Int {
                switch self { case .low: return 128; case .medium, .high: return 256 }
            }
        }
        public enum Format: String, Sendable {
            case gif, webp
            var utType: UTType {
                switch self {
                case .gif: return .gif
                case .webp: return UTType("public.webp") ?? .gif
                }
            }
            var fileExtension: String { rawValue }
        }
    }

    public struct ExportResult: Sendable {
        public let outputURL: URL
        public let format: Config.Format
        public let width: Int
        public let height: Int
        public let frameCount: Int
        public let fps: Double
        public let duration: Double
        public let fileSize: Int

        public var sizeMB: Double { Double(fileSize) / 1_048_576 }

        public func asDictionary() -> [String: Any] {
            [
                "path": outputURL.path,
                "format": format.rawValue,
                "width": width,
                "height": height,
                "frames": frameCount,
                "fps": fps,
                "duration": duration,
                "size": fileSize,
                "size_mb": (sizeMB * 100).rounded() / 100
            ]
        }
    }

    public enum ExportError: Error, LocalizedError {
        case unsupportedFormat(String)
        case noVideoSource
        case assetLoadFailed(String)
        case noVideoTrack
        case outputDirectoryFailed(String)
        case destinationCreateFailed(URL)
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let f):
                return "Unsupported format '\(f)'. Supported: gif, webp"
            case .noVideoSource:
                return "No video available. Record something first, or pass 'source' with a file path."
            case .assetLoadFailed(let msg):
                return "Failed to load video asset: \(msg)"
            case .noVideoTrack:
                return "Video has no video tracks."
            case .outputDirectoryFailed(let path):
                return "Could not create output directory: \(path)"
            case .destinationCreateFailed(let url):
                return "Failed to create image destination at: \(url.path)"
            case .exportFailed(let msg):
                return "Export failed: \(msg)"
            }
        }
    }

    // MARK: - Export

    /// Export a video to animated GIF or WebP.
    ///
    /// - Parameters:
    ///   - sourceURL: The source MP4 (or any AVAsset-readable format)
    ///   - outputURL: Destination file path
    ///   - config: Export configuration (fps, scale, quality, time range, format)
    ///   - progress: Optional 0.0–1.0 progress callback
    public func export(
        sourceURL: URL,
        outputURL: URL,
        config: Config,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ExportResult {

        smLog.info("GIFExporter: \(config.format.rawValue) export started — source=\(sourceURL.lastPathComponent) fps=\(config.fps) scale=\(config.scale) quality=\(config.quality.rawValue)", category: .recording)

        let asset = AVURLAsset(url: sourceURL)

        // Load duration and video track
        let duration: CMTime
        let naturalSize: CGSize

        do {
            duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else {
                throw ExportError.noVideoTrack
            }
            naturalSize = try await videoTrack.load(.naturalSize)
        } catch let err as ExportError {
            throw err
        } catch {
            throw ExportError.assetLoadFailed(error.localizedDescription)
        }

        let totalDuration = CMTimeGetSeconds(duration)
        guard totalDuration > 0 else {
            throw ExportError.exportFailed("Video duration is 0")
        }

        // Resolve time range
        let startSeconds = config.timeRange?.lowerBound ?? 0
        let endSeconds = min(config.timeRange?.upperBound ?? totalDuration, totalDuration)
        guard startSeconds < endSeconds else {
            throw ExportError.exportFailed("start (\(startSeconds)s) must be less than end (\(endSeconds)s)")
        }
        let exportDuration = endSeconds - startSeconds

        // Compute output dimensions (preserve aspect ratio)
        let aspectRatio = naturalSize.width / naturalSize.height
        let outWidth: Int
        let outHeight: Int
        if naturalSize.width > naturalSize.height {
            outWidth = config.scale
            outHeight = max(1, Int(Double(config.scale) / aspectRatio))
        } else {
            outHeight = config.scale
            outWidth = max(1, Int(Double(config.scale) * aspectRatio))
        }

        smLog.info("GIFExporter: source size=\(Int(naturalSize.width))×\(Int(naturalSize.height)) → export=\(outWidth)×\(outHeight) duration=\(String(format:"%.1f",exportDuration))s", category: .recording)

        // Build frame timestamps
        let frameInterval = 1.0 / config.fps
        var frameTimes: [NSValue] = []
        var t = startSeconds
        while t < endSeconds {
            frameTimes.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
            t += frameInterval
        }

        if frameTimes.isEmpty {
            throw ExportError.exportFailed("No frames to export in time range \(startSeconds)–\(endSeconds)s")
        }

        // Create image destination.
        // CGImageDestination with public.webp supports animated WebP on macOS 14+.
        // If creation fails (e.g., unsupported system config), fall back to GIF automatically.
        let destinationUTType = config.format.utType

        // Resolve effective output URL — may change if WebP falls back to GIF
        var effectiveOutputURL = outputURL
        var effectiveFormat = config.format

        var destination = CGImageDestinationCreateWithURL(
            effectiveOutputURL as CFURL,
            destinationUTType.identifier as CFString,
            frameTimes.count,
            nil
        )

        if destination == nil && config.format == .webp {
            smLog.warning("GIFExporter: animated WebP not supported on this system — falling back to GIF", category: .recording)
            effectiveFormat = .gif
            effectiveOutputURL = outputURL.deletingPathExtension().appendingPathExtension("gif")
            destination = CGImageDestinationCreateWithURL(
                effectiveOutputURL as CFURL,
                UTType.gif.identifier as CFString,
                frameTimes.count,
                nil
            )
        }

        guard let destination else {
            throw ExportError.destinationCreateFailed(effectiveOutputURL)
        }

        // Set animated GIF/WebP container properties
        let delayTime = frameInterval
        let containerProps: [String: Any]
        let frameProps: [String: Any]

        switch effectiveFormat {
        case .gif:
            containerProps = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFLoopCount as String: 0  // 0 = loop forever
                ]
            ]
            frameProps = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delayTime,
                    kCGImagePropertyGIFUnclampedDelayTime as String: delayTime
                ]
            ]
        case .webp:
            containerProps = [
                kCGImagePropertyWebPDictionary as String: [
                    kCGImagePropertyWebPLoopCount as String: 0
                ]
            ]
            frameProps = [
                kCGImagePropertyWebPDictionary as String: [
                    kCGImagePropertyWebPDelayTime as String: delayTime
                ]
            ]
        }

        CGImageDestinationSetProperties(destination, containerProps as CFDictionary)

        // Set up image generator
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true  // respect rotation metadata
        generator.maximumSize = CGSize(width: outWidth * 2, height: outHeight * 2)  // 2x for downscale quality
        generator.requestedTimeToleranceBefore = CMTime(seconds: frameInterval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: frameInterval / 2, preferredTimescale: 600)

        // CIContext for downscaling
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        // Extract and write frames.
        // State is tracked via a reference-type container captured by the generator closure.
        // AVFoundation calls the handler serially on its internal queue, so no lock is needed —
        // but @unchecked Sendable is required to cross the Swift concurrency boundary.
        final class FrameState: @unchecked Sendable {
            var written: Int = 0
            var lastError: Error? = nil
        }
        let totalFrames = frameTimes.count
        let state = FrameState()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            generator.generateCGImagesAsynchronously(forTimes: frameTimes) { [ciContext] requestedTime, cgImage, actualTime, result, error in
                defer {
                    state.written += 1
                    progress?(Double(state.written) / Double(totalFrames))
                    if state.written == totalFrames {
                        continuation.resume()
                    }
                }

                guard result == .succeeded, let rawImage = cgImage else {
                    if let e = error {
                        smLog.warning("GIFExporter: frame at \(CMTimeGetSeconds(requestedTime))s failed: \(e.localizedDescription)", category: .recording)
                        state.lastError = e
                    }
                    // Skip this frame — destination frame count will be less than totalFrames
                    // but the animation will still play with slightly uneven timing
                    return
                }

                // Downscale to target size with Lanczos for quality
                let ciImage = CIImage(cgImage: rawImage)
                let scaleX = CGFloat(outWidth) / ciImage.extent.width
                let scaleY = CGFloat(outHeight) / ciImage.extent.height
                // CIFilter.lanczosScaleTransform() typed accessor removed in newer SDKs — use name-based init
                let scaleFilter = CIFilter(name: "CILanczosScaleTransform")!
                scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
                scaleFilter.setValue(Float(scaleX), forKey: kCIInputScaleKey)
                scaleFilter.setValue(Float(scaleY / scaleX), forKey: kCIInputAspectRatioKey)

                let scaledFrame: CGImage
                if let outputCI = scaleFilter.outputImage,
                   let rendered = ciContext.createCGImage(outputCI, from: CGRect(x: 0, y: 0, width: outWidth, height: outHeight)) {
                    scaledFrame = rendered
                } else {
                    // Fallback: use raw image (no downscale, still correct)
                    scaledFrame = rawImage
                }

                CGImageDestinationAddImage(destination, scaledFrame, frameProps as CFDictionary)
            }
        }

        // Finalize the destination
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.exportFailed("CGImageDestinationFinalize failed — possibly out of disk space or invalid frame data")
        }

        if let e = state.lastError {
            smLog.warning("GIFExporter: export completed with \(state.written) frames but had frame errors: \(e.localizedDescription)", category: .recording)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: effectiveOutputURL.path)[.size] as? Int) ?? 0
        let result = ExportResult(
            outputURL: effectiveOutputURL,
            format: effectiveFormat,
            width: outWidth,
            height: outHeight,
            frameCount: state.written,
            fps: config.fps,
            duration: exportDuration,
            fileSize: fileSize
        )

        smLog.info("GIFExporter: ✅ export done — \(effectiveOutputURL.lastPathComponent) \(result.width)×\(result.height) \(state.written) frames \(String(format:"%.2f",result.sizeMB))MB", category: .recording)
        smLog.usage("EXPORT \(effectiveFormat.rawValue.uppercased())", details: [
            "file": effectiveOutputURL.lastPathComponent,
            "size": "\(String(format:"%.2f",result.sizeMB))MB",
            "frames": "\(state.written)",
            "duration": "\(String(format:"%.1f",exportDuration))s"
        ])

        return result
    }

    // MARK: - Output URL Helper

    /// Generate a default output URL next to the source file.
    /// ~/Movies/ScreenMuse/Exports/<name>.<format>
    public static func defaultOutputURL(
        for sourceURL: URL,
        format: Config.Format,
        exportsDir: URL
    ) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let filename = "\(stem).\(format.fileExtension)"
        return exportsDir.appendingPathComponent(filename)
    }
}
