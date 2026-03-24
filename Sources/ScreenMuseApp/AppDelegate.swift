import AppKit
import ScreenMuseCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        smLog.info("applicationDidFinishLaunching", category: .lifecycle)

        // Check permissions and warn if missing
        let hasScreen = CGPreflightScreenCaptureAccess()
        let hasAccessibility = AXIsProcessTrusted()

        smLog.info("Permission status — screenRecording=\(hasScreen) accessibility=\(hasAccessibility)", category: .permissions)

        if !hasScreen {
            smLog.warning("Screen Recording permission NOT granted — showing alert", category: .permissions)
            showPermissionAlert()
        }

        if !hasAccessibility {
            smLog.warning("Accessibility permission NOT granted — keyboard overlays will be disabled", category: .permissions)
        }

        // Start agent API server on port 7823
        // Connect to RecordViewModel.shared so API calls get the full effects pipeline
        Task { @MainActor in
            do {
                ScreenMuseServer.shared.coordinator = RecordViewModel.shared
                smLog.info("Coordinator wired to RecordViewModel.shared", category: .server)
                try ScreenMuseServer.shared.start()
                smLog.info("Agent API server started on http://localhost:7823 (effects pipeline: enabled)", category: .server)
                smLog.info("Log file: \(smLog.logFilePath)", category: .lifecycle)
            } catch {
                smLog.error("Failed to start agent API server: \(error.localizedDescription)", category: .server)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        smLog.info("applicationWillTerminate — stopping server", category: .lifecycle)
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
            smLog.info("User opened System Settings for Screen Recording permission", category: .permissions)
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        } else {
            smLog.warning("User dismissed Screen Recording permission alert", category: .permissions)
        }
    }
}
