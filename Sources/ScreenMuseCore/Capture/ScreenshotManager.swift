import AppKit
import ScreenCaptureKit
import CoreMedia

public final class ScreenshotManager: Sendable {
    public init() {}

    public func captureFullScreen() async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw ScreenshotError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter,
            configuration: config
        )

        return try imageFromSampleBuffer(sampleBuffer)
    }

    public func captureWindow(_ window: SCWindow) async throws -> NSImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter,
            configuration: config
        )

        return try imageFromSampleBuffer(sampleBuffer)
    }

    public func captureRegion(_ rect: CGRect) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw ScreenshotError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width) * 2
        config.height = Int(rect.height) * 2
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter,
            configuration: config
        )

        return try imageFromSampleBuffer(sampleBuffer)
    }

    private func imageFromSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws -> NSImage {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ScreenshotError.invalidImageData
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw ScreenshotError.imageConversionFailed
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}

public enum ScreenshotError: Error, LocalizedError {
    case noDisplayFound
    case invalidImageData
    case imageConversionFailed

    public var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for capture"
        case .invalidImageData:
            return "Failed to extract image data from sample buffer"
        case .imageConversionFailed:
            return "Failed to convert pixel buffer to image"
        }
    }
}
