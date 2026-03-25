import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// OCR for AI agents — reads text from the screen or any image file.
///
/// Uses Apple's Vision framework (VNRecognizeTextRequest). Requires no
/// API key or internet connection. Accurate on macOS 14+ with hardware
/// acceleration.
///
/// Sources:
///   "screen"      — capture and OCR the full display right now (default)
///   "/path/..."   — OCR an existing image (PNG, JPEG, TIFF, etc.)
///
/// API: POST /ocr
/// {
///   "source": "screen" | "/path/to/image.png"  (default: "screen")
///   "lang": "en"                               (language hint, default: auto)
///   "level": "accurate" | "fast"               (recognition level, default: accurate)
///   "full_text_only": true                     (omit bounding boxes, default: false)
/// }
///
/// Response:
/// {
///   "full_text": "Hello\nWorld",
///   "block_count": 2,
///   "blocks": [
///     {"text": "Hello", "confidence": 0.99, "box": {"x":0.1,"y":0.9,"w":0.2,"h":0.05}},
///     {"text": "World", "confidence": 0.97, "box": {"x":0.1,"y":0.8,"w":0.22,"h":0.05}}
///   ],
///   "source_width": 1920,
///   "source_height": 1080
/// }
///
/// Note on bounding boxes: Vision uses normalized coordinates (0.0–1.0)
/// where (0,0) is bottom-left. Multiply by source_width/height to get pixels.
public final class ScreenOCR {

    public enum OCRError: Error, LocalizedError {
        case sourceNotFound(String)
        case captureFailedNoDisplay
        case imageLoadFailed(String)
        case recognitionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceNotFound(let p): return "Image not found: \(p)"
            case .captureFailedNoDisplay: return "Could not capture screen — no display available"
            case .imageLoadFailed(let p): return "Could not load image: \(p)"
            case .recognitionFailed(let m): return "OCR recognition failed: \(m)"
            }
        }
    }

    public struct Block: Sendable {
        public let text: String
        public let confidence: Float
        /// Normalized bbox in Vision coordinate space: origin = bottom-left, y-axis up
        public let boundingBox: CGRect
    }

    public struct OCRResult: Sendable {
        public let fullText: String
        public let blocks: [Block]
        public let sourceWidth: Int
        public let sourceHeight: Int
        public let source: String
        public let debugInfo: DebugInfo?

        public init(fullText: String, blocks: [Block], sourceWidth: Int, sourceHeight: Int, source: String, debugInfo: DebugInfo? = nil) {
            self.fullText = fullText
            self.blocks = blocks
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            self.source = source
            self.debugInfo = debugInfo
        }

        public var asJSON: [String: Any] {
            [
                "full_text": fullText,
                "block_count": blocks.count,
                "blocks": blocks.map { block in
                    [
                        "text": block.text
                            .components(separatedBy: CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\t\n\r")))
                            .joined()
                            .replacingOccurrences(of: "\u{FFFC}", with: ""),
                        "confidence": Double(block.confidence),
                        "box": [
                            "x": block.boundingBox.minX,
                            "y": block.boundingBox.minY,
                            "w": block.boundingBox.width,
                            "h": block.boundingBox.height
                        ]
                    ] as [String: Any]
                },
                "source_width": sourceWidth,
                "source_height": sourceHeight,
                "source": source
            ]
        }

        /// JSON including debug info (used when debug=true in request).
        public var asJSONWithDebug: [String: Any] {
            var json = asJSON
            if let debug = debugInfo {
                var debugDict: [String: Any] = [
                    "image_size": debug.imageSize,
                    "upscaled": debug.upscaled,
                    "detected_blocks": debug.detectedBlocks,
                    "confidence_avg": debug.confidenceAvg
                ]
                if let upscaledTo = debug.upscaledTo {
                    debugDict["upscaled_to"] = upscaledTo
                }
                json["debug"] = debugDict
            }
            return json
        }
    }

    // MARK: - Public API

    /// OCR the current screen.
    public func recognizeScreen(
        level: VNRequestTextRecognitionLevel = .accurate,
        languages: [String] = []
    ) async throws -> OCRResult {
        smLog.info("ScreenOCR: capturing screen for OCR", category: .capture)
        let cgImage = try await captureScreen()
        return try await recognize(cgImage: cgImage, source: "screen", level: level, languages: languages)
    }

    /// OCR a CGImage directly (used by /validate text_at check).
    public func recognizeImage(
        cgImage: CGImage,
        source: String = "image",
        level: VNRequestTextRecognitionLevel = .accurate,
        languages: [String] = []
    ) async throws -> OCRResult {
        smLog.info("ScreenOCR: recognizing CGImage \(cgImage.width)×\(cgImage.height)", category: .capture)
        return try await recognize(cgImage: cgImage, source: source, level: level, languages: languages)
    }

    /// OCR an existing image file.
    public func recognizeFile(
        at url: URL,
        level: VNRequestTextRecognitionLevel = .accurate,
        languages: [String] = []
    ) async throws -> OCRResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OCRError.sourceNotFound(url.path)
        }
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.imageLoadFailed(url.path)
        }
        smLog.info("ScreenOCR: recognizing \(url.lastPathComponent) \(cgImage.width)×\(cgImage.height)", category: .capture)
        return try await recognize(cgImage: cgImage, source: url.path, level: level, languages: languages)
    }

    // MARK: - Core Recognition

    /// Auto-upscale threshold: images narrower than this get upscaled for better OCR accuracy.
    private static let upscaleThreshold = 1000
    private static let upscaleTargetWidth = 1440

    /// Upscale a CGImage to the target width, maintaining aspect ratio.
    private func upscaleIfNeeded(_ cgImage: CGImage) -> (image: CGImage, upscaled: Bool, targetWidth: Int, targetHeight: Int) {
        let w = cgImage.width
        let h = cgImage.height
        guard w < Self.upscaleThreshold, w > 0, h > 0 else {
            return (cgImage, false, w, h)
        }

        let scale = Double(Self.upscaleTargetWidth) / Double(w)
        let targetW = Self.upscaleTargetWidth
        let targetH = Int(Double(h) * scale)

        guard let context = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            smLog.warning("ScreenOCR: upscale failed — CGContext creation error", category: .capture)
            return (cgImage, false, w, h)
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        if let upscaled = context.makeImage() {
            smLog.info("ScreenOCR: upscaled \(w)×\(h) → \(targetW)×\(targetH) for better OCR", category: .capture)
            return (upscaled, true, targetW, targetH)
        }
        return (cgImage, false, w, h)
    }

    /// Debug info collected during recognition.
    public struct DebugInfo: Sendable {
        public let imageSize: String
        public let upscaled: Bool
        public let upscaledTo: String?
        public let detectedBlocks: Int
        public let confidenceAvg: Double
    }

    private func recognize(
        cgImage: CGImage,
        source: String,
        level: VNRequestTextRecognitionLevel,
        languages: [String]
    ) async throws -> OCRResult {
        let originalWidth = cgImage.width
        let originalHeight = cgImage.height

        // Auto-upscale small images for better Vision accuracy
        let (processedImage, wasUpscaled, finalWidth, finalHeight) = upscaleIfNeeded(cgImage)

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, error in
                if let error {
                    continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                    return
                }
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                let blocks: [Block] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return Block(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        boundingBox: obs.boundingBox
                    )
                }
                // Sanitize: remove stray control chars (U+0000–U+001F) except tab + newline.
                // Vision OCR can return U+FFFC (object replacement) and other non-printables
                // that trip up JSON parsers and tools like jq.
                func sanitize(_ s: String) -> String {
                    var allowed = CharacterSet.controlCharacters
                    allowed.remove(charactersIn: "\t\n\r")
                    return s.components(separatedBy: allowed).joined()
                        .replacingOccurrences(of: "\u{FFFC}", with: "")  // object replacement char
                }
                let fullText = blocks.map { sanitize($0.text) }.joined(separator: "\n")
                let avgConfidence: Double = blocks.isEmpty ? 0 :
                    Double(blocks.map { Double($0.confidence) }.reduce(0, +)) / Double(blocks.count)

                let debugInfo = DebugInfo(
                    imageSize: "\(originalWidth)x\(originalHeight)",
                    upscaled: wasUpscaled,
                    upscaledTo: wasUpscaled ? "\(finalWidth)x\(finalHeight)" : nil,
                    detectedBlocks: blocks.count,
                    confidenceAvg: (avgConfidence * 100).rounded() / 100
                )

                smLog.info("ScreenOCR: ✅ \(blocks.count) blocks, \(fullText.count) chars from \(source == "screen" ? "screen" : URL(fileURLWithPath: source).lastPathComponent)\(wasUpscaled ? " (upscaled)" : "")", category: .capture)
                smLog.usage("OCR", details: ["source": source == "screen" ? "screen" : "file", "blocks": "\(blocks.count)", "chars": "\(fullText.count)", "upscaled": "\(wasUpscaled)"])
                continuation.resume(returning: OCRResult(
                    fullText: fullText,
                    blocks: blocks,
                    sourceWidth: originalWidth,
                    sourceHeight: originalHeight,
                    source: source,
                    debugInfo: debugInfo
                ))
            }
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }

            let handler = VNImageRequestHandler(cgImage: processedImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Screen Capture

    private func captureScreen() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw OCRError.captureFailedNoDisplay
        }

        let cfg = SCStreamConfiguration()
        cfg.width = display.width
        cfg.height = display.height
        cfg.minimumFrameInterval = .zero
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: cfg
        )
        return cgImage
    }
}
