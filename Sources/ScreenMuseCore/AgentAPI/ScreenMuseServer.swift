import Foundation
import Network
import ScreenCaptureKit
import AppKit

// Local HTTP server for programmatic agent control
// Endpoints:
//   POST /start           body: {"name": "recording-name"}               → {"session_id": "uuid", "status": "recording"}
//   POST /stop            → {"video_path": "/path/video.mp4", "metadata": {...}}
//   POST /pause           → {"status": "paused", "elapsed": N}
//   POST /resume          → {"status": "recording", "elapsed": N}
//   POST /chapter         body: {"name": "Chapter name"}                 → {"ok": true, "time": N}
//   POST /highlight       → {"ok": true}
//   POST /screenshot      body: {"path": "/optional/path.png"}           → {"path": "...", "width": N, "height": N}
//   POST /note            body: {"text": "something felt wrong here"}    → {"ok": true, "timestamp": "..."}
//   POST /export          body: {"format":"gif","fps":10,"scale":800,"start":0,"end":30} → {"path":...,"frames":N,"size_mb":N}
//
//   -- Window Management (native macOS, Playwright can't do these) --
//   POST /window/focus    body: {"app": "Notes"}                         → {"ok": true, "app": "Notes"}
//   POST /window/position body: {"app": "Notes", "x":0,"y":0,"width":1440,"height":900} → {"ok": true}
//   POST /window/hide-others body: {"app": "Notes"}                      → {"ok": true, "hidden": N}
//
//   -- System State --
//   GET  /system/clipboard      → {"type": "text", "text": "...", "length": N}
//   GET  /system/active-window  → {"app": "...", "window_title": "...", "bundle_id": "..."}
//   GET  /system/running-apps   → {"apps": [...], "count": N}
//
//   GET  /status      → {"recording": bool, "elapsed": N, "chapters": [...]}
//   GET  /windows     → {"windows": [...], "count": N}
//   GET  /version     → {"version": "0.5.0", "build": "...", "api_endpoints": [...]}
//   GET  /debug       → save dir, recent files, server state
//   GET  /logs        → recent log entries from ScreenMuseLogger ring buffer
//   GET  /report      → clean session report for bug reports

@MainActor
public class ScreenMuseServer {
    public static let shared = ScreenMuseServer()

    private var listener: NWListener?
    // recordingManager used when coordinator is not set (e.g. headless/test mode)
    private let recordingManager = RecordingManager()
    /// Set this at app launch to route API calls through the full effects pipeline.
    /// When set, /start and /stop go through RecordViewModel (effects compositing included).
    /// When nil, falls back to raw RecordingManager (no effects).
    public weak var coordinator: RecordingCoordinating?

    public private(set) var isRecording = false
    public private(set) var sessionName: String?
    public private(set) var sessionID: String?
    public private(set) var startTime: Date?
    public private(set) var currentVideoURL: URL?
    public private(set) var chapters: [(name: String, time: TimeInterval)] = []
    public private(set) var highlightNextClick = false

    private var requestCount = 0

    public func start() throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: 7823)
        listener?.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.handleConnection(conn)
            }
        }
        listener?.start(queue: .main)
        smLog.info("NWListener started on port 7823", category: .server)
    }

    public func stop() {
        listener?.cancel()
        smLog.info("NWListener stopped", category: .server)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(connection)
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty else {
                if let error { smLog.debug("Connection closed with error: \(error)", category: .server) }
                connection.cancel()
                return
            }
            Task { @MainActor in
                await self.processHTTPRequest(data: data, connection: connection)
            }
        }
    }

    private func processHTTPRequest(data: Data, connection: NWConnection) async {
        requestCount += 1
        let reqID = requestCount

        guard let raw = String(data: data, encoding: .utf8) else {
            smLog.error("[\(reqID)] Bad request — could not decode UTF-8", category: .server)
            sendResponse(connection: connection, status: 400, body: ["error": "bad request"])
            return
        }

        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let method = parts[0]
        let path = parts[1]

        // Parse JSON body
        var body: [String: Any] = [:]
        if let blankLine = lines.firstIndex(of: ""), blankLine + 1 < lines.count {
            let bodyStr = lines[(blankLine + 1)...].joined(separator: "\r\n")
            if let bodyData = bodyStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                body = json
            }
        }

        smLog.info("[\(reqID)] → \(method) \(path) body=\(body.isEmpty ? "{}" : "\(body)")", category: .server)

        switch (method, path) {

        case ("POST", "/start"):
            guard !isRecording else {
                smLog.warning("[\(reqID)] /start rejected — already recording session=\(sessionID ?? "?")", category: .server)
                sendResponse(connection: connection, status: 409, body: [
                    "error": "Already recording",
                    "code": "ALREADY_RECORDING",
                    "suggestion": "Call POST /stop first to stop the current recording"
                ])
                return
            }
            let name = body["name"] as? String ?? "recording-\(Date().timeIntervalSince1970)"
            let windowTitle = body["window_title"] as? String
            let windowPid = body["window_pid"] as? Int
            let quality = body["quality"] as? String
            smLog.info("[\(reqID)] Starting recording name='\(name)' quality=\(quality ?? "medium") windowTitle=\(windowTitle ?? "nil") windowPid=\(windowPid.map { "\($0)" } ?? "nil")", category: .server)
            do {
                if let coord = coordinator {
                    smLog.debug("[\(reqID)] Routing through coordinator (effects pipeline)", category: .server)
                    try await coord.startRecording(name: name, windowTitle: windowTitle, windowPid: windowPid, quality: quality)
                } else {
                    smLog.warning("[\(reqID)] No coordinator set — falling back to raw RecordingManager (no effects)", category: .server)
                    let source: CaptureSource
                    if let title = windowTitle {
                        smLog.debug("[\(reqID)] Looking up window: '\(title)'", category: .capture)
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        if let window = content.windows.first(where: { $0.title?.localizedCaseInsensitiveContains(title) ?? false }) {
                            smLog.info("[\(reqID)] Found window: '\(window.title ?? "?")' pid=\(window.owningApplication?.processID ?? 0)", category: .capture)
                            source = .window(window)
                        } else {
                            smLog.error("[\(reqID)] Window not found: '\(title)'", category: .capture)
                            sendResponse(connection: connection, status: 404, body: [
                                "error": "Window not found: '\(title)'",
                                "code": "WINDOW_NOT_FOUND",
                                "suggestion": "Call GET /windows to see available windows"
                            ])
                            return
                        }
                    } else {
                        smLog.debug("[\(reqID)] Using full screen capture", category: .capture)
                        source = .fullScreen
                    }
                    let resolvedQuality = RecordingConfig.Quality(rawValue: quality ?? "medium") ?? .medium
                    let config = RecordingConfig(captureSource: source, includeSystemAudio: true, quality: resolvedQuality)
                    try await recordingManager.startRecording(config: config)
                }
                sessionID = UUID().uuidString
                sessionName = name
                startTime = Date()
                isRecording = true
                chapters = []
                highlightNextClick = false
                currentVideoURL = nil
                var resp: [String: Any] = [
                    "session_id": sessionID!,
                    "status": "recording",
                    "name": name,
                    "quality": quality ?? "medium"
                ]
                if let wt = windowTitle { resp["window_title"] = wt }
                if let wp = windowPid { resp["window_pid"] = wp }
                smLog.info("[\(reqID)] ✅ Recording started — session=\(sessionID!)", category: .server)
                var usageDetails: [String: String] = ["name": name, "quality": quality ?? "medium", "session": sessionID!]
                if let wt = windowTitle { usageDetails["window"] = wt }
                smLog.usage("RECORD START", details: usageDetails)
                sendResponse(connection: connection, status: 200, body: resp)
            } catch let err as RecordingError {
                smLog.error("[\(reqID)] /start failed (RecordingError): \(err.errorDescription ?? "\(err)")", category: .server)
                smLog.usage("RECORD ERROR", details: ["code": "RecordingError", "reason": err.errorDescription ?? "\(err)"])
                sendResponse(connection: connection, status: 500, body: structuredError(err))
            } catch {
                smLog.error("[\(reqID)] /start failed (unknown): \(error.localizedDescription)", category: .server)
                smLog.usage("RECORD ERROR", details: ["code": "unknown", "reason": error.localizedDescription])
                sendResponse(connection: connection, status: 500, body: [
                    "error": error.localizedDescription,
                    "code": "UNKNOWN_ERROR"
                ])
            }

        case ("POST", "/stop"):
            guard isRecording else {
                smLog.warning("[\(reqID)] /stop rejected — not currently recording", category: .server)
                sendResponse(connection: connection, status: 409, body: ["error": "not recording"])
                return
            }
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            smLog.info("[\(reqID)] Stopping recording session=\(sessionID ?? "?") elapsed=\(String(format: "%.1f", elapsed))s chapters=\(chapters.count)", category: .server)
            let metadata: [String: Any] = [
                "session_id": sessionID ?? "",
                "name": sessionName ?? "",
                "elapsed": elapsed,
                "chapters": chapters.map { ["name": $0.name, "time": $0.time] }
            ]
            let capturedSessionID = sessionID
            let capturedSessionName = sessionName
            sessionID = nil
            sessionName = nil
            startTime = nil
            isRecording = false

            if let coord = coordinator {
                smLog.debug("[\(reqID)] Awaiting coordinator.stopAndGetVideo() — effects compositing in progress...", category: .server)
                smLog.usage("EFFECTS COMPOSITING  started — applying zoom + click effects to raw video")
                if let url = await coord.stopAndGetVideo() {
                    currentVideoURL = url
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576)
                    smLog.info("[\(reqID)] ✅ Video ready: \(url.path)", category: .server)
                    smLog.usage("RECORD STOP", details: [
                        "elapsed": String(format: "%.0fs", elapsed),
                        "chapters": "\(chapters.count)",
                        "size": "\(sizeMB)MB",
                        "video": url.lastPathComponent
                    ])
                    sendResponse(connection: connection, status: 200, body: [
                        "video_path": url.path,
                        "metadata": metadata
                    ])
                } else {
                    smLog.error("[\(reqID)] coordinator.stopAndGetVideo() returned nil — video finalization failed", category: .server)
                    smLog.usage("RECORD ERROR  Video finalization failed — coordinator returned nil")
                    sendResponse(connection: connection, status: 500, body: ["error": "Recording stopped but video could not be finalized"])
                }
            } else {
                smLog.debug("[\(reqID)] No coordinator — using raw RecordingManager.stopRecording()", category: .server)
                do {
                    let url = try await recordingManager.stopRecording()
                    currentVideoURL = url
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576)
                    smLog.info("[\(reqID)] ✅ Video saved: \(url.path)", category: .server)
                    smLog.usage("RECORD STOP (raw)", details: [
                        "elapsed": String(format: "%.0fs", elapsed),
                        "size": "\(sizeMB)MB",
                        "video": url.lastPathComponent
                    ])
                    sendResponse(connection: connection, status: 200, body: [
                        "video_path": url.path,
                        "metadata": metadata
                    ])
                } catch {
                    smLog.error("[\(reqID)] stopRecording() threw: \(error.localizedDescription)", category: .server)
                    smLog.usage("RECORD ERROR  \(error.localizedDescription)")
                    sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
                }
            }
            _ = capturedSessionID
            _ = capturedSessionName

        case ("POST", "/pause"):
            guard isRecording else {
                smLog.warning("[\(reqID)] /pause rejected — not recording", category: .server)
                sendResponse(connection: connection, status: 409, body: ["error": "Not recording", "code": "NOT_RECORDING"])
                return
            }
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            smLog.info("[\(reqID)] Pausing at elapsed=\(String(format: "%.1f", elapsed))s", category: .server)
            do {
                if let coord = coordinator {
                    try await coord.pauseRecording()
                } else {
                    try await recordingManager.pauseRecording()
                }
                smLog.info("[\(reqID)] ✅ Paused", category: .server)
                smLog.usage("PAUSED", details: ["at": String(format: "%.0fs", elapsed)])
                sendResponse(connection: connection, status: 200, body: ["status": "paused", "elapsed": elapsed])
            } catch {
                smLog.error("[\(reqID)] /pause failed: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: structuredError(error))
            }

        case ("POST", "/resume"):
            guard isRecording else {
                smLog.warning("[\(reqID)] /resume rejected — not recording", category: .server)
                sendResponse(connection: connection, status: 409, body: ["error": "Not recording", "code": "NOT_RECORDING"])
                return
            }
            smLog.info("[\(reqID)] Resuming recording", category: .server)
            do {
                if let coord = coordinator {
                    try await coord.resumeRecording()
                } else {
                    try await recordingManager.resumeRecording()
                }
                let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                smLog.info("[\(reqID)] ✅ Resumed at elapsed=\(String(format: "%.1f", elapsed))s", category: .server)
                smLog.usage("RESUMED", details: ["at": String(format: "%.0fs", elapsed)])
                sendResponse(connection: connection, status: 200, body: ["status": "recording", "elapsed": elapsed])
            } catch {
                smLog.error("[\(reqID)] /resume failed: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: structuredError(error))
            }

        case ("POST", "/chapter"):
            let name = body["name"] as? String ?? "Chapter"
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            chapters.append((name: name, time: elapsed))
            smLog.info("[\(reqID)] Chapter '\(name)' at \(String(format: "%.1f", elapsed))s (total chapters: \(chapters.count))", category: .server)
            smLog.usage("CHAPTER", details: ["name": name, "at": String(format: "%.0fs", elapsed), "total": "\(chapters.count)"])
            sendResponse(connection: connection, status: 200, body: ["ok": true, "time": elapsed])

        case ("POST", "/highlight"):
            highlightNextClick = true
            smLog.info("[\(reqID)] Highlight flag set — next click will be highlighted", category: .server)
            smLog.usage("HIGHLIGHT  next click flagged for auto-zoom + enhanced effect")
            sendResponse(connection: connection, status: 200, body: ["ok": true])

        // MARK: - Window Management

        case ("POST", "/window/focus"):
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

        case ("POST", "/window/position"):
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

        case ("POST", "/window/hide-others"):
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

        // MARK: - Export

        case ("POST", "/export"):
            smLog.info("[\(reqID)] /export request", category: .server)

            // Parse format
            let formatStr = body["format"] as? String ?? "gif"
            guard let format = GIFExporter.Config.Format(rawValue: formatStr.lowercased()) else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "Unsupported format '\(formatStr)'",
                    "code": "UNSUPPORTED_FORMAT",
                    "supported": ["gif", "webp"]
                ])
                return
            }

            // Resolve source video
            let sourceStr = body["source"] as? String ?? "last"
            let sourceURL: URL?
            if sourceStr == "last" {
                sourceURL = await viewModel.lastVideoURL
            } else {
                sourceURL = URL(fileURLWithPath: sourceStr)
            }
            guard let resolvedSource = sourceURL,
                  FileManager.default.fileExists(atPath: resolvedSource.path) else {
                smLog.warning("[\(reqID)] /export no video source (source='\(sourceStr)')", category: .server)
                sendResponse(connection: connection, status: 404, body: [
                    "error": "No video available. Record something first, or pass 'source' with a file path.",
                    "code": "NO_VIDEO"
                ])
                return
            }

            // Build config
            var config = GIFExporter.Config()
            config.format = format
            if let fps = body["fps"] as? Double { config.fps = fps }
            else if let fps = body["fps"] as? Int { config.fps = Double(fps) }
            if let scale = body["scale"] as? Int { config.scale = scale }
            else if let scale = body["scale"] as? Double { config.scale = Int(scale) }
            if let q = body["quality"] as? String,
               let quality = GIFExporter.Config.Quality(rawValue: q.lowercased()) {
                config.quality = quality
            }
            if let start = body["start"] as? Double,
               let end = body["end"] as? Double {
                config.timeRange = start...end
            } else if let start = body["start"] as? Double {
                config.timeRange = start...Double.infinity  // handled inside exporter
            }

            // Resolve output path
            let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

            let outputURL: URL
            if let customOutput = body["output"] as? String {
                outputURL = URL(fileURLWithPath: customOutput)
            } else {
                outputURL = GIFExporter.defaultOutputURL(for: resolvedSource, format: format, exportsDir: exportsDir)
            }

            smLog.info("[\(reqID)] /export source=\(resolvedSource.lastPathComponent) format=\(format.rawValue) fps=\(config.fps) scale=\(config.scale) quality=\(config.quality.rawValue) → \(outputURL.lastPathComponent)", category: .server)

            do {
                let exporter = GIFExporter()
                let result = try await exporter.export(
                    sourceURL: resolvedSource,
                    outputURL: outputURL,
                    config: config,
                    progress: { pct in
                        smLog.debug("[\(reqID)] /export progress \(Int(pct * 100))%", category: .server)
                    }
                )
                sendResponse(connection: connection, status: 200, body: result.asDictionary())
            } catch let err as GIFExporter.ExportError {
                smLog.error("[\(reqID)] /export failed: \(err.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: [
                    "error": err.errorDescription ?? err.localizedDescription,
                    "code": "EXPORT_FAILED"
                ])
            } catch {
                smLog.error("[\(reqID)] /export error: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        // MARK: - System State

        case ("GET", "/system/clipboard"):
            smLog.debug("[\(reqID)] /system/clipboard", category: .server)
            let contents = SystemState.clipboardContents()
            sendResponse(connection: connection, status: 200, body: contents)

        case ("GET", "/system/active-window"):
            smLog.debug("[\(reqID)] /system/active-window", category: .server)
            let info = SystemState.activeWindow()
            sendResponse(connection: connection, status: 200, body: info)

        case ("GET", "/system/running-apps"):
            smLog.debug("[\(reqID)] /system/running-apps", category: .server)
            let apps = SystemState.runningApps()
            sendResponse(connection: connection, status: 200, body: ["apps": apps, "count": apps.count])

        // MARK: - Status / Recording Control

        case ("GET", "/status"):
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            smLog.debug("[\(reqID)] /status — recording=\(isRecording) elapsed=\(String(format: "%.1f", elapsed))s", category: .server)
            sendResponse(connection: connection, status: 200, body: [
                "recording": isRecording,
                "elapsed": elapsed,
                "session_id": sessionID ?? "",
                "chapters": chapters.map { ["name": $0.name, "time": $0.time] },
                "last_video": currentVideoURL?.path ?? ""
            ])

        case ("GET", "/windows"):
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

        case ("POST", "/screenshot"):
            smLog.info("[\(reqID)] Screenshot requested path=\(body["path"] as? String ?? "(auto)")", category: .capture)
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    smLog.error("[\(reqID)] No display found for screenshot", category: .capture)
                    sendResponse(connection: connection, status: 500, body: ["error": "No display found"])
                    return
                }
                smLog.debug("[\(reqID)] Capture display \(display.width)x\(display.height)", category: .capture)
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.pixelFormat = kCVPixelFormatType_32BGRA

                let savePath: URL
                if let customPath = body["path"] as? String {
                    savePath = URL(fileURLWithPath: customPath)
                } else {
                    let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
                    let screenshotDir = moviesURL.appendingPathComponent("ScreenMuse/Screenshots", isDirectory: true)
                    try FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
                    let fileName = "screenshot-\(formatter.string(from: Date())).png".replacingOccurrences(of: ":", with: "-")
                    savePath = screenshotDir.appendingPathComponent(fileName)
                }

                if #available(macOS 14.0, *) {
                    smLog.debug("[\(reqID)] Calling SCScreenshotManager.captureImage()", category: .capture)
                    let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    guard let pngData = rep.representation(using: .png, properties: [:]) else {
                        smLog.error("[\(reqID)] PNG conversion failed", category: .capture)
                        sendResponse(connection: connection, status: 500, body: ["error": "PNG conversion failed"])
                        return
                    }
                    try pngData.write(to: savePath)
                    let sizeMB = String(format: "%.2f", Double(pngData.count) / 1_048_576)
                    smLog.info("[\(reqID)] ✅ Screenshot saved: \(savePath.path) (\(pngData.count) bytes, \(cgImage.width)x\(cgImage.height))", category: .capture)
                    smLog.usage("SCREENSHOT", details: ["file": savePath.lastPathComponent, "size": "\(sizeMB)MB", "resolution": "\(cgImage.width)x\(cgImage.height)"])
                    sendResponse(connection: connection, status: 200, body: [
                        "path": savePath.path,
                        "width": cgImage.width,
                        "height": cgImage.height,
                        "size": pngData.count
                    ])
                } else {
                    smLog.error("[\(reqID)] Screenshot API requires macOS 14+", category: .capture)
                    sendResponse(connection: connection, status: 400, body: ["error": "Screenshot API requires macOS 14+"])
                }
            } catch {
                smLog.error("[\(reqID)] /screenshot failed: \(error.localizedDescription)", category: .capture)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        case ("GET", "/debug"):
            smLog.debug("[\(reqID)] /debug requested", category: .server)
            let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse")
            var recentFiles: [String] = []
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: screenMuseDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            ) {
                recentFiles = contents
                    .filter { $0.pathExtension == "mp4" }
                    .sorted { ($0.path) > ($1.path) }
                    .prefix(5)
                    .map { $0.path }
            }
            sendResponse(connection: connection, status: 200, body: [
                "save_directory": screenMuseDir.path,
                "directory_exists": FileManager.default.fileExists(atPath: screenMuseDir.path),
                "recent_recordings": recentFiles,
                "last_video": currentVideoURL?.path ?? "",
                "server_recording": isRecording,
                "request_count": requestCount,
                "log_file": smLog.logFilePath,
                "log_buffer_count": smLog.bufferCount
            ])

        case ("POST", "/note"):
            // Drop a timestamped annotation into the usage log mid-session.
            // Vera (or an agent) calls this when something feels off — the note is
            // stamped exactly when it happened, not reconstructed from memory later.
            let text = body["text"] as? String ?? body["note"] as? String ?? ""
            guard !text.isEmpty else {
                smLog.warning("[\(reqID)] /note called with empty text", category: .server)
                sendResponse(connection: connection, status: 400, body: ["error": "body must include 'text' field", "example": "{\"text\": \"audio dropped here\"}"])
                return
            }
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            var noteDetails: [String: String] = ["text": text]
            if isRecording { noteDetails["recording_elapsed"] = String(format: "%.0fs", elapsed) }
            smLog.usage("📝 NOTE", details: noteDetails)
            smLog.info("[\(reqID)] Note recorded: \"\(text)\"", category: .server)
            sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "note": text,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "recording_elapsed": isRecording ? elapsed : -1
            ])

        case ("GET", "/version"):
            // Build info — always know exactly what Vera is running.
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            smLog.debug("[\(reqID)] /version requested", category: .server)
            sendResponse(connection: connection, status: 200, body: [
                "version": version,
                "build": build,
                "min_macos": "14.0 (Sonoma)",
                "api_endpoints": [
                    // Recording
                    "POST /start", "POST /stop", "POST /pause", "POST /resume",
                    "POST /chapter", "POST /highlight", "POST /screenshot", "POST /note",
                    // Export
                    "POST /export",
                    // Window management
                    "POST /window/focus", "POST /window/position", "POST /window/hide-others",
                    // System state
                    "GET /system/clipboard", "GET /system/active-window", "GET /system/running-apps",
                    // Info / debug
                    "GET /status", "GET /windows", "GET /debug", "GET /logs", "GET /report", "GET /version"
                ]
            ])

        case ("GET", "/report"):
            // Clean human-readable session report — this is what Vera attaches to bug reports.
            // Shows the full usage story: what happened, when, in plain English.
            smLog.debug("[\(reqID)] /report requested", category: .server)
            let usageEvents = smLog.recentUsageEvents(limit: 100)
            let errors = smLog.recentEntries(limit: 50, minLevel: .warning)

            // Build a clean text report
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var reportLines: [String] = [
                "═══════════════════════════════════════════════",
                "  ScreenMuse Session Report",
                "  Generated: \(df.string(from: Date()))",
                "═══════════════════════════════════════════════",
                "",
                "── Usage Timeline ──────────────────────────────"
            ]
            if usageEvents.isEmpty {
                reportLines.append("  (no usage events yet)")
            } else {
                for event in usageEvents {
                    reportLines.append("  " + event.formatted())
                }
            }
            reportLines += [
                "",
                "── Warnings & Errors ───────────────────────────"
            ]
            let warnErrors = errors.filter { $0["level"] == "warning" || $0["level"] == "error" }
            if warnErrors.isEmpty {
                reportLines.append("  ✅ No warnings or errors")
            } else {
                for e in warnErrors {
                    let ts = String((e["timestamp"] ?? "").dropFirst(11).prefix(8))
                    let lvl = (e["level"] ?? "").uppercased()
                    let msg = e["message"] ?? ""
                    reportLines.append("  [\(ts)] \(lvl)  \(msg)")
                }
            }
            reportLines += [
                "",
                "── System Info ─────────────────────────────────",
                "  Log file:   \(smLog.logFilePath)",
                "  Usage log:  \(smLog.usageLogFilePath)",
                "  Recording:  \(isRecording ? "▶ ACTIVE (session: \(sessionID ?? "?"))" : "⏹ idle")",
                "  Last video: \(currentVideoURL?.path ?? "(none)")",
                "═══════════════════════════════════════════════"
            ]

            let reportText = reportLines.joined(separator: "\n")

            sendResponse(connection: connection, status: 200, body: [
                "report": reportText,
                "usage_events": usageEvents.map { $0.asDictionary() },
                "warnings_and_errors": warnErrors,
                "log_file": smLog.logFilePath,
                "usage_log_file": smLog.usageLogFilePath
            ])

        case ("GET", "/logs"):
            // Return recent log entries from the ring buffer.
            // Query params supported (parsed from path):
            //   ?limit=N      — max entries to return (default 200)
            //   ?level=error  — minimum level filter (debug/info/warning/error)
            //   ?category=X   — category filter
            let queryString = path.contains("?") ? String(path.split(separator: "?", maxSplits: 1).last ?? "") : ""
            var queryParams: [String: String] = [:]
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { queryParams[String(kv[0])] = String(kv[1]) }
            }

            let limit = Int(queryParams["limit"] ?? "200") ?? 200
            let minLevel = ScreenMuseLogger.Level(rawValue: queryParams["level"] ?? "debug") ?? .debug
            let filterCategory = queryParams["category"].flatMap { ScreenMuseLogger.Category(rawValue: $0) }

            smLog.debug("[\(reqID)] /logs limit=\(limit) minLevel=\(minLevel.rawValue) category=\(filterCategory?.rawValue ?? "all")", category: .server)

            let entries = smLog.recentEntries(limit: limit, category: filterCategory, minLevel: minLevel)
            sendResponse(connection: connection, status: 200, body: [
                "count": entries.count,
                "log_file": smLog.logFilePath,
                "entries": entries
            ])

        default:
            smLog.warning("[\(reqID)] 404 — \(method) \(path) not found", category: .server)
            sendResponse(connection: connection, status: 404, body: ["error": "not found"])
        }
    }

    private func structuredError(_ error: Error) -> [String: Any] {
        if let re = error as? RecordingError {
            switch re {
            case .permissionDenied:
                return [
                    "error": re.errorDescription ?? error.localizedDescription,
                    "code": "PERMISSION_DENIED",
                    "suggestion": "Grant Screen Recording in System Settings → Privacy & Security → Screen Recording, then relaunch ScreenMuse"
                ]
            case .noFramesCaptured:
                return [
                    "error": re.errorDescription ?? error.localizedDescription,
                    "code": "NO_FRAMES_CAPTURED",
                    "suggestion": "Grant Screen Recording permission and relaunch. Also check ./scripts/reset-permissions.sh"
                ]
            case .windowNotFound(let q):
                return [
                    "error": re.errorDescription ?? error.localizedDescription,
                    "code": "WINDOW_NOT_FOUND",
                    "query": q,
                    "suggestion": "Call GET /windows to list available windows"
                ]
            case .notRecording:
                return ["error": re.errorDescription ?? error.localizedDescription, "code": "NOT_RECORDING"]
            case .writerFailed(let msg):
                return ["error": msg, "code": "WRITER_FAILED", "suggestion": "Check Console.app for AVFoundation errors"]
            default:
                return ["error": re.errorDescription ?? error.localizedDescription, "code": "RECORDING_ERROR"]
            }
        }
        return ["error": error.localizedDescription, "code": "UNKNOWN_ERROR"]
    }

    private func sendResponse(connection: NWConnection, status: Int, body: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let statusTexts = [200: "OK", 400: "Bad Request", 404: "Not Found", 409: "Conflict", 500: "Internal Server Error"]
        let statusText = statusTexts[status] ?? "Unknown"
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(jsonStr)"

        guard let responseData = response.data(using: .utf8) else { return }
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
