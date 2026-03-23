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
        isCapturing = true
        defer { isCapturing = false }
        do {
            lastCapture = try await screenshotManager.captureFullScreen()
        } catch {
            print("Full screen capture failed: \(error.localizedDescription)")
        }
    }

    func captureWindow() async {
        isCapturing = true
        defer { isCapturing = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.isOnScreen }) else {
                print("No window available to capture")
                return
            }
            lastCapture = try await screenshotManager.captureWindow(window)
        } catch {
            print("Window capture failed: \(error.localizedDescription)")
        }
    }

    func captureRegion() async {
        isCapturing = true
        defer { isCapturing = false }
        do {
            // TODO: In Phase 2, replace with interactive region selector
            let region = CGRect(x: 100, y: 100, width: 800, height: 600)
            lastCapture = try await screenshotManager.captureRegion(region)
        } catch {
            print("Region capture failed: \(error.localizedDescription)")
        }
    }

    func copyToClipboard() {
        guard let image = lastCapture else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    func saveToDesktop() {
        guard let image = lastCapture,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileURL = desktopURL.appendingPathComponent("ScreenMuse_\(timestamp).png")
        do {
            try pngData.write(to: fileURL)
            print("Saved screenshot to \(fileURL.path)")
        } catch {
            print("Failed to save screenshot: \(error.localizedDescription)")
        }
    }
}
