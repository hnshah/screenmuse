@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import Foundation

/// Burns text overlays into a video using AVVideoCompositionCoreAnimationTool.
///
/// Overlays are composited using CoreAnimation layers — GPU-accelerated,
/// no frame-by-frame iteration required. The video data itself is re-encoded
/// once; CATextLayer handles the text rendering at each frame.
///
/// API: POST /annotate
/// {
///   "source":  "last" | "/path/to/video.mp4"   (default: "last")
///   "overlays": [
///     {
///       "text":  "Step 1: Open settings",
///       "start": 2.0,               (seconds, default: 0)
///       "end":   8.0,               (seconds, default: end of video)
///       "position": "bottom",       ("top" | "bottom" | "center", default: "bottom")
///       "size":  36,                (font size, default: 32)
///       "color": "#FFFFFF",         (hex color, default: white)
///       "background": "#000000",    (hex color + alpha, default: semi-transparent black)
///       "background_alpha": 0.6     (0.0–1.0, default: 0.6)
///     }
///   ]
/// }
public final class VideoAnnotator {

    public enum AnnotateError: Error, LocalizedError {
        case noSource
        case sourceNotFound(String)
        case noOverlays
        case invalidOverlay(String)
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noSource: return "No source video specified"
            case .sourceNotFound(let p): return "Source not found: \(p)"
            case .noOverlays: return "'overlays' must be a non-empty array"
            case .invalidOverlay(let m): return "Invalid overlay: \(m)"
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    public struct Overlay: Sendable {
        public let text: String
        public let start: Double
        public let end: Double?           // nil = end of video
        public let position: Position
        public let fontSize: CGFloat
        public let textColorHex: String
        public let bgColorHex: String
        public let bgAlpha: Double

        public enum Position: String, Sendable {
            case top, center, bottom
        }

        public init(from dict: [String: Any], videoDuration: Double) throws {
            guard let text = dict["text"] as? String, !text.isEmpty else {
                throw VideoAnnotator.AnnotateError.invalidOverlay("'text' is required")
            }
            self.text = text
            self.start = (dict["start"] as? Double) ?? (dict["start"] as? Int).map(Double.init) ?? 0
            self.end   = (dict["end"] as? Double) ?? (dict["end"] as? Int).map(Double.init)
            self.position = Position(rawValue: dict["position"] as? String ?? "bottom") ?? .bottom
            self.fontSize = CGFloat((dict["size"] as? Int) ?? (dict["size"] as? Double).map(Int.init) ?? 32)
            self.textColorHex = dict["color"] as? String ?? "#FFFFFF"
            self.bgColorHex   = dict["background"] as? String ?? "#000000"
            self.bgAlpha      = dict["background_alpha"] as? Double ?? 0.6
        }
    }

    public struct AnnotateResult: Sendable {
        public let outputURL: URL
        public let overlayCount: Int
        public let duration: Double
        public let fileSizeMB: Double
    }

    // MARK: - Public API

    public func annotate(
        sourceURL: URL,
        overlays: [[String: Any]],
        outputURL: URL,
        quality: RecordingConfig.Quality = .medium,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AnnotateResult {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AnnotateError.sourceNotFound(sourceURL.path)
        }
        guard !overlays.isEmpty else {
            throw AnnotateError.noOverlays
        }

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Parse overlays
        let parsed = try overlays.map { try Overlay(from: $0, videoDuration: durationSeconds) }

        smLog.info("VideoAnnotator: \(parsed.count) overlays on \(sourceURL.lastPathComponent) (\(String(format:"%.1f",durationSeconds))s)", category: .recording)

        // Get video natural size
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw AnnotateError.exportFailed("No video track found")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let renderSize = naturalSize.applying(transform).applying(CGAffineTransform(scaleX: abs(1), y: abs(1)))
        let width = abs(renderSize.width) > 10 ? abs(renderSize.width) : naturalSize.width
        let height = abs(renderSize.height) > 10 ? abs(renderSize.height) : naturalSize.height

        // Build parent layer + video layer
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        videoLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        parentLayer.addSublayer(videoLayer)

        // Add text overlays as CATextLayer with keyframe opacity animation
        for overlay in parsed {
            let textLayer = CATextLayer()
            textLayer.string = overlay.text
            textLayer.font = CTFontCreateWithName("Helvetica-Bold" as CFString, overlay.fontSize, nil)
            textLayer.fontSize = overlay.fontSize
            textLayer.foregroundColor = cgColor(from: overlay.textColorHex)
            textLayer.alignmentMode = .center
            textLayer.contentsScale = 2.0

            // Measure text for sizing
            let padding: CGFloat = 12
            let textWidth = width - 40
            let textHeight = overlay.fontSize + padding * 2

            let yPos: CGFloat
            switch overlay.position {
            case .top:    yPos = height - textHeight - 20
            case .center: yPos = (height - textHeight) / 2
            case .bottom: yPos = 20
            }

            // Background layer
            let bgLayer = CALayer()
            bgLayer.backgroundColor = cgColor(from: overlay.bgColorHex, alpha: overlay.bgAlpha)
            bgLayer.cornerRadius = 6
            bgLayer.frame = CGRect(x: 20, y: yPos, width: textWidth, height: textHeight)

            textLayer.frame = CGRect(x: 20, y: yPos + padding / 2, width: textWidth, height: textHeight)

            // Opacity keyframe: 0 → 1 at start, 1 → 0 at end
            let endTime = overlay.end ?? durationSeconds
            let totalDur = durationSeconds

            let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
            opacityAnim.keyTimes = [
                0,
                NSNumber(value: overlay.start / totalDur - 0.001),
                NSNumber(value: overlay.start / totalDur),
                NSNumber(value: endTime / totalDur),
                NSNumber(value: min(1.0, endTime / totalDur + 0.001)),
                1
            ]
            opacityAnim.values = [0, 0, 1, 1, 0, 0]
            opacityAnim.duration = totalDur
            opacityAnim.beginTime = AVCoreAnimationBeginTimeAtZero
            opacityAnim.isRemovedOnCompletion = false
            opacityAnim.fillMode = .both
            opacityAnim.calculationMode = .discrete

            textLayer.add(opacityAnim, forKey: "opacity")
            bgLayer.add(opacityAnim.copy() as! CAKeyframeAnimation, forKey: "opacity")

            parentLayer.addSublayer(bgLayer)
            parentLayer.addSublayer(textLayer)
        }

        parentLayer.isGeometryFlipped = true

        // Build video composition
        let videoComposition = AVMutableVideoComposition(propertiesOf: asset)
        videoComposition.renderSize = CGSize(width: width, height: height)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        // Export
        let presetName: String
        switch quality {
        case .low:    presetName = AVAssetExportPresetMediumQuality
        case .medium: presetName = AVAssetExportPresetHighestQuality
        case .high, .max: presetName = AVAssetExportPresetHighestQuality
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw AnnotateError.exportFailed("Could not create export session")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                progress?(Double(exportSession.progress))
            }
        }

        await exportSession.export()
        progressTask.cancel()

        guard exportSession.status == .completed else {
            throw AnnotateError.exportFailed(exportSession.error?.localizedDescription ?? "export failed")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let sizeMB = Double(fileSize) / 1_048_576

        smLog.info("VideoAnnotator: ✅ \(parsed.count) overlays \(String(format:"%.1f",durationSeconds))s \(String(format:"%.1f",sizeMB))MB → \(outputURL.lastPathComponent)", category: .recording)
        smLog.usage("ANNOTATE", details: ["overlays": "\(parsed.count)", "duration": "\(String(format:"%.1f",durationSeconds))s"])

        return AnnotateResult(outputURL: outputURL, overlayCount: parsed.count, duration: durationSeconds, fileSizeMB: sizeMB)
    }

    // MARK: - Color Helpers

    private func cgColor(from hex: String, alpha: Double = 1.0) -> CGColor {
        var h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else {
            return CGColor(red: 1, green: 1, blue: 1, alpha: CGFloat(alpha))
        }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return CGColor(red: r, green: g, blue: b, alpha: CGFloat(alpha))
    }
}
