import AppKit
import ScreenCaptureKit
import ScreenMuseCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start agent API server on port 7823
        Task { @MainActor in
            do {
                try ScreenMuseServer.shared.start()
                print("ScreenMuse agent API running on http://localhost:7823")
            } catch {
                print("Failed to start agent API server: \(error)")
            }
        }

        // Request screen capture permission
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                print("Screen capture permission not granted: \(error.localizedDescription)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            ScreenMuseServer.shared.stop()
        }
    }
}
