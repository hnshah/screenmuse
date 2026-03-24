import AppKit
import Foundation

/// Window management utilities — focus, position, hide-others, list.
///
/// These are the native macOS primitives Playwright can't reach.
/// They make ScreenMuse the ideal recording partner for any automation tool.
///
/// Permission notes:
///   focus()        — no special permission required (NSRunningApplication.activate)
///   position()     — requires Accessibility (AXIsProcessTrusted) to set frame via AX
///   hideOthers()   — no special permission required (NSRunningApplication.hide)
///   list()         — no special permission required

public enum WindowError: Error, LocalizedError {
    case appNotFound(String)
    case noWindowAvailable(String)
    case accessibilityRequired
    case positionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let name):
            return "App not found: '\(name)'. Check GET /system/running-apps for available apps."
        case .noWindowAvailable(let name):
            return "No visible window found for '\(name)'. Make sure the app is open and has at least one window."
        case .accessibilityRequired:
            return "Window positioning requires Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility."
        case .positionFailed(let reason):
            return "Failed to position window: \(reason)"
        }
    }
}

public struct WindowInfo: Sendable {
    public let appName: String
    public let bundleID: String
    public let pid: Int32
    public let isActive: Bool
    public let isHidden: Bool

    public func asDictionary() -> [String: Any] {
        [
            "app": appName,
            "bundle_id": bundleID,
            "pid": pid,
            "is_active": isActive,
            "is_hidden": isHidden
        ]
    }
}

public final class WindowManager {

    // MARK: - App Resolution

    /// Resolve an app by display name OR bundle identifier.
    /// Supports: "Notes", "Google Chrome", "com.apple.Notes", "com.google.Chrome"
    public static func findApp(named query: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        // Exact bundle ID match first
        if let app = apps.first(where: { $0.bundleIdentifier == query }) {
            return app
        }
        // Exact display name match
        if let app = apps.first(where: { $0.localizedName == query }) {
            return app
        }
        // Case-insensitive display name
        if let app = apps.first(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare(query) == .orderedSame
        }) {
            return app
        }
        // Partial display name (e.g. "Chrome" matches "Google Chrome")
        return apps.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(query) ?? false
        })
    }

    // MARK: - Focus

    /// Bring an app's window to the front.
    /// Does NOT require Accessibility permission.
    public static func focus(app query: String) throws {
        smLog.info("WindowManager.focus('\(query)')", category: .capture)
        guard let app = findApp(named: query) else {
            smLog.error("focus: app not found — '\(query)'", category: .capture)
            throw WindowError.appNotFound(query)
        }
        app.activate(options: .activateIgnoringOtherApps)
        smLog.info("Activated '\(app.localizedName ?? query)' (pid=\(app.processIdentifier))", category: .capture)
    }

    // MARK: - Position

    /// Move and resize an app's frontmost window.
    /// Requires Accessibility permission (AXIsProcessTrusted).
    ///
    /// - Parameters:
    ///   - query: App name or bundle ID
    ///   - x, y: Screen coordinates (top-left origin, like CGRect)
    ///   - width, height: Desired window size
    public static func position(app query: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) throws {
        smLog.info("WindowManager.position('\(query)') → (\(x),\(y)) \(Int(width))×\(Int(height))", category: .capture)

        guard AXIsProcessTrusted() else {
            smLog.error("position: Accessibility permission not granted", category: .permissions)
            throw WindowError.accessibilityRequired
        }

        guard let app = findApp(named: query) else {
            smLog.error("position: app not found — '\(query)'", category: .capture)
            throw WindowError.appNotFound(query)
        }

        // Bring to front first so the window is accessible
        app.activate(options: .activateIgnoringOtherApps)

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowsValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success, let windows = windowsValue as? [AXUIElement], let window = windows.first else {
            smLog.error("position: no AX windows for '\(app.localizedName ?? query)'", category: .capture)
            throw WindowError.noWindowAvailable(query)
        }

        var pos = CGPoint(x: x, y: y)
        var size = CGSize(width: width, height: height)

        if let posValue = AXValueCreate(.cgPoint, &pos) {
            let r = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            if r != .success { smLog.warning("AX set position returned \(r.rawValue)", category: .capture) }
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            let r = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            if r != .success { smLog.warning("AX set size returned \(r.rawValue)", category: .capture) }
        }

        smLog.info("Positioned '\(app.localizedName ?? query)' to (\(x),\(y)) \(Int(width))×\(Int(height))", category: .capture)
    }

    // MARK: - Hide Others

    /// Hide all running apps EXCEPT the named target.
    /// Equivalent to Option-clicking in the Dock — clears visual clutter before recording.
    /// Does NOT require Accessibility permission.
    ///
    /// - Parameters:
    ///   - keepVisible: App name or bundle ID to keep visible (plus ScreenMuse itself)
    public static func hideOthers(keeping query: String) throws {
        smLog.info("WindowManager.hideOthers(keeping: '\(query)')", category: .capture)

        guard let targetApp = findApp(named: query) else {
            smLog.error("hideOthers: app not found — '\(query)'", category: .capture)
            throw WindowError.appNotFound(query)
        }

        let selfBundleID = Bundle.main.bundleIdentifier ?? ""
        var hiddenCount = 0

        for app in NSWorkspace.shared.runningApplications {
            // Skip the target, ScreenMuse itself, and background-only apps (Dock, menubar agents)
            guard app.processIdentifier != targetApp.processIdentifier,
                  app.bundleIdentifier != selfBundleID,
                  app.activationPolicy == .regular,
                  !app.isHidden else {
                continue
            }
            app.hide()
            hiddenCount += 1
            smLog.debug("Hidden: \(app.localizedName ?? app.bundleIdentifier ?? "?")", category: .capture)
        }

        smLog.info("hideOthers: hid \(hiddenCount) apps, kept '\(targetApp.localizedName ?? query)' visible", category: .capture)
    }

    // MARK: - List

    /// Returns all regular (non-background) running apps.
    public static func listRunningApps() -> [WindowInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                WindowInfo(
                    appName: app.localizedName ?? "Unknown",
                    bundleID: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    isActive: app.isActive,
                    isHidden: app.isHidden
                )
            }
    }

    // MARK: - Active Window

    /// Returns the frontmost app and its focused window title (if accessible).
    public static func activeWindowInfo() -> [String: Any] {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return ["error": "No frontmost application"]
        }

        var info: [String: Any] = [
            "app": frontApp.localizedName ?? "Unknown",
            "bundle_id": frontApp.bundleIdentifier ?? "",
            "pid": frontApp.processIdentifier
        ]

        // Try to get window title + frame via AX (best-effort — may fail without permission)
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
            var focusedWindowRef: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
               focusedWindowRef != nil {
                let axWindow = focusedWindowRef as! AXUIElement  // Safe: .success guarantees AXUIElement
                // Window title
                var titleRef: AnyObject?
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String {
                    info["window_title"] = title
                }
                // Window position
                var posRef: AnyObject?
                if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
                   let axPosValue = posRef,
                   CFGetTypeID(axPosValue) == AXValueGetTypeID() {
                    var pos = CGPoint.zero
                    AXValueGetValue(axPosValue as! AXValue, .cgPoint, &pos)
                    info["window_x"] = pos.x
                    info["window_y"] = pos.y
                }
                // Window size
                var sizeRef: AnyObject?
                if AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let axSizeValue = sizeRef,
                   CFGetTypeID(axSizeValue) == AXValueGetTypeID() {
                    var size = CGSize.zero
                    AXValueGetValue(axSizeValue as! AXValue, .cgSize, &size)
                    info["window_width"] = size.width
                    info["window_height"] = size.height
                }
            }
        } else {
            info["note"] = "Window title/frame unavailable — grant Accessibility permission for full info"
        }

        return info
    }
}
