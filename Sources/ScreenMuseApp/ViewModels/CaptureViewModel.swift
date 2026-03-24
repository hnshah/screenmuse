import AppKit
import SwiftUI
import ScreenCaptureKit
import ScreenMuseCore

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var lastCapture: NSImage?
    @Published var isCapturing = false

    private let screenshotManager = ScreenshotManager()

    func captureFullScreen() async {
        smLog.info("CaptureViewModel: captureFullScreen()", category: .capture)
        isCapturing = true
        defer { isCapturing = false }
        do {
            lastCapture = try await screenshotManager.captureFullScreen()
            smLog.info("CaptureViewModel: Full screen capture succeeded", category: .capture)
        } catch {
            smLog.error("CaptureViewModel: Full screen capture failed: \(error.localizedDescription)", category: .capture)
        }
    }

    func captureWindow() async {
        smLog.info("CaptureViewModel: captureWindow()", category: .capture)
        isCapturing = true
        defer { isCapturing = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.isOnScreen }) else {
                smLog.warning("CaptureViewModel: No on-screen window available to capture", category: .capture)
                return
            }
            smLog.debug("CaptureViewModel: Capturing window '\(window.title ?? "?")'", category: .capture)
            lastCapture = try await screenshotManager.captureWindow(window)
            smLog.info("CaptureViewModel: Window capture succeeded", category: .capture)
        } catch {
            smLog.error("CaptureViewModel: Window capture failed: \(error.localizedDescription)", category: .capture)
        }
    }

    func captureRegion() async {
        smLog.info("CaptureViewModel: captureRegion()", category: .capture)
        isCapturing = true
        defer { isCapturing = false }
        do {
            // TODO: In Phase 2, replace with interactive region selector
            let region = CGRect(x: 100, y: 100, width: 800, height: 600)
            smLog.debug("CaptureViewModel: Capturing region \(region)", category: .capture)
            lastCapture = try await screenshotManager.captureRegion(region)
            smLog.info("CaptureViewModel: Region capture succeeded", category: .capture)
        } catch {
            smLog.error("CaptureViewModel: Region capture failed: \(error.localizedDescription)", category: .capture)
        }
    }

    func copyToClipboard() {
        guard let image = lastCapture else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        smLog.info("CaptureViewModel: Image copied to clipboard", category: .capture)
    }

    func saveToDesktop() {
        guard let image = lastCapture,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            smLog.warning("CaptureViewModel: saveToDesktop — no image or conversion failed", category: .capture)
            return
        }
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileURL = desktopURL.appendingPathComponent("ScreenMuse_\(timestamp).png")
        do {
            try pngData.write(to: fileURL)
            smLog.info("CaptureViewModel: Screenshot saved to \(fileURL.path)", category: .capture)
        } catch {
            smLog.error("CaptureViewModel: Failed to save screenshot: \(error.localizedDescription)", category: .capture)
        }
    }
}
