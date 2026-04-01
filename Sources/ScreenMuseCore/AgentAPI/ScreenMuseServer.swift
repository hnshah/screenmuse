import AVFoundation
import AppKit
import Darwin
import Foundation
import Network
import ScreenCaptureKit
import Vision

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
//   POST /validate     body: {"source":"last","checks":[...]}               → {"valid":true,"score":85,"checks":[...],"issues":[]}
//   POST /frames       body: {"source":"last","timestamps":[1.0,2.5],"format":"png"} → {"frames":[...],"count":N}
//
//   GET  /status      → {"recording": bool, "elapsed": N, "chapters": [...]}
//   GET  /windows        → {"windows": [...], "count": N}
//   GET  /version        → {"version": "1.6.0", "build": "...", "api_endpoints": [...], "endpoint_count": 40}
//   GET  /debug          → save dir, recent files, server state
//   GET  /logs           → recent log entries from ScreenMuseLogger ring buffer
//   GET  /logs/download  → download all logs as zip for bug reports
//   GET  /performance    → real-time performance metrics (memory, CPU, disk)
//   GET  /report         → clean session report for bug reports
//
//   -- Phase 2: Demo Recording --
//   POST /demo/record    body: {"script": {...}, "output_name": "my-demo"} → {"video_path": ..., "duration": N, "scenes_completed": N}
//   POST /edit/auto      body: {"source": "last", "remove_pauses": true, "pause_threshold": 3.0} → {"original_duration": N, "edited_duration": N, "edited_path": ...}

@MainActor
public class ScreenMuseServer {
    public static let shared = ScreenMuseServer()

    private var listener: NWListener?
    // recordingManager used when coordinator is not set (e.g. headless/test mode)
    private let recordingManager = RecordingManager()
    private let pipManager = PiPRecordingManager()
    private let streamManager = SSEStreamManager()
    private lazy var demoExecutor = DemoExecutor(server: self)
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
    public private(set) var sessionNotes: [(text: String, time: TimeInterval)] = []
    public private(set) var sessionHighlights: [TimeInterval] = []
    public private(set) var highlightNextClick = false
    // Webhook fired when recording stops
    private var pendingWebhookURL: URL?

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

        // Strip query string from path and merge into body (GET params override JSON body)
        let cleanPath: String
        if let qIdx = path.firstIndex(of: "?") {
            let queryString = String(path[path.index(after: qIdx)...])
            cleanPath = String(path[..<qIdx])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let k = String(kv[0])
                    let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    // Coerce to Int/Double if possible, otherwise String
                    if let n = Int(v) { body[k] = n }
                    else if let d = Double(v) { body[k] = d }
                    else { body[k] = v }
                }
            }
        } else {
            cleanPath = path
        }

        smLog.info("[\(reqID)] → \(method) \(cleanPath) body=\(body.isEmpty ? "{}" : "\(body)")", category: .server)

        switch (method, cleanPath) {

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
            // region: {"x":0,"y":0,"width":1280,"height":720} — capture a specific display area
            let regionDict = body["region"] as? [String: Any]
            let regionRect: CGRect? = regionDict.flatMap { d in
                guard let w = (d["width"] as? Double) ?? (d["width"] as? Int).map(Double.init),
                      let h = (d["height"] as? Double) ?? (d["height"] as? Int).map(Double.init),
                      w > 0, h > 0 else { return nil }
                let x = (d["x"] as? Double) ?? (d["x"] as? Int).map(Double.init) ?? 0
                let y = (d["y"] as? Double) ?? (d["y"] as? Int).map(Double.init) ?? 0
                return CGRect(x: x, y: y, width: w, height: h)
            }
            // webhook: URL to POST to when recording stops
            let webhookURL: URL? = (body["webhook"] as? String).flatMap { URL(string: $0) }
            if let wh = webhookURL { self.pendingWebhookURL = wh }
            smLog.info("[\(reqID)] Starting recording name='\(name)' quality=\(quality ?? "medium") windowTitle=\(windowTitle ?? "nil") region=\(regionRect.map { "\(Int($0.width))x\(Int($0.height))" } ?? "full")", category: .server)
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
                    } else if let rect = regionRect {
                        smLog.debug("[\(reqID)] Region capture: \(Int(rect.width))×\(Int(rect.height)) at (\(Int(rect.origin.x)),\(Int(rect.origin.y)))", category: .capture)
                        source = .region(rect)
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
            let capturedNotes = sessionNotes
            let capturedChapters = chapters
            let capturedWebhook = pendingWebhookURL
            sessionID = nil
            sessionName = nil
            startTime = nil
            isRecording = false
            sessionNotes.removeAll()
            sessionHighlights.removeAll()
            pendingWebhookURL = nil

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
                        "chapters": "\(capturedChapters.count)",
                        "size": "\(sizeMB)MB",
                        "video": url.lastPathComponent
                    ])
                    let resp = enrichedStopResponse(
                        videoURL: url, elapsed: elapsed,
                        sessionID: capturedSessionID,
                        chapters: capturedChapters,
                        notes: capturedNotes
                    )
                    sendResponse(connection: connection, status: 200, body: resp)
                    fireWebhook(capturedWebhook, videoURL: url, sessionID: capturedSessionID, elapsed: elapsed)
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
                    let resp = enrichedStopResponse(
                        videoURL: url, elapsed: elapsed,
                        sessionID: capturedSessionID,
                        chapters: capturedChapters,
                        notes: capturedNotes
                    )
                    sendResponse(connection: connection, status: 200, body: resp)
                    fireWebhook(capturedWebhook, videoURL: url, sessionID: capturedSessionID, elapsed: elapsed)
                } catch {
                    smLog.error("[\(reqID)] stopRecording() threw: \(error.localizedDescription)", category: .server)
                    smLog.usage("RECORD ERROR  \(error.localizedDescription)")
                    sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
                }
            }
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
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            sessionHighlights.append(elapsed)
            smLog.info("[\(reqID)] Highlight flag set — next click will be highlighted", category: .server)
            smLog.usage("HIGHLIGHT  next click flagged for auto-zoom + enhanced effect")
            sendResponse(connection: connection, status: 200, body: ["ok": true, "timestamp": elapsed])

        // MARK: - Demo Recording (Phase 2)

        case ("POST", "/demo/record"):
            smLog.info("[\(reqID)] /demo/record", category: .server)
            
            guard let scriptDict = body["script"] as? [String: Any] else {
                sendResponse(connection: connection, status: 400, body: ["error": "Missing 'script' in request body"])
                return
            }
            
            let outputName = body["output_name"] as? String
            
            Task {
                do {
                    // Parse script
                    let scriptData = try JSONSerialization.data(withJSONObject: scriptDict)
                    let script = try JSONDecoder().decode(DemoScript.self, from: scriptData)
                    
                    smLog.info("Executing demo script: \(script.name) (\(script.scenes.count) scenes)", category: .server)
                    
                    // Execute
                    let result = try await demoExecutor.execute(script: script, outputName: outputName)
                    
                    // Encode result
                    let resultData = try JSONEncoder().encode(result)
                    let resultDict = try JSONSerialization.jsonObject(with: resultData) as! [String: Any]
                    
                    sendResponse(connection: connection, status: 200, body: resultDict)
                } catch {
                    smLog.error("Demo execution failed: \(error)", category: .server)
                    sendResponse(connection: connection, status: 500, body: structuredError(error))
                }
            }

        case ("POST", "/edit/auto"):
            smLog.info("[\(reqID)] /edit/auto", category: .server)
            
            let source = body["source"] as? String ?? "last"
            let removePauses = body["remove_pauses"] as? Bool ?? true
            let pauseThreshold = body["pause_threshold"] as? Double ?? 3.0
            let speedUpIdle = body["speed_up_idle"] as? Bool ?? false
            let idleSpeed = body["idle_speed"] as? Double ?? 2.0
            let addTransitions = body["add_transitions"] as? Bool ?? false
            
            Task {
                do {
                    // Get video URL
                    let videoURL: URL
                    if source == "last" {
                        guard let lastVideo = currentVideoURL else {
                            sendResponse(connection: connection, status: 400, body: ["error": "No video recorded yet"])
                            return
                        }
                        videoURL = lastVideo
                    } else {
                        videoURL = URL(fileURLWithPath: source)
                    }
                    
                    // Edit
                    let options = AutoEditor.EditOptions(
                        removePauses: removePauses,
                        pauseThreshold: pauseThreshold,
                        speedUpIdle: speedUpIdle,
                        idleSpeed: idleSpeed,
                        addTransitions: addTransitions
                    )
                    
                    let result = try await AutoEditor.edit(videoURL: videoURL, options: options)
                    
                    // Encode result
                    let resultData = try JSONEncoder().encode(result)
                    let resultDict = try JSONSerialization.jsonObject(with: resultData) as! [String: Any]
                    
                    sendResponse(connection: connection, status: 200, body: resultDict)
                } catch {
                    smLog.error("Auto-edit failed: \(error)", category: .server)
                    sendResponse(connection: connection, status: 500, body: structuredError(error))
                }
            }

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

        // MARK: - Concat

        case ("POST", "/concat"):
            // Concatenate multiple recordings into one.
            // {"sources": ["/path/1.mp4", "/path/2.mp4"], "output": "/optional/out.mp4"}
            // "sources" can also be ["last"] to use currentVideoURL as first input.
            smLog.info("[\(reqID)] /concat request", category: .server)

            guard let rawSources = body["sources"] as? [String], !rawSources.isEmpty else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "'sources' must be a non-empty array of file paths",
                    "example": "{\"sources\": [\"/path/1.mp4\", \"/path/2.mp4\"]}"
                ])
                return
            }

            // Resolve "last" token to currentVideoURL
            var sourceURLs: [URL] = []
            for s in rawSources {
                if s == "last" {
                    guard let last = currentVideoURL else {
                        sendResponse(connection: connection, status: 404, body: [
                            "error": "No recent recording available for 'last'",
                            "code": "NO_VIDEO"
                        ])
                        return
                    }
                    sourceURLs.append(last)
                } else {
                    sourceURLs.append(URL(fileURLWithPath: s))
                }
            }

            // Build output URL
            let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            let outputURL: URL
            if let customOut = body["output"] as? String {
                outputURL = URL(fileURLWithPath: customOut)
            } else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
                let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                outputURL = exportsDir.appendingPathComponent("ScreenMuse_\(ts).concat.mp4")
            }

            do {
                let concatenator = VideoConcatenator()
                let result = try await concatenator.concatenate(sources: sourceURLs, outputURL: outputURL)
                currentVideoURL = outputURL
                sendResponse(connection: connection, status: 200, body: [
                    "path": result.outputURL.path,
                    "duration": result.duration,
                    "source_count": result.sourceCount,
                    "size_mb": result.fileSizeMB
                ])
            } catch let err as VideoConcatenator.ConcatError {
                smLog.error("[\(reqID)] /concat failed: \(err.localizedDescription)", category: .server)
                let status = (err.localizedDescription.contains("not found")) ? 404 : 500
                sendResponse(connection: connection, status: status, body: [
                    "error": err.errorDescription ?? err.localizedDescription,
                    "code": "CONCAT_FAILED"
                ])
            } catch {
                smLog.error("[\(reqID)] /concat error: \(error.localizedDescription)", category: .server)
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

        // MARK: - Thumbnail

        case ("POST", "/thumbnail"):
            // Extract a still frame from a video at a specific timestamp.
            // {"source":"last","time":5.0,"scale":800,"format":"jpeg","quality":85}
            smLog.info("[\(reqID)] /thumbnail request", category: .server)

            let sourceStr = body["source"] as? String ?? "last"
            let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
            guard let src = sourceURL else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                    "code": "NO_VIDEO"
                ])
                return
            }

            let thumbTime = (body["time"] as? Double) ?? (body["time"] as? Int).map(Double.init)
            let scale = body["scale"] as? Int ?? 800
            let format = body["format"] as? String ?? "jpeg"
            let quality = Double(body["quality"] as? Int ?? 85) / 100.0

            let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let thumbsDir = moviesURL.appendingPathComponent("ScreenMuse/Thumbnails", isDirectory: true)
            try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
            let ext = (format == "png") ? "png" : "jpg"
            let outputURL = thumbsDir.appendingPathComponent("thumb_\(Int(Date().timeIntervalSince1970)).\(ext)")

            do {
                let extractor = ThumbnailExtractor()
                let result = try await extractor.extract(
                    sourceURL: src,
                    time: thumbTime,
                    scale: scale,
                    format: format,
                    quality: quality,
                    outputURL: outputURL
                )
                sendResponse(connection: connection, status: 200, body: [
                    "path": result.outputURL.path,
                    "time": result.actualTime,
                    "width": result.width,
                    "height": result.height,
                    "size_bytes": result.fileSizeBytes,
                    "format": format
                ])
            } catch {
                smLog.error("[\(reqID)] /thumbnail failed: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        // MARK: - OCR

        case ("POST", "/ocr"):
            // Read text from the screen or any image file using Apple Vision.
            // {"source":"screen"} — OCR current display (default)
            // {"source":"/path/to/image.png"} — OCR existing image
            // {"level":"fast"} — "accurate" (default) or "fast"
            smLog.info("[\(reqID)] /ocr request source=\(body["source"] as? String ?? "screen")", category: .server)

            let ocrSource = body["source"] as? String ?? "screen"
            let levelStr = body["level"] as? String ?? "accurate"
            let level: VNRequestTextRecognitionLevel = (levelStr == "fast") ? .fast : .accurate
            let langHint = body["lang"] as? String
            let languages: [String] = langHint.map { [$0] } ?? []
            let fullTextOnly = body["full_text_only"] as? Bool ?? false
            let debugMode = body["debug"] as? Bool ?? false

            do {
                let ocr = ScreenOCR()
                let result: ScreenOCR.OCRResult
                if ocrSource == "screen" || ocrSource == "display" {
                    result = try await ocr.recognizeScreen(level: level, languages: languages)
                } else {
                    result = try await ocr.recognizeFile(at: URL(fileURLWithPath: ocrSource), level: level, languages: languages)
                }

                var responseBody = debugMode ? result.asJSONWithDebug : result.asJSON
                if fullTextOnly {
                    responseBody.removeValue(forKey: "blocks")
                }
                sendResponse(connection: connection, status: 200, body: responseBody)
            } catch {
                smLog.error("[\(reqID)] /ocr failed: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: [
                    "error": error.localizedDescription,
                    "tip": "Ensure Screen Recording permission is granted"
                ])
            }

        // MARK: - Crop

        case ("POST", "/crop"):
            // Crop a rectangular region from an existing recording.
            // {"source":"last","region":{"x":100,"y":50,"width":1280,"height":720}}
            smLog.info("[\(reqID)] /crop request", category: .server)

            let sourceStr = body["source"] as? String ?? "last"
            let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
            guard let src = sourceURL else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                    "code": "NO_VIDEO"
                ])
                return
            }

            guard let regionDict = body["region"] as? [String: Any],
                  let w = (regionDict["width"] as? Double) ?? (regionDict["width"] as? Int).map(Double.init),
                  let h = (regionDict["height"] as? Double) ?? (regionDict["height"] as? Int).map(Double.init),
                  w > 0, h > 0 else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "'region' is required: {x, y, width, height}",
                    "example": "{\"source\":\"last\",\"region\":{\"x\":0,\"y\":0,\"width\":1280,\"height\":720}}"
                ])
                return
            }
            let rx = (regionDict["x"] as? Double) ?? (regionDict["x"] as? Int).map(Double.init) ?? 0
            let ry = (regionDict["y"] as? Double) ?? (regionDict["y"] as? Int).map(Double.init) ?? 0
            let cropRect = CGRect(x: rx, y: ry, width: w, height: h)
            let quality = RecordingConfig.Quality(rawValue: body["quality"] as? String ?? "medium") ?? .medium

            let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
            let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let outputURL = exportsDir.appendingPathComponent("ScreenMuse_\(ts).cropped.mp4")

            do {
                let cropper = VideoCropper()
                let result = try await cropper.crop(sourceURL: src, region: cropRect, outputURL: outputURL, quality: quality)
                currentVideoURL = outputURL
                sendResponse(connection: connection, status: 200, body: [
                    "path": result.outputURL.path,
                    "crop_rect": ["x": result.cropRect.origin.x, "y": result.cropRect.origin.y,
                                  "width": result.cropRect.width, "height": result.cropRect.height],
                    "duration": result.duration,
                    "size_mb": result.fileSizeMB
                ])
            } catch let err as VideoCropper.CropError {
                smLog.error("[\(reqID)] /crop failed: \(err.localizedDescription)", category: .server)
                let status = (err.localizedDescription.contains("not found")) ? 404 :
                             (err.localizedDescription.contains("required") || err.localizedDescription.contains("Invalid")) ? 400 : 500
                sendResponse(connection: connection, status: status, body: [
                    "error": err.errorDescription ?? err.localizedDescription
                ])
            } catch {
                smLog.error("[\(reqID)] /crop error: \(error.localizedDescription)", category: .server)
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        // MARK: - Annotate

        case ("POST", "/annotate"):
            // Burn text overlays into a video at specific timestamps.
            // {"source":"last","overlays":[{"text":"Step 1","start":2,"end":8,"position":"bottom"}]}
            smLog.info("[\(reqID)] /annotate request", category: .server)

            let sourceStr = body["source"] as? String ?? "last"
            let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
            guard let src = sourceURL else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                    "code": "NO_VIDEO"
                ])
                return
            }
            guard let overlayDicts = body["overlays"] as? [[String: Any]], !overlayDicts.isEmpty else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "'overlays' must be a non-empty array",
                    "example": "{\"overlays\":[{\"text\":\"Step 1\",\"start\":2,\"end\":8,\"position\":\"bottom\"}]}"
                ])
                return
            }

            let quality = RecordingConfig.Quality(rawValue: body["quality"] as? String ?? "medium") ?? .medium
            let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
            let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let outputURL = exportsDir.appendingPathComponent("ScreenMuse_\(ts).annotated.mp4")

            do {
                let annotator = VideoAnnotator()
                let result = try await annotator.annotate(
                    sourceURL: src,
                    overlays: overlayDicts,
                    outputURL: outputURL,
                    quality: quality
                )
                currentVideoURL = outputURL
                sendResponse(connection: connection, status: 200, body: [
                    "path": result.outputURL.path,
                    "overlay_count": result.overlayCount,
                    "duration": result.duration,
                    "size_mb": result.fileSizeMB
                ])
            } catch {
                smLog.error("[\(reqID)] /annotate failed: \(error.localizedDescription)", category: .server)
                let status = error.localizedDescription.contains("required") ? 400 : 500
                sendResponse(connection: connection, status: status, body: ["error": error.localizedDescription])
            }

        // MARK: - Script (Batch Runner)

        case ("POST", "/script"):
            // Execute a sequence of ScreenMuse commands as a transaction.
            // {"commands":[{"action":"start","name":"demo"},{"sleep":5},{"action":"chapter","name":"Step 1"},{"action":"stop"}]}
            // Supported actions: start, stop, pause, resume, chapter, note, highlight, sleep
            smLog.info("[\(reqID)] /script request", category: .server)

            guard let commands = body["commands"] as? [[String: Any]], !commands.isEmpty else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "'commands' must be a non-empty array",
                    "example": "{\"commands\":[{\"action\":\"start\"},{\"sleep\":5},{\"action\":\"chapter\",\"name\":\"Step 1\"},{\"action\":\"stop\"}]}"
                ])
                return
            }

            var scriptResults: [[String: Any]] = []
            var scriptError: String? = nil

            for (idx, cmd) in commands.enumerated() {
                let action = cmd["action"] as? String ?? ""

                // sleep is a special non-action command
                if let sleepSeconds = cmd["sleep"] as? Double ?? (cmd["sleep"] as? Int).map(Double.init) {
                    try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                    scriptResults.append(["step": idx + 1, "action": "sleep", "seconds": sleepSeconds, "ok": true])
                    continue
                }

                var stepResult: [String: Any] = ["step": idx + 1, "action": action]
                do {
                    switch action {
                    case "start":
                        let name = cmd["name"] as? String ?? "script-recording"
                        let quality = cmd["quality"] as? String
                        if let coord = coordinator {
                            try await coord.startRecording(name: name, windowTitle: cmd["window_title"] as? String, windowPid: nil, quality: quality)
                        } else {
                            try await recordingManager.startRecording(config: RecordingConfig(
                                captureSource: .fullScreen,
                                includeSystemAudio: true,
                                quality: RecordingConfig.Quality(rawValue: quality ?? "medium") ?? .medium
                            ))
                        }
                        sessionID = UUID().uuidString
                        sessionName = name
                        startTime = Date()
                        isRecording = true
                        stepResult["ok"] = true

                    case "stop":
                        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                        if let coord = coordinator, let url = await coord.stopAndGetVideo() {
                            currentVideoURL = url
                            stepResult["video_path"] = url.path
                        } else {
                            let url = try await recordingManager.stopRecording()
                            currentVideoURL = url
                            stepResult["video_path"] = url.path
                        }
                        isRecording = false
                        stepResult["elapsed"] = elapsed
                        stepResult["ok"] = true

                    case "pause":
                        if let coord = coordinator {
                            try await coord.pauseRecording()
                        } else {
                            try await recordingManager.pauseRecording()
                        }
                        stepResult["ok"] = true

                    case "resume":
                        if let coord = coordinator {
                            try await coord.resumeRecording()
                        } else {
                            try await recordingManager.resumeRecording()
                        }
                        stepResult["ok"] = true

                    case "chapter":
                        let chapterName = cmd["name"] as? String ?? "Chapter \(chapters.count + 1)"
                        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                        chapters.append((name: chapterName, time: elapsed))
                        smLog.usage("CHAPTER \(chapterName)  t=\(String(format:"%.1f",elapsed))s")
                        stepResult["name"] = chapterName
                        stepResult["timestamp"] = elapsed
                        stepResult["ok"] = true

                    case "note":
                        let noteText = cmd["text"] as? String ?? ""
                        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                        sessionNotes.append((text: noteText, time: elapsed))
                        smLog.usage("📝 NOTE", details: ["text": noteText])
                        stepResult["ok"] = true

                    case "highlight":
                        highlightNextClick = true
                        stepResult["ok"] = true

                    default:
                        stepResult["ok"] = false
                        stepResult["error"] = "Unknown action '\(action)'. Supported: start, stop, pause, resume, chapter, note, highlight, sleep"
                    }
                } catch {
                    stepResult["ok"] = false
                    stepResult["error"] = error.localizedDescription
                    scriptError = "Step \(idx + 1) (\(action)) failed: \(error.localizedDescription)"
                    scriptResults.append(stepResult)
                    break // stop on error
                }
                scriptResults.append(stepResult)
            }

            sendResponse(connection: connection, status: scriptError == nil ? 200 : 500, body: [
                "ok": scriptError == nil,
                "steps_run": scriptResults.count,
                "steps": scriptResults,
                "error": scriptError as Any
            ])

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
            sessionNotes.append((text: text, time: elapsed))
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

        case ("GET", "/openapi"):
            // Machine-readable OpenAPI 3.0 spec for the full ScreenMuse API.
            // Spec lives in OpenAPISpec.swift as a JSON string literal —
            // no bracket counting, validated by any JSON linter.
            smLog.debug("[\(reqID)] /openapi spec requested", category: .server)
            guard let specData = OpenAPISpec.json.data(using: .utf8) else {
                sendResponse(connection: connection, status: 500, body: ["error": "spec encoding failed"])
                return
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(specData.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(OpenAPISpec.json)"
            if let responseData = response.data(using: .utf8) {
                connection.send(content: responseData, completion: .contentProcessed { _ in connection.cancel() })
            }

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
                    "GET /status", "GET /windows", "GET /debug", "GET /logs", "GET /report", "GET /version",
                    // Live stream
                    "GET /stream", "GET /stream/status",
                    // Session timeline + concat
                    "GET /timeline", "POST /concat",
                    // Visual analysis
                    "POST /thumbnail", "POST /ocr", "POST /crop",
                    // Validation & frames
                    "POST /validate", "POST /frames",
                    // Video editing
                    "POST /annotate",
                    // Batch runner
                    "POST /script",
                    // OpenAPI spec
                    "GET /openapi"
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
            // Query params: ?limit=N  ?level=error  ?category=X
            // (parsed from URL query string via body map above)
            let limit = body["limit"] as? Int ?? 200
            let minLevel = ScreenMuseLogger.Level(rawValue: body["level"] as? String ?? "debug") ?? .debug
            let filterCategory = (body["category"] as? String).flatMap { ScreenMuseLogger.Category(rawValue: $0) }

            smLog.debug("[\(reqID)] /logs limit=\(limit) minLevel=\(minLevel.rawValue) category=\(filterCategory?.rawValue ?? "all")", category: .server)

            let entries = smLog.recentEntries(limit: limit, category: filterCategory, minLevel: minLevel)
            sendResponse(connection: connection, status: 200, body: [
                "count": entries.count,
                "log_file": smLog.logFilePath,
                "entries": entries
            ])

        case ("GET", "/logs/download"):
            // Download all logs as a zip file for bug reports
            smLog.debug("[\(reqID)] /logs/download", category: .server)
            
            let zipURL = createLogsZip()
            if let zipPath = zipURL?.path, FileManager.default.fileExists(atPath: zipPath) {
                sendFileResponse(connection: connection, path: zipPath, contentType: "application/zip")
            } else {
                sendResponse(connection: connection, status: 500, body: ["error": "Failed to create logs zip"])
            }

        case ("GET", "/performance"):
            // Real-time performance metrics
            smLog.debug("[\(reqID)] /performance", category: .server)
            
            let metrics = getPerformanceMetrics()
            sendResponse(connection: connection, status: 200, body: metrics)

        // MARK: - Timeline

        case ("GET", "/timeline"):
            // Returns the full structured timeline of the current (or last) session:
            // chapters, notes, highlights — all with timestamps.
            // Perfect for agents that need to build summaries or reference specific moments.
            let sid = sessionID ?? "last"
            let sessionStart = startTime
            let elapsed = sessionStart.map { Date().timeIntervalSince($0) } ?? 0

            let chaptersJSON: [[String: Any]] = chapters.map { ["name": $0.name, "time": $0.time] }
            let notesJSON: [[String: Any]] = sessionNotes.map { ["text": $0.text, "time": $0.time] }
            let highlightsJSON: [Double] = sessionHighlights

            sendResponse(connection: connection, status: 200, body: [
                "session_id": sid,
                "recording": isRecording,
                "elapsed": isRecording ? elapsed : -1,
                "start_time": sessionStart.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "chapters": chaptersJSON,
                "notes": notesJSON,
                "highlights": highlightsJSON,
                "event_count": chaptersJSON.count + notesJSON.count + highlightsJSON.count
            ])

        // MARK: - SSE Live Stream

        case ("GET", "/stream"):
            // Server-Sent Events — real-time frame push.
            // Query params: ?fps=2 &scale=1280 &format=jpeg &quality=60
            // Connection stays open; frames pushed until client disconnects.
            // Usage: curl -N http://localhost:7823/stream
            // Usage: curl -N "http://localhost:7823/stream?fps=5&scale=640&quality=80"
            let fps   = body["fps"] as? Int    ?? 2
            let scale = body["scale"] as? Int  ?? 1280
            let fmt   = SSEStreamManager.StreamConfig.Format(rawValue: body["format"] as? String ?? "jpeg") ?? .jpeg
            let qual  = body["quality"] as? Int ?? 60

            let config = SSEStreamManager.StreamConfig(fps: fps, scale: scale, format: fmt, quality: qual)
            smLog.info("[\(reqID)] /stream — fps=\(fps) scale=\(scale) format=\(fmt.rawValue) quality=\(qual) active=\(streamManager.activeClientCount)", category: .server)
            smLog.usage("STREAM START", details: ["fps": "\(fps)", "scale": "\(scale)"])

            // Send SSE handshake (keeps connection open — do NOT call sendResponse)
            streamManager.sendSSEHandshake(to: connection)
            streamManager.addClient(connection, config: config)
            // Do NOT close — streamManager owns this connection until client disconnects

        case ("GET", "/stream/status"):
            // Quick health check for the stream subsystem
            sendResponse(connection: connection, status: 200, body: [
                "active_clients": streamManager.activeClientCount,
                "total_frames_sent": streamManager.totalFramesSent
            ])

        // MARK: - Validate

        case ("POST", "/validate"):
            // Run quality checks on a recording.
            // {"source":"last","checks":[{"type":"duration","min":10,"max":30},{"type":"text_at","time":5.0,"expected":"GitHub"}]}
            smLog.info("[\(reqID)] /validate request", category: .server)

            let sourceStr = body["source"] as? String ?? "last"
            let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
            guard let src = sourceURL, FileManager.default.fileExists(atPath: src.path) else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                    "code": "NO_VIDEO"
                ])
                return
            }

            guard let checks = body["checks"] as? [[String: Any]], !checks.isEmpty else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "'checks' must be a non-empty array",
                    "example": "{\"source\":\"last\",\"checks\":[{\"type\":\"duration\",\"min\":10,\"max\":30}]}"
                ])
                return
            }

            let asset = AVURLAsset(url: src)
            var checkResults: [[String: Any]] = []
            var issues: [String] = []

            // Load video duration
            var videoDuration: Double = 0
            do {
                let dur = try await asset.load(.duration)
                videoDuration = CMTimeGetSeconds(dur)
            } catch {
                sendResponse(connection: connection, status: 500, body: [
                    "error": "Could not load video: \(error.localizedDescription)"
                ])
                return
            }

            for check in checks {
                guard let checkType = check["type"] as? String else { continue }

                switch checkType {
                case "duration":
                    let minDur = (check["min"] as? Double) ?? (check["min"] as? Int).map(Double.init) ?? 0
                    let maxDur = (check["max"] as? Double) ?? (check["max"] as? Int).map(Double.init) ?? Double.infinity
                    let pass = videoDuration >= minDur && videoDuration <= maxDur
                    checkResults.append([
                        "name": "duration",
                        "pass": pass,
                        "value": (videoDuration * 10).rounded() / 10
                    ])
                    if !pass {
                        issues.append("Duration \(String(format: "%.1f", videoDuration))s outside range [\(minDur), \(maxDur)]")
                    }

                case "frame_count":
                    let minFrames = (check["min"] as? Int) ?? 0
                    var frameCount = 0
                    if let track = asset.tracks(withMediaType: .video).first {
                        let fps = track.nominalFrameRate
                        frameCount = Int(Double(fps) * videoDuration)
                    }
                    let pass = frameCount >= minFrames
                    checkResults.append([
                        "name": "frame_count",
                        "pass": pass,
                        "value": frameCount
                    ])
                    if !pass {
                        issues.append("Frame count \(frameCount) < min \(minFrames)")
                    }

                case "no_black_frames":
                    // Sample up to 10 frames and check none are fully black (< 5% avg brightness)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

                    let sampleCount = min(10, max(1, Int(videoDuration)))
                    var hasBlack = false
                    for i in 0..<sampleCount {
                        let t = videoDuration * Double(i) / Double(sampleCount)
                        let time = CMTime(seconds: t, preferredTimescale: 600)
                        do {
                            let (cgImage, _) = try await generator.image(at: time)
                            // Check average brightness — a black frame has < 5% brightness
                            let brightness = averageBrightness(of: cgImage)
                            if brightness < 0.05 {
                                hasBlack = true
                                break
                            }
                        } catch {
                            // Skip frames we can't extract
                            continue
                        }
                    }
                    let pass = !hasBlack
                    checkResults.append(["name": "no_black_frames", "pass": pass])
                    if !pass {
                        issues.append("Black frame detected")
                    }

                case "text_at":
                    let time = (check["time"] as? Double) ?? (check["time"] as? Int).map(Double.init) ?? 0
                    let expected = check["expected"] as? String ?? ""
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

                    let checkName = "text_at_\(String(format: "%.1f", time))s"
                    do {
                        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
                        let (cgImage, _) = try await generator.image(at: cmTime)
                        let ocr = ScreenOCR()
                        let ocrResult = try await ocr.recognizeImage(cgImage: cgImage, source: "frame@\(time)s")
                        let found = ocrResult.fullText.localizedCaseInsensitiveContains(expected)
                        checkResults.append([
                            "name": checkName,
                            "pass": found,
                            "found": String(ocrResult.fullText.prefix(200))
                        ])
                        if !found {
                            issues.append("Expected text '\(expected)' not found at \(time)s")
                        }
                    } catch {
                        checkResults.append([
                            "name": checkName,
                            "pass": false,
                            "error": error.localizedDescription
                        ])
                        issues.append("text_at check failed: \(error.localizedDescription)")
                    }

                default:
                    issues.append("Unknown check type: '\(checkType)' — skipped")
                }
            }

            let passCount = checkResults.filter { $0["pass"] as? Bool == true }.count
            let score = checkResults.isEmpty ? 0 : Int((Double(passCount) / Double(checkResults.count)) * 100)
            let valid = score >= 70

            sendResponse(connection: connection, status: 200, body: [
                "valid": valid,
                "score": score,
                "checks": checkResults,
                "issues": issues
            ])

        // MARK: - Frames

        case ("POST", "/frames"):
            // Extract multiple frames from a video at given timestamps.
            // {"source":"last","timestamps":[1.0,2.5,5.0],"format":"png"}
            smLog.info("[\(reqID)] /frames request", category: .server)

            let sourceStr = body["source"] as? String ?? "last"
            let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
            guard let src = sourceURL, FileManager.default.fileExists(atPath: src.path) else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                    "code": "NO_VIDEO"
                ])
                return
            }

            // Parse timestamps — accept [Double] or [Int]
            let rawTimestamps = body["timestamps"] as? [Any] ?? []
            let timestamps: [Double] = rawTimestamps.compactMap { val in
                if let d = val as? Double { return d }
                if let i = val as? Int { return Double(i) }
                return nil
            }
            guard !timestamps.isEmpty else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "'timestamps' must be a non-empty array of numbers",
                    "example": "{\"source\":\"last\",\"timestamps\":[1.0,2.5,5.0],\"format\":\"png\"}"
                ])
                return
            }

            let formatStr = (body["format"] as? String ?? "png").lowercased()
            let usePNG = formatStr != "jpg" && formatStr != "jpeg"

            // Create temp output directory
            let framesDir = URL(fileURLWithPath: "/tmp/screenmuse-frames")
            try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

            let asset = AVURLAsset(url: src)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

            var frames: [[String: Any]] = []
            for ts in timestamps {
                let cmTime = CMTime(seconds: ts, preferredTimescale: 600)
                let ext = usePNG ? "png" : "jpg"
                let filename = "frame-\(String(format: "%.1f", ts))s.\(ext)"
                let outputPath = framesDir.appendingPathComponent(filename)

                do {
                    let (cgImage, _) = try await generator.image(at: cmTime)
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    let imageData: Data?
                    if usePNG {
                        imageData = rep.representation(using: .png, properties: [:])
                    } else {
                        imageData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
                    }
                    if let data = imageData {
                        try data.write(to: outputPath)
                        frames.append(["time": ts, "path": outputPath.path])
                    } else {
                        frames.append(["time": ts, "error": "Image conversion failed"])
                    }
                } catch {
                    frames.append(["time": ts, "error": error.localizedDescription])
                }
            }

            sendResponse(connection: connection, status: 200, body: [
                "frames": frames,
                "count": frames.filter { $0["path"] != nil }.count
            ])

        default:
            smLog.warning("[\(reqID)] 404 — \(method) \(cleanPath) not found", category: .server)
            sendResponse(connection: connection, status: 404, body: ["error": "not found"])
        }
    }

    /// POST the recording-complete payload to a webhook URL.
    /// Fires-and-forgets — does not block the response to the caller.
    private func fireWebhook(_ webhookURL: URL?, videoURL: URL, sessionID: String?, elapsed: TimeInterval) {
        guard let url = webhookURL else { return }
        smLog.info("Webhook: firing → \(url.absoluteString)", category: .server)
        let payload: [String: Any] = [
            "event": "recording.complete",
            "video_path": videoURL.path,
            "session_id": sessionID ?? "",
            "elapsed": elapsed,
            "size_mb": (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int)
                .flatMap { $0 }.map { Double($0) / 1_048_576 } ?? 0,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("ScreenMuse/1.1", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                smLog.info("Webhook: delivered → \(url.host ?? url.absoluteString) HTTP \(code)", category: .server)
                smLog.usage("WEBHOOK FIRED", details: ["url": url.host ?? "?", "status": "\(code)"])
            } catch {
                smLog.warning("Webhook: delivery failed → \(url.absoluteString): \(error.localizedDescription)", category: .server)
            }
        }
    }

    /// Compute average brightness of a CGImage (0.0 = black, 1.0 = white).
    private func averageBrightness(of cgImage: CGImage) -> Double {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return 0 }

        // Downsample to 64x64 for speed
        let sampleSize = 64
        guard let context = CGContext(
            data: nil,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        guard let data = context.data else { return 0 }

        let ptr = data.bindMemory(to: UInt8.self, capacity: sampleSize * sampleSize * 4)
        var totalBrightness: Double = 0
        let pixelCount = sampleSize * sampleSize
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Double(ptr[offset])
            let g = Double(ptr[offset + 1])
            let b = Double(ptr[offset + 2])
            // Luminance formula
            totalBrightness += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }
        return totalBrightness / Double(pixelCount)
    }

    /// Build an enriched stop response with video metadata.
    /// Never returns undefined/null for required fields — uses sensible defaults.
    private func enrichedStopResponse(
        videoURL: URL,
        elapsed: TimeInterval,
        sessionID: String?,
        chapters: [(name: String, time: TimeInterval)],
        notes: [(text: String, time: TimeInterval)],
        windowPid: Int? = nil,
        windowApp: String? = nil,
        windowTitle: String? = nil
    ) -> [String: Any] {
        let fm = FileManager.default
        let fileSize = (try? fm.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
        let sizeMB = Double(fileSize) / 1_048_576

        // Probe video for resolution and fps
        let asset = AVURLAsset(url: videoURL)
        var width = 0
        var height = 0
        var fps: Double = 0
        // Use synchronous approach for track properties
        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize
            width = Int(size.width)
            height = Int(size.height)
            fps = Double(track.nominalFrameRate)
        }

        var resp: [String: Any] = [
            "path": videoURL.path,
            "video_path": videoURL.path, // backward compat
            "duration": elapsed,
            "size": fileSize,
            "size_mb": (sizeMB * 100).rounded() / 100,
            "session_id": sessionID ?? "",
            "chapters": chapters.map { ["name": $0.name, "time": $0.time] as [String: Any] },
            "notes": notes.map { ["text": $0.text, "time": $0.time] as [String: Any] }
        ]

        if width > 0 && height > 0 {
            resp["resolution"] = ["width": width, "height": height]
        }
        if fps > 0 {
            resp["fps"] = (fps * 10).rounded() / 10
        }

        // Window info (if available)
        var windowInfo: [String: Any] = [:]
        if let app = windowApp { windowInfo["app"] = app }
        if let pid = windowPid { windowInfo["pid"] = pid }
        if let title = windowTitle { windowInfo["title"] = title }
        if !windowInfo.isEmpty {
            resp["window"] = windowInfo
        }

        return resp
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

    // MARK: - Phase 1: Debugging Helpers

    private func createLogsZip() -> URL? {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let zipURL = tempDir.appendingPathComponent("screenmuse-logs-\(Date().timeIntervalSince1970).zip")
        
        // Create temporary directory for logs
        let logsDir = tempDir.appendingPathComponent("screenmuse-logs-temp")
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        // Copy log files
        let moviesURL = fm.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let sourceDir = moviesURL.appendingPathComponent("ScreenMuse/Logs")
        
        if let logFiles = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) {
            for logFile in logFiles {
                let dest = logsDir.appendingPathComponent(logFile.lastPathComponent)
                try? fm.copyItem(at: logFile, to: dest)
            }
        }
        
        // Create system info snapshot
        let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse")
        
        let sysInfo = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "save_directory": screenMuseDir.path
        ] as [String: Any]
        
        if let sysInfoData = try? JSONSerialization.data(withJSONObject: sysInfo, options: .prettyPrinted) {
            let sysInfoFile = logsDir.appendingPathComponent("system-info.json")
            try? sysInfoData.write(to: sysInfoFile)
        }
        
        // Zip it up using command line (macOS has zip built-in)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", zipURL.path, "."]
        process.currentDirectoryURL = logsDir
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // Clean up temp directory
            try? fm.removeItem(at: logsDir)
            
            return process.terminationStatus == 0 ? zipURL : nil
        } catch {
            smLog.error("Failed to create logs zip: \(error)", category: .server)
            return nil
        }
    }

    private func getPerformanceMetrics() -> [String: Any] {
        // Get system performance metrics
        var metrics: [String: Any] = [:]
        
        // Process info
        let processInfo = ProcessInfo.processInfo
        metrics["uptime_seconds"] = processInfo.systemUptime
        metrics["physical_memory_gb"] = Double(processInfo.physicalMemory) / 1_000_000_000.0
        
        // App memory usage
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let memoryMB = Double(taskInfo.resident_size) / 1_048_576.0
            metrics["app_memory_mb"] = String(format: "%.1f", memoryMB)
        }
        
        // Recording state
        metrics["recording"] = isRecording
        if let start = startTime {
            metrics["recording_duration_seconds"] = Date().timeIntervalSince(start)
        }
        
        // Disk space
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        if let values = try? moviesURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity {
            metrics["disk_available_gb"] = Double(available) / 1_000_000_000.0
        }
        
        // CPU usage (simple estimate based on thread count)
        var threadCount: mach_msg_type_number_t = 0
        var threadList: thread_act_array_t?
        if task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS {
            metrics["thread_count"] = threadCount
            if let list = threadList {
                let size = Int(threadCount) * MemoryLayout<thread_t>.size
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(size))
            }
        }
        
        return metrics
    }

    private func sendFileResponse(connection: NWConnection, path: String, contentType: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            sendResponse(connection: connection, status: 404, body: ["error": "File not found"])
            return
        }
        
        let filename = (path as NSString).lastPathComponent
        let response = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: \(contentType)\r\n" +
                      "Content-Length: \(data.count)\r\n" +
                      "Content-Disposition: attachment; filename=\"\(filename)\"\r\n" +
                      "\r\n"
        
        guard let headerData = response.data(using: .utf8) else { return }
        
        connection.send(content: headerData, completion: .contentProcessed { _ in
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        })
    }

    // MARK: - Demo Script Helpers
    
    /// Internal helper for DemoExecutor to add chapters
    public func addChapterInternal(name: String) {
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        chapters.append((name: name, time: elapsed))
        smLog.info("Chapter: \(name) at \(String(format: "%.1f", elapsed))s", category: .server)
        smLog.usage("CHAPTER", details: ["name": name, "at": String(format: "%.0fs", elapsed)])
    }
    
    /// Internal helper for DemoExecutor to set highlight flag
    public func setHighlightFlagInternal() {
        highlightNextClick = true
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        sessionHighlights.append(elapsed)
        smLog.info("Highlight flag set for next click", category: .server)
    }
}
