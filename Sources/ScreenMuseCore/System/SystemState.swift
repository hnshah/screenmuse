import AppKit
import Foundation

/// System state queries — the things Playwright can't see.
///
/// These endpoints give agents environmental awareness:
/// what's on the clipboard, what window has focus, what apps are running.
/// All are read-only and require no special permissions.

public final class SystemState {

    // MARK: - Clipboard

    /// Read the current clipboard contents.
    /// Returns text if available; image dimensions if it's an image; raw type list otherwise.
    public static func clipboardContents() -> [String: Any] {
        let pasteboard = NSPasteboard.general
        var result: [String: Any] = [
            "change_count": pasteboard.changeCount
        ]

        // Text content (most common)
        if let text = pasteboard.string(forType: .string) {
            result["type"] = "text"
            result["text"] = text
            result["length"] = text.count
            smLog.debug("Clipboard: text (\(text.count) chars)", category: .general)
            return result
        }

        // HTML content
        if let html = pasteboard.string(forType: .html) {
            result["type"] = "html"
            result["html"] = html
            result["length"] = html.count
            smLog.debug("Clipboard: html (\(html.count) chars)", category: .general)
            return result
        }

        // URL
        if let urlStr = pasteboard.string(forType: .URL) {
            result["type"] = "url"
            result["url"] = urlStr
            smLog.debug("Clipboard: URL", category: .general)
            return result
        }

        // Image
        if let image = NSImage(pasteboard: pasteboard) {
            result["type"] = "image"
            result["width"] = image.size.width
            result["height"] = image.size.height
            smLog.debug("Clipboard: image \(image.size)", category: .general)
            return result
        }

        // File URLs
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty {
            result["type"] = "files"
            result["paths"] = fileURLs.map { $0.path }
            result["count"] = fileURLs.count
            smLog.debug("Clipboard: \(fileURLs.count) file(s)", category: .general)
            return result
        }

        // Fallback: just list the types
        result["type"] = "unknown"
        result["available_types"] = pasteboard.types?.map { $0.rawValue } ?? []
        smLog.debug("Clipboard: unknown type(s)", category: .general)
        return result
    }

    // MARK: - Running Apps

    /// List all regular (user-visible) running applications.
    public static func runningApps() -> [[String: Any]] {
        smLog.debug("SystemState.runningApps()", category: .general)
        return WindowManager.listRunningApps().map { $0.asDictionary() }
    }

    // MARK: - Active Window

    /// The frontmost application and its focused window info.
    public static func activeWindow() -> [String: Any] {
        smLog.debug("SystemState.activeWindow()", category: .general)
        return WindowManager.activeWindowInfo()
    }
}
