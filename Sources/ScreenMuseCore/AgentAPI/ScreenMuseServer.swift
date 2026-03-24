import AVFoundation
import AppKit
import Foundation
import Network
import ScreenCaptureKit

// Local HTTP server for programmatic agent control
// Endpoints:
//   POST /start           body: {"name":"...","quality":"high","audio_source":"Chrome"}  → {"session_id": "uuid", "status": "recording"}
//   POST /stop            → {"video_path": "/path/video.mp4", "metadata": {...}}
//   POST /pause           → {"status": "paused", "elapsed": N}
//   POST /resume          → {"status": "recording", "elapsed": N}
//   POST /chapter         body: {"name": "Chapter name"}                 → {"ok": true, "time": N}
//   POST /highlight       → {"ok": true}
//   POST /screenshot      body: {"path": "/optional/path.png"}           → {"path": "...", "width": N, "height": N}
//   POST /note            body: {"text": "something felt wrong here"}    → {"ok": true, "timestamp": "..."}
//   POST /export          body: {"format":"gif","fps":10,"scale":800,"start":0,"end":30} → {"path":...,"frames":N,"size_mb":N}
//   POST /trim            body: {"start":3.5,"end":45.0}                                → {"path":...,"trimmed_duration":N}
//   POST /speedramp       body: {"idle_speed":4.0,"idle_threshold_sec":2.0}             → {"output_duration":N,"compression_ratio":N}
//   POST /upload/icloud   body: {"source":"last","filename":"demo.mp4"}                 → {"local_path":...,"syncing_to_cloud":true}
//
//   -- Multi-Window --
//   POST /start/pip       body: {"windows":["Chrome","Terminal"],"layout":"picture-in-picture"} → {"session_id":...}
//
//   -- Recording Management --
//   GET  /recordings      → list all recordings with metadata
//   DELETE /recording     body: {"filename":"..."} or {"path":"..."} → {"ok":true}
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
//   GET  /version     → {"version": "1.0.2", "build": "...", "api_endpoints": [...], "endpoint_count": 28}
//   GET  /debug       → save dir, recent files, server state
//   GET  /logs        → recent log entries from ScreenMuseLogger ring buffer
//   GET  /report      → clean session report for bug reports

@MainActor
public class ScreenMuseServer {
    public static let shared = ScreenMuseServer()

    private var listener: NWListener?
    // recordingManager used when coordinator is not set (e.g. headless/test mode)
    private let recordingManager = RecordingManager()
    private let pipManager = PiPRecordingManager()
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
            // audio_source: "system" (default), "none", or app name/bundle ID for app-only audio
            let audioSourceStr = body["audio_source"] as? String
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
                    let resolvedAudioSource: RecordingConfig.AudioSource
                    switch audioSourceStr?.lowercased() {
                    case "none", "off", "silent": resolvedAudioSource = .none
                    case nil, "system", "all": resolvedAudioSource = .system
                    default:
                        // Treat as app name / bundle ID
                        resolvedAudioSource = .appOnly(audioSourceStr!)
                    }
                    let config = RecordingConfig(
                        captureSource: source,
                        includeSystemAudio: resolvedAudioSource != RecordingConfig.AudioSource.none,
                        quality: resolvedQuality,
                        audioSource: resolvedAudioSource
                    )
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

        // MARK: - PiP Recording

        case ("POST", "/start/pip"):
            guard !isRecording else {
                sendResponse(connection: connection, status: 409, body: [
                    "error": "Already recording. Stop the current session first.",
                    "code": "ALREADY_RECORDING"
                ])
                return
            }

            // Parse windows: ["Chrome", "Terminal"] or ["com.google.Chrome", "com.apple.Terminal"]
            let windowNames = body["windows"] as? [String] ?? []
            guard windowNames.count >= 2 else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "'windows' must be an array of at least 2 app names or titles",
                    "example": "{\"windows\": [\"Google Chrome\", \"Terminal\"], \"layout\": \"picture-in-picture\"}"
                ])
                return
            }

            let layoutStr = body["layout"] as? String ?? "picture-in-picture"
            let layout = PiPRecordingManager.Layout(rawValue: layoutStr) ?? .pictureInPicture
            let quality = RecordingConfig.Quality(rawValue: body["quality"] as? String ?? "medium") ?? .medium
            let fps = body["fps"] as? Int ?? 30
            let overlayScale = body["overlay_scale"] as? Double ?? 0.25
            let includeAudio = body["include_audio"] as? Bool ?? true

            smLog.info("[\(reqID)] /start/pip windows=\(windowNames) layout=\(layoutStr)", category: .server)

            do {
                // Find both windows via SCShareableContent
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                func findWindow(_ query: String) -> SCWindow? {
                    // Try window title, then app name, then bundle ID
                    content.windows.first(where: { $0.title?.localizedCaseInsensitiveContains(query) ?? false })
                    ?? content.windows.first(where: { $0.owningApplication?.applicationName.localizedCaseInsensitiveContains(query) ?? false })
                    ?? content.windows.first(where: { $0.owningApplication?.bundleIdentifier.localizedCaseInsensitiveContains(query) ?? false })
                }

                guard let primaryWindow = findWindow(windowNames[0]) else {
                    sendResponse(connection: connection, status: 404, body: [
                        "error": "Primary window not found: '\(windowNames[0])'",
                        "code": "WINDOW_NOT_FOUND",
                        "tip": "Use GET /windows to see available windows"
                    ])
                    return
                }
                guard let overlayWindow = findWindow(windowNames[1]) else {
                    sendResponse(connection: connection, status: 404, body: [
                        "error": "Overlay window not found: '\(windowNames[1])'",
                        "code": "WINDOW_NOT_FOUND",
                        "tip": "Use GET /windows to see available windows"
                    ])
                    return
                }

                var pipConfig = PiPRecordingManager.PiPConfig()
                pipConfig.layout = layout
                pipConfig.quality = quality
                pipConfig.fps = fps
                pipConfig.overlayScale = overlayScale
                pipConfig.includeAudio = includeAudio

                try await pipManager.startRecording(
                    primaryWindow: primaryWindow,
                    overlayWindow: overlayWindow,
                    config: pipConfig
                )

                sessionID = UUID().uuidString
                sessionName = body["name"] as? String ?? "pip-recording"
                startTime = Date()
                isRecording = true

                sendResponse(connection: connection, status: 200, body: [
                    "session_id": sessionID!,
                    "status": "recording",
                    "mode": "pip",
                    "layout": layoutStr,
                    "primary_window": primaryWindow.title ?? windowNames[0],
                    "overlay_window": overlayWindow.title ?? windowNames[1]
                ])
            } catch let err as PiPRecordingManager.PiPError {
                smLog.error("[\(reqID)] /start/pip failed: \(err.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: [
                    "error": err.errorDescription ?? err.localizedDescription,
                    "code": "PIP_FAILED"
                ])
            } catch {
                smLog.error("[\(reqID)] /start/pip error: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        case ("POST", "/stop"):
            // Handle PiP stop
            if pipManager.isRecording {
                smLog.info("[\(reqID)] Stopping PiP session", category: .server)
                do {
                    let url = try await pipManager.stopRecording()
                    isRecording = false
                    let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                    currentVideoURL = url
                    smLog.usage("RECORD STOP (PiP)", details: ["elapsed": "\(Int(elapsed))s", "file": url.lastPathComponent])
                    sendResponse(connection: connection, status: 200, body: [
                        "video_path": url.path,
                        "session_id": sessionID ?? "",
                        "elapsed": elapsed,
                        "mode": "pip"
                    ])
                    sessionID = nil
                    startTime = nil
                    chapters.removeAll()
                } catch {
                    smLog.error("[\(reqID)] PiP stop failed: \(error.localizedDescription)", category: .server)
                    sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
                }
                return
            }

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

        // MARK: - Recordings Management

        case ("GET", "/recordings"):
            // List all recordings in ~/Movies/ScreenMuse/ with metadata.
            smLog.debug("[\(reqID)] /recordings list", category: .server)
            let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse", isDirectory: true)
            let exportsDir = screenMuseDir.appendingPathComponent("Exports", isDirectory: true)

            var recordings: [[String: Any]] = []
            let fm = FileManager.default

            // Scan main folder + Exports subfolder
            let scanDirs = [screenMuseDir, exportsDir].filter { fm.fileExists(atPath: $0.path) }
            for dir in scanDirs {
                guard let contents = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for url in contents.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                    let ext = url.pathExtension.lowercased()
                    guard ["mp4", "mov", "gif", "webp"].contains(ext) else { continue }
                    let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                    let fileSize = attrs?.fileSize ?? 0
                    let sizeMB = (Double(fileSize) / 1_048_576 * 100).rounded() / 100
                    var rec: [String: Any] = [
                        "path": url.path,
                        "filename": url.lastPathComponent,
                        "format": ext,
                        "size": fileSize,
                        "size_mb": sizeMB,
                        "folder": dir.lastPathComponent == "ScreenMuse" ? "recordings" : dir.lastPathComponent.lowercased()
                    ]
                    if let created = attrs?.creationDate {
                        rec["created_at"] = ISO8601DateFormatter().string(from: created)
                    }
                    // Mark which one is currently loaded as lastVideoURL
                    if let last = currentVideoURL, last.path == url.path {
                        rec["is_last"] = true
                    }
                    recordings.append(rec)
                }
            }

            smLog.debug("[\(reqID)] /recordings found \(recordings.count) files", category: .server)
            sendResponse(connection: connection, status: 200, body: [
                "recordings": recordings,
                "count": recordings.count,
                "directory": screenMuseDir.path
            ])

        case ("DELETE", "/recording"):
            // Delete a recording by path or filename.
            // Body: {"path": "/abs/path.mp4"} OR {"filename": "ScreenMuse_2026-03-24.mp4"}
            let pathStr = body["path"] as? String
            let filenameStr = body["filename"] as? String

            guard pathStr != nil || filenameStr != nil else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "Provide 'path' or 'filename'",
                    "example_path": "{\"path\": \"/Users/you/Movies/ScreenMuse/recording.mp4\"}",
                    "example_filename": "{\"filename\": \"ScreenMuse_2026-03-24.mp4\"}"
                ])
                return
            }

            let fm = FileManager.default
            let targetURL: URL?
            if let p = pathStr {
                targetURL = URL(fileURLWithPath: p)
            } else if let name = filenameStr {
                let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
                let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse", isDirectory: true)
                // Search main dir + Exports
                let candidates = [
                    screenMuseDir.appendingPathComponent(name),
                    screenMuseDir.appendingPathComponent("Exports/\(name)")
                ]
                targetURL = candidates.first { fm.fileExists(atPath: $0.path) }
            } else {
                targetURL = nil
            }

            guard let url = targetURL, fm.fileExists(atPath: url.path) else {
                smLog.warning("[\(reqID)] /recording DELETE — file not found", category: .server)
                sendResponse(connection: connection, status: 404, body: [
                    "error": "Recording not found",
                    "code": "NOT_FOUND",
                    "tip": "Use GET /recordings to list available files"
                ])
                return
            }

            // Refuse to delete the currently loaded video
            if let last = currentVideoURL, last.path == url.path {
                sendResponse(connection: connection, status: 409, body: [
                    "error": "Cannot delete the currently loaded recording. Stop and start a new session first.",
                    "code": "IN_USE"
                ])
                return
            }

            smLog.info("[\(reqID)] Deleting recording: \(url.lastPathComponent)", category: .server)
            do {
                try fm.removeItem(at: url)
                smLog.usage("DELETE RECORDING", details: ["file": url.lastPathComponent])
                sendResponse(connection: connection, status: 200, body: [
                    "ok": true,
                    "deleted": url.lastPathComponent,
                    "path": url.path
                ])
            } catch {
                smLog.error("[\(reqID)] Delete failed: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        // MARK: - iCloud Upload

        case ("POST", "/upload/icloud"):
            smLog.info("[\(reqID)] /upload/icloud request", category: .server)

            // Resolve source
            let sourceStr = body["source"] as? String ?? "last"
            let sourceURL: URL?
            if sourceStr == "last" {
                sourceURL = currentVideoURL
            } else {
                sourceURL = URL(fileURLWithPath: sourceStr)
            }
            guard let resolvedSource = sourceURL,
                  FileManager.default.fileExists(atPath: resolvedSource.path) else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "No video available. Record something first, or pass 'source' with a file path.",
                    "code": "NO_VIDEO"
                ])
                return
            }

            let filename = body["filename"] as? String
            let overwrite = body["overwrite"] as? Bool ?? false

            smLog.info("[\(reqID)] /upload/icloud source=\(resolvedSource.lastPathComponent) overwrite=\(overwrite)", category: .server)

            do {
                let uploader = iCloudUploader()
                let result = try uploader.upload(sourceURL: resolvedSource, filename: filename, overwrite: overwrite)
                sendResponse(connection: connection, status: 200, body: result.asDictionary())
            } catch let err as iCloudUploader.UploadError {
                let code: String
                let status: Int
                switch err {
                case .sourceNotFound: code = "SOURCE_NOT_FOUND"; status = 404
                case .iCloudDriveNotAvailable: code = "ICLOUD_NOT_AVAILABLE"; status = 503
                case .copyFailed: code = "COPY_FAILED"; status = 500
                }
                smLog.error("[\(reqID)] /upload/icloud failed [\(code)]: \(err.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: status, body: [
                    "error": err.errorDescription ?? err.localizedDescription,
                    "code": code
                ])
            } catch {
                smLog.error("[\(reqID)] /upload/icloud error: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        // MARK: - Speed Ramp

        case ("POST", "/speedramp"):
            smLog.info("[\(reqID)] /speedramp request", category: .server)

            // Resolve source
            let sourceStr = body["source"] as? String ?? "last"
            let sourceURL: URL?
            if sourceStr == "last" {
                sourceURL = currentVideoURL
            } else {
                sourceURL = URL(fileURLWithPath: sourceStr)
            }
            guard let resolvedSource = sourceURL,
                  FileManager.default.fileExists(atPath: resolvedSource.path) else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "No video available. Record something first, or pass 'source' with a file path.",
                    "code": "NO_VIDEO"
                ])
                return
            }

            // Build ramp config
            var rampConfig = SpeedRamper.Config()
            if let v = body["idle_threshold_sec"] as? Double { rampConfig.idleThresholdSec = v }
            if let v = body["idle_speed"] as? Double { rampConfig.idleSpeed = max(1.0, v) }
            if let v = body["active_speed"] as? Double { rampConfig.activeSpeed = max(0.1, v) }

            // Event data for activity analysis.
            // ScreenMuseServer doesn't hold cursor/keyboard event arrays directly — those live
            // in RecordViewModel which is in the App layer. Without them, ActivityAnalyzer
            // falls back to audio amplitude analysis automatically.
            let cursorEvents: [CursorEvent] = []
            let keystrokeTimestamps: [Date] = []
            let recordingStart = startTime

            // Analyze activity
            let analyzer = ActivityAnalyzer()
            let asset = AVURLAsset(url: resolvedSource)
            let assetDuration: Double
            do {
                let dur = try await asset.load(.duration)
                assetDuration = CMTimeGetSeconds(dur)
            } catch {
                sendResponse(connection: connection, status: 500, body: [
                    "error": "Could not load video duration: \(error.localizedDescription)",
                    "code": "ASSET_LOAD_FAILED"
                ])
                return
            }

            let segments: [ActivityAnalyzer.Segment]
            if !cursorEvents.isEmpty || !keystrokeTimestamps.isEmpty, let start = recordingStart {
                // Use agent event data
                segments = analyzer.analyze(
                    cursorEvents: cursorEvents,
                    keystrokeTimestamps: keystrokeTimestamps,
                    recordingStart: start,
                    duration: assetDuration,
                    idleThreshold: rampConfig.idleThresholdSec
                )
                smLog.info("[\(reqID)] /speedramp using agent event data (\(cursorEvents.count) cursor, \(keystrokeTimestamps.count) keystrokes)", category: .server)
            } else {
                // Fallback to audio analysis
                smLog.info("[\(reqID)] /speedramp no event data — falling back to audio analysis", category: .server)
                do {
                    segments = try await analyzer.analyzeFromAudio(
                        asset: asset,
                        duration: assetDuration,
                        idleThreshold: rampConfig.idleThresholdSec
                    )
                } catch {
                    sendResponse(connection: connection, status: 500, body: [
                        "error": "Activity analysis failed: \(error.localizedDescription)",
                        "code": "ANALYSIS_FAILED"
                    ])
                    return
                }
            }

            // Resolve output path
            let moviesURL2 = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let exportsDir2 = moviesURL2.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: exportsDir2, withIntermediateDirectories: true)
            let rampOutputURL: URL
            if let customOut = body["output"] as? String {
                rampOutputURL = URL(fileURLWithPath: customOut)
            } else {
                rampOutputURL = SpeedRamper.defaultOutputURL(for: resolvedSource, exportsDir: exportsDir2)
            }

            smLog.info("[\(reqID)] /speedramp segments=\(segments.count) idle=\(segments.filter{$0.isIdle}.count) → \(rampOutputURL.lastPathComponent)", category: .server)

            do {
                let ramper = SpeedRamper()
                let result = try await ramper.ramp(
                    sourceURL: resolvedSource,
                    outputURL: rampOutputURL,
                    segments: segments,
                    config: rampConfig
                )
                sendResponse(connection: connection, status: 200, body: result.asDictionary())
            } catch let err as SpeedRamper.SpeedRampError {
                smLog.error("[\(reqID)] /speedramp failed: \(err.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: [
                    "error": err.errorDescription ?? err.localizedDescription,
                    "code": "SPEEDRAMP_FAILED"
                ])
            } catch {
                smLog.error("[\(reqID)] /speedramp error: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        // MARK: - Trim

        case ("POST", "/trim"):
            smLog.info("[\(reqID)] /trim request", category: .server)

            // Resolve source
            let sourceStr = body["source"] as? String ?? "last"
            let sourceURL: URL?
            if sourceStr == "last" {
                sourceURL = currentVideoURL
            } else {
                sourceURL = URL(fileURLWithPath: sourceStr)
            }
            guard let resolvedSource = sourceURL,
                  FileManager.default.fileExists(atPath: resolvedSource.path) else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "No video available. Record something first, or pass 'source' with a file path.",
                    "code": "NO_VIDEO"
                ])
                return
            }

            // Build config
            var trimConfig = VideoTrimmer.Config()
            if let start = body["start"] as? Double { trimConfig.start = start }
            else if let start = body["start"] as? Int { trimConfig.start = Double(start) }
            if let end = body["end"] as? Double { trimConfig.end = end }
            else if let end = body["end"] as? Int { trimConfig.end = Double(end) }
            if let reencode = body["reencode"] as? Bool { trimConfig.reencode = reencode }

            // Resolve output
            let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

            let outputURL: URL
            if let customOut = body["output"] as? String {
                outputURL = URL(fileURLWithPath: customOut)
            } else {
                outputURL = VideoTrimmer.defaultOutputURL(for: resolvedSource, exportsDir: exportsDir)
            }

            smLog.info("[\(reqID)] /trim source=\(resolvedSource.lastPathComponent) start=\(trimConfig.start) end=\(trimConfig.end.map{String($0)} ?? "full") reencode=\(trimConfig.reencode) → \(outputURL.lastPathComponent)", category: .server)

            do {
                let trimmer = VideoTrimmer()
                let result = try await trimmer.trim(sourceURL: resolvedSource, outputURL: outputURL, config: trimConfig)
                sendResponse(connection: connection, status: 200, body: result.asDictionary())
            } catch let err as VideoTrimmer.TrimError {
                let code: String
                switch err {
                case .noVideoSource: code = "NO_VIDEO"
                case .invalidRange: code = "INVALID_RANGE"
                case .exportFailed: code = "EXPORT_FAILED"
                case .exportCancelled: code = "CANCELLED"
                }
                smLog.error("[\(reqID)] /trim failed [\(code)]: \(err.localizedDescription)", category: .server)
                let status = (code == "INVALID_RANGE" || code == "NO_VIDEO") ? 400 : 500
                sendResponse(connection: connection, status: status, body: [
                    "error": err.errorDescription ?? err.localizedDescription,
                    "code": code
                ])
            } catch {
                smLog.error("[\(reqID)] /trim error: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

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
                sourceURL = currentVideoURL
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

        // MARK: - Frame (recording-context-aware screenshot)

        case ("POST", "/frame"):
            // Like /screenshot but annotated with recording context.
            // Returns elapsed, session_id, current_chapter alongside the image path.
            // Useful for agents to verify recording content mid-session or build thumbnails.
            smLog.info("[\(reqID)] /frame requested", category: .capture)
            // Read recording state from server's own properties (not viewModel)
            let frameIsRecording = isRecording
            let frameIsPaused = !isRecording && startTime != nil

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    sendResponse(connection: connection, status: 500, body: ["error": "No display found"])
                    return
                }

                // Support jpeg format for smaller thumbnails
                let formatStr = (body["format"] as? String ?? "png").lowercased()
                let useJPEG = formatStr == "jpeg" || formatStr == "jpg"
                let jpegQuality = body["quality"] as? Double ?? 0.85

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.pixelFormat = kCVPixelFormatType_32BGRA

                // Resolve output path
                let ext = useJPEG ? "jpg" : "png"
                let savePath: URL
                if let customPath = body["path"] as? String {
                    savePath = URL(fileURLWithPath: customPath)
                } else {
                    let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
                    let framesDir = moviesURL.appendingPathComponent("ScreenMuse/Frames", isDirectory: true)
                    try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
                    let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    savePath = framesDir.appendingPathComponent("frame-\(ts).\(ext)")
                }

                if #available(macOS 14.0, *) {
                    let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let rep = NSBitmapImageRep(cgImage: cgImage)

                    let imageData: Data?
                    if useJPEG {
                        imageData = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
                    } else {
                        imageData = rep.representation(using: .png, properties: [:])
                    }

                    guard let data = imageData else {
                        sendResponse(connection: connection, status: 500, body: ["error": "Image conversion failed"])
                        return
                    }
                    try data.write(to: savePath)

                    // Build recording context
                    var response: [String: Any] = [
                        "path": savePath.path,
                        "format": ext,
                        "width": cgImage.width,
                        "height": cgImage.height,
                        "size": data.count
                    ]

                    let frameElapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                    if frameIsRecording || frameIsPaused {
                        response["recording"] = true
                        response["paused"] = frameIsPaused
                        response["recording_elapsed"] = frameElapsed
                        if let sid = sessionID { response["session_id"] = sid }
                        // Current chapter (last chapter whose time <= elapsed)
                        if let currentChapter = chapters.last(where: { $0.time <= frameElapsed }) {
                            response["current_chapter"] = currentChapter.name
                        }
                    } else {
                        response["recording"] = false
                    }

                    smLog.info("[\(reqID)] ✅ /frame saved \(savePath.lastPathComponent) \(cgImage.width)×\(cgImage.height) recording=\(frameIsRecording)", category: .capture)
                    smLog.usage("FRAME CAPTURE", details: ["file": savePath.lastPathComponent, "format": ext, "recording": "\(frameIsRecording)"])
                    sendResponse(connection: connection, status: 200, body: response)
                } else {
                    sendResponse(connection: connection, status: 400, body: ["error": "Frame capture requires macOS 14+"])
                }
            } catch {
                smLog.error("[\(reqID)] /frame failed: \(error.localizedDescription)", category: .capture)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
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
            let endpoints: [String] = [
                    // Recording
                    "POST /start", "POST /stop", "POST /pause", "POST /resume",
                    "POST /chapter", "POST /highlight", "POST /screenshot", "POST /note",
                    // Export
                    "POST /export", "POST /trim", "POST /speedramp",
                    // Frame capture
                    "POST /frame",
                    // Cloud
                    "POST /upload/icloud",
                    // Multi-window
                    "POST /start/pip",
                    // Recording management
                    "GET /recordings", "DELETE /recording",
                    // Window management
                    "POST /window/focus", "POST /window/position", "POST /window/hide-others",
                    // System state
                    "GET /system/clipboard", "GET /system/active-window", "GET /system/running-apps",
                    // Info / debug
                    "GET /status", "GET /windows", "GET /debug", "GET /logs", "GET /report", "GET /version"
                ]
            sendResponse(connection: connection, status: 200, body: [
                "version": version,
                "build": build,
                "min_macos": "14.0 (Sonoma)",
                "endpoint_count": endpoints.count,
                "api_endpoints": endpoints
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
