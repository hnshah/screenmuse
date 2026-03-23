import AppKit
import ScreenMuseCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check permissions and warn if missing
        let hasScreen = CGPreflightScreenCaptureAccess()
        let hasAccessibility = AXIsProcessTrusted()

        if !hasScreen {
            showPermissionAlert()
        }

        if !hasAccessibility {
            print("⚠️ ScreenMuse: Accessibility not granted — keyboard overlays disabled")
        }

        // Start agent API server on port 7823
        Task { @MainActor in
            do {
                try ScreenMuseServer.shared.start()
                print("ScreenMuse agent API running on http://localhost:7823")
            } catch {
                print("Failed to start agent API server: \(error)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            ScreenMuseServer.shared.stop()
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        ScreenMuse needs Screen Recording permission to capture your screen.

        Click "Open System Settings" to grant access, then relaunch the app.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
    }
}
