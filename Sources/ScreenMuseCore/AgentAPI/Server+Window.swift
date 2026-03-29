import Foundation
import Network
@preconcurrency import ScreenCaptureKit

// MARK: - Window Handlers (/windows, /window/focus, /window/position, /window/hide-others)

extension ScreenMuseServer {

    func handleWindows(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] Enumerating on-screen windows", category: .capture)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windows: [[String: Any]] = content.windows.compactMap { window in
                guard let title = window.title, !title.isEmpty else { return nil }
                var entry: [String: Any] = [
                    "title": title,
                    "app": window.owningApplication?.applicationName ?? "Unknown",
                    "bundle_id": window.owningApplication?.bundleIdentifier ?? "",
                    "on_screen": window.isOnScreen,
                    "bounds": [
                        "x": window.frame.origin.x,
                        "y": window.frame.origin.y,
                        "width": window.frame.width,
                        "height": window.frame.height
                    ]
                ]
                if let pid = window.owningApplication?.processID {
                    entry["pid"] = pid
                }
                return entry
            }
            smLog.info("[\(reqID)] Found \(windows.count) windows", category: .capture)
            sendResponse(connection: connection, status: 200, body: ["windows": windows, "count": windows.count])
        } catch {
            smLog.error("[\(reqID)] /windows failed: \(error.localizedDescription)", category: .capture)
            sendResponse(connection: connection, status: 500, body: structuredError(error))
        }
    }

    func handleWindowFocus(body: [String: Any], connection: NWConnection, reqID: Int) {
        let appName = body["app"] as? String ?? ""
        guard !appName.isEmpty else {
            smLog.warning("[\(reqID)] /window/focus missing 'app' field", category: .server)
            sendResponse(connection: connection, status: 400, body: [
                "error": "body must include 'app' field",
                "example": "{\"app\": \"Notes\"}",
                "tip": "Use app display name (\"Notes\", \"Google Chrome\") or bundle ID (\"com.apple.Notes\")"
            ])
            return
        }
        smLog.info("[\(reqID)] /window/focus app='\(appName)'", category: .server)
        do {
            try WindowManager.focus(app: appName)
            let resolvedName = WindowManager.findApp(named: appName)?.localizedName ?? appName
            smLog.usage("WINDOW FOCUS", details: ["app": resolvedName])
            sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "app": resolvedName
            ])
        } catch let err as WindowError {
            smLog.error("[\(reqID)] /window/focus failed: \(err.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 404, body: [
                "error": err.errorDescription ?? err.localizedDescription,
                "code": "APP_NOT_FOUND"
            ])
        } catch {
            smLog.error("[\(reqID)] /window/focus error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleWindowPosition(body: [String: Any], connection: NWConnection, reqID: Int) {
        let appName = body["app"] as? String ?? ""
        guard !appName.isEmpty else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "body must include 'app'",
                "example": "{\"app\":\"Google Chrome\",\"x\":0,\"y\":0,\"width\":1440,\"height\":900}"
            ])
            return
        }
        let x = body["x"] as? CGFloat ?? (body["x"] as? Double).map { CGFloat($0) } ?? 0
        let y = body["y"] as? CGFloat ?? (body["y"] as? Double).map { CGFloat($0) } ?? 0
        let width = body["width"] as? CGFloat ?? (body["width"] as? Double).map { CGFloat($0) } ?? 1440
        let height = body["height"] as? CGFloat ?? (body["height"] as? Double).map { CGFloat($0) } ?? 900
        smLog.info("[\(reqID)] /window/position app='\(appName)' x=\(x) y=\(y) \(Int(width))×\(Int(height))", category: .server)
        do {
            try WindowManager.position(app: appName, x: x, y: y, width: width, height: height)
            let resolvedName = WindowManager.findApp(named: appName)?.localizedName ?? appName
            smLog.usage("WINDOW POSITION", details: ["app": resolvedName, "size": "\(Int(width))×\(Int(height))", "pos": "(\(Int(x)),\(Int(y)))"])
            sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "app": resolvedName,
                "x": x, "y": y, "width": width, "height": height
            ])
        } catch let err as WindowError {
            let code: String
            switch err {
            case .accessibilityRequired: code = "ACCESSIBILITY_REQUIRED"
            case .appNotFound: code = "APP_NOT_FOUND"
            case .noWindowAvailable: code = "NO_WINDOW"
            default: code = "WINDOW_ERROR"
            }
            smLog.error("[\(reqID)] /window/position failed [\(code)]: \(err.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 400, body: [
                "error": err.errorDescription ?? err.localizedDescription,
                "code": code
            ])
        } catch {
            smLog.error("[\(reqID)] /window/position error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleWindowHideOthers(body: [String: Any], connection: NWConnection, reqID: Int) {
        let appName = body["app"] as? String ?? ""
        guard !appName.isEmpty else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "body must include 'app'",
                "example": "{\"app\": \"Notes\"}"
            ])
            return
        }
        smLog.info("[\(reqID)] /window/hide-others keeping='\(appName)'", category: .server)
        do {
            try WindowManager.hideOthers(keeping: appName)
            let resolvedName = WindowManager.findApp(named: appName)?.localizedName ?? appName
            smLog.usage("HIDE OTHERS", details: ["keeping": resolvedName])
            sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "kept_visible": resolvedName
            ])
        } catch let err as WindowError {
            smLog.error("[\(reqID)] /window/hide-others failed: \(err.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 404, body: [
                "error": err.errorDescription ?? err.localizedDescription,
                "code": "APP_NOT_FOUND"
            ])
        } catch {
            smLog.error("[\(reqID)] /window/hide-others error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }
}
