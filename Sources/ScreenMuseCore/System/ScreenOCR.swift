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

        public var asJSON: [String: Any] {
            [
                "full_text": fullText,
                "block_count": blocks.count,
                "blocks": blocks.map { block in
                    [
                        "text": block.text,
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

    private func recognize(
        cgImage: CGImage,
        source: String,
        level: VNRequestTextRecognitionLevel,
        languages: [String]
    ) async throws -> OCRResult {
        let width = cgImage.width
        let height = cgImage.height

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
                let fullText = blocks.map { $0.text }.joined(separator: "\n")
                smLog.info("ScreenOCR: ✅ \(blocks.count) blocks, \(fullText.count) chars from \(source == "screen" ? "screen" : URL(fileURLWithPath: source).lastPathComponent)", category: .capture)
                smLog.usage("OCR", details: ["source": source == "screen" ? "screen" : "file", "blocks": "\(blocks.count)", "chars": "\(fullText.count)"])
                continuation.resume(returning: OCRResult(
                    fullText: fullText,
                    blocks: blocks,
                    sourceWidth: width,
                    sourceHeight: height,
                    source: source
                ))
            }
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
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
