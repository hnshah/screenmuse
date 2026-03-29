import AVFoundation
import AppKit
import Foundation
import Network
import ScreenCaptureKit
import Vision

// NWConnection is thread-safe internally but not marked Sendable by Apple.
// We use it across actor boundaries (MainActor ↔ network callbacks) throughout the server.
extension NWConnection: @retroactive @unchecked Sendable {}

// Local HTTP server for programmatic agent control.
//
// Route handlers are organized into extensions (see route table in processHTTPRequest):
//
//   RECORDING  Server+Recording.swift  — /record /start /stop /pause /resume /chapter /highlight /note /screenshot
//              Server+PiP.swift        — /start/pip, PiP stop flow
//   EXPORT     Server+Export.swift     — /export /trim /speedramp /concat /frames /frame /thumbnail /crop /ocr
//   STREAM     Server+Stream.swift     — /stream /stream/status
//   WINDOW     Server+Window.swift     — /windows /window/focus /window/position /window/hide-others
//   SYSTEM     Server+System.swift     — /health /status /debug /logs /report /version /recordings /openapi /system/*
//   MEDIA      Server+Media.swift      — /timeline /validate /annotate /script /script/batch /upload/icloud

@MainActor
public class ScreenMuseServer {
    public static let shared = ScreenMuseServer()

    /// The port the server listens on. Resolved at start() from:
    ///   1. SCREENMUSE_PORT env var
    ///   2. ~/.screenmuse/config.json "port" field
    ///   3. Default: 7823
    public private(set) var port: UInt16 = 7823

    var listener: NWListener?
    // recordingManager used when coordinator is not set (e.g. headless/test mode)
    let recordingManager = RecordingManager()
    let pipManager = PiPRecordingManager()
    let streamManager = SSEStreamManager()
    /// Set this at app launch to route API calls through the full effects pipeline.
    /// When set, /start and /stop go through RecordViewModel (effects compositing included).
    /// When nil, falls back to raw RecordingManager (no effects).
    public weak var coordinator: RecordingCoordinating?

    public let sessionRegistry = SessionRegistry()

    public internal(set) var isRecording = false
    public internal(set) var sessionName: String?
    public internal(set) var sessionID: String?
    public internal(set) var startTime: Date?
    public internal(set) var currentVideoURL: URL?
    public internal(set) var chapters: [(name: String, time: TimeInterval)] = []
    public internal(set) var sessionNotes: [(text: String, time: TimeInterval)] = []
    public internal(set) var sessionHighlights: [TimeInterval] = []
    public internal(set) var highlightNextClick = false
    // Webhook fired when recording stops
    var pendingWebhookURL: URL?

    /// Optional API key. When set, every request must include:
    ///   X-ScreenMuse-Key: <key>
    /// Loaded from ~/.screenmuse/api_key on start(), falling back to env var
    /// SCREENMUSE_API_KEY, or auto-generated on first launch.
    /// Set SCREENMUSE_NO_AUTH=1 to explicitly disable authentication.
    /// When nil, no auth is required — safe for local-only use.
    public var apiKey: String?

    var requestCount = 0

    /// Count of currently-open incoming connections.
    /// Incremented in handleConnection, decremented when the connection reaches
    /// .cancelled or .failed state.  Exposed via GET /health for diagnostics.
    public private(set) var activeConnectionCount = 0

    /// Maps dummy NWConnection instances to job IDs for async dispatch.
    /// When sendResponse is called with a connection in this map, the result is routed
    /// to the JobQueue instead of the wire.
    private var jobConnections: [ObjectIdentifier: String] = [:]

    public func start(port overridePort: UInt16? = nil) throws {
        loadOrGenerateAPIKey()
        port = resolvePort(override: overridePort)

        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { @Sendable [weak self] conn in
            Task { @MainActor in
                self?.handleConnection(conn)
            }
        }
        // Monitor listener state — without this, failures are completely invisible.
        // NWListener.start() is async; the listener may enter .failed or .waiting
        // after start() returns and there'd be no log, no error, no way to diagnose.
        listener?.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                // Unwrap self; safe to exit early since server is a singleton but correct for Swift 6.
                guard let self else { return }
                switch state {
                case .ready:
                    smLog.info("NWListener ready — accepting connections on port \(self.port)", category: .server)
                case .failed(let error):
                    smLog.error("NWListener failed: \(error.localizedDescription) — HTTP API unavailable on port \(self.port)", category: .server)
                    smLog.usage("SERVER FAILED", details: ["error": error.localizedDescription, "port": "\(self.port)"])
                    // Attempt restart after a short delay
                    smLog.info("Scheduling NWListener restart in 2s…", category: .server)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.restartListener()
                case .cancelled:
                    smLog.info("NWListener cancelled", category: .server)
                case .waiting(let error):
                    smLog.warning("NWListener waiting (port may be in use): \(error.localizedDescription)", category: .server)
                case .setup:
                    break
                @unknown default:
                    break
                }
            }
        }
        listener?.start(queue: .main)
        smLog.info("NWListener starting on port \(port) (async — watch for 'ready' log below)", category: .server)
    }

    /// Restart the NWListener after a failure. Called automatically by the stateUpdateHandler.
    private func restartListener() {
        smLog.info("Restarting NWListener on port \(port)…", category: .server)
        listener?.cancel()
        listener = nil
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener?.newConnectionHandler = { @Sendable [weak self] conn in
                Task { @MainActor in
                    self?.handleConnection(conn)
                }
            }
            listener?.stateUpdateHandler = { @Sendable [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        smLog.info("NWListener restart succeeded — accepting connections on port \(self.port)", category: .server)
                    case .failed(let error):
                        smLog.error("NWListener restart failed: \(error.localizedDescription) — giving up", category: .server)
                        smLog.usage("SERVER RESTART FAILED", details: ["error": error.localizedDescription])
                    case .waiting(let error):
                        smLog.warning("NWListener restart waiting: \(error.localizedDescription)", category: .server)
                    default:
                        break
                    }
                }
            }
            listener?.start(queue: .main)
            smLog.info("NWListener restart initiated", category: .server)
        } catch {
            smLog.error("NWListener restart threw: \(error.localizedDescription) — HTTP API is down", category: .server)
            smLog.usage("SERVER RESTART ERROR", details: ["error": error.localizedDescription])
        }
    }

    /// Resolve listening port from (in priority order):
    ///   1. overridePort parameter passed to start()
    ///   2. SCREENMUSE_PORT environment variable
    ///   3. ~/.screenmuse/config.json "port" field
    ///   4. Default 7823
    private func resolvePort(override: UInt16?) -> UInt16 {
        if let p = override { return p }
        if let envStr = ProcessInfo.processInfo.environment["SCREENMUSE_PORT"],
           let p = UInt16(envStr), p > 0 {
            smLog.info("Using port \(p) from SCREENMUSE_PORT env var", category: .server)
            return p
        }
        let fm = FileManager.default
        let configFile = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".screenmuse/config.json")
        if fm.fileExists(atPath: configFile.path),
           let data = try? Data(contentsOf: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = json["port"] as? Int, p > 0, p <= 65535 {
            smLog.info("Using port \(p) from ~/.screenmuse/config.json", category: .server)
            return UInt16(p)
        }
        return 7823
    }

    /// Load API key from ~/.screenmuse/api_key, env var, or auto-generate one.
    private func loadOrGenerateAPIKey() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let keyDir = home.appendingPathComponent(".screenmuse", isDirectory: true)
        let keyFile = keyDir.appendingPathComponent("api_key")

        // 1. If ~/.screenmuse/api_key exists, use it
        if fm.fileExists(atPath: keyFile.path) {
            if let contents = try? String(contentsOf: keyFile, encoding: .utf8) {
                let key = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    apiKey = key
                    smLog.info("ScreenMuse API key: \(key) (from ~/.screenmuse/api_key)", category: .server)
                    return
                }
            }
        }

        // 2. If SCREENMUSE_API_KEY env var is set, use it (legacy)
        if let envKey = ProcessInfo.processInfo.environment["SCREENMUSE_API_KEY"], !envKey.isEmpty {
            apiKey = envKey
            smLog.info("ScreenMuse API key: \(envKey) (from SCREENMUSE_API_KEY env var)", category: .server)
            return
        }

        // 3. If SCREENMUSE_NO_AUTH=1, disable auth explicitly
        if ProcessInfo.processInfo.environment["SCREENMUSE_NO_AUTH"] == "1" {
            apiKey = nil
            smLog.info("ScreenMuse running without authentication (SCREENMUSE_NO_AUTH=1)", category: .server)
            return
        }

        // 4. Auto-generate a key, write it to ~/.screenmuse/api_key
        let generatedKey = UUID().uuidString
        do {
            try fm.createDirectory(at: keyDir, withIntermediateDirectories: true)
            try generatedKey.write(to: keyFile, atomically: true, encoding: .utf8)
            apiKey = generatedKey
            smLog.info("ScreenMuse API key: \(generatedKey) (from ~/.screenmuse/api_key)", category: .server)
        } catch {
            // If we can't write the file, still use the generated key for this session
            apiKey = generatedKey
            smLog.warning("Could not write API key to ~/.screenmuse/api_key: \(error.localizedDescription). Using session-only key.", category: .server)
        }
    }

    public func stop() {
        listener?.cancel()
        smLog.info("NWListener stopped", category: .server)
    }

    private func handleConnection(_ connection: NWConnection) {
        activeConnectionCount += 1
        smLog.debug("Connection accepted — active=\(activeConnectionCount)", category: .server)

        // Monitor connection state transitions so failed/cancelled connections are
        // always cleaned up and never accumulate as leaked file descriptors.
        // Without this handler, a client that connects then drops immediately would
        // leave the NWConnection object alive, consuming a file descriptor indefinitely.
        // Enough of these will exhaust the process limit and cause the listener to stop
        // accepting new connections (the symptom reported in issue #13).
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    // Connection is established — safe to start reading.
                    self.receiveRequest(connection)
                case .failed(let error):
                    self.activeConnectionCount = max(0, self.activeConnectionCount - 1)
                    smLog.debug("Incoming connection failed: \(error.localizedDescription) — active=\(self.activeConnectionCount)", category: .server)
                    connection.cancel()
                case .cancelled:
                    self.activeConnectionCount = max(0, self.activeConnectionCount - 1)
                    smLog.debug("Connection cancelled — active=\(self.activeConnectionCount)", category: .server)
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    /// Maximum HTTP body size: 4 MB.  Requests larger than this are rejected.
    private static let maxBodySize = 4_194_304

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { @Sendable [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty else {
                if let error { smLog.debug("Connection closed with error: \(error)", category: .server) }
                connection.cancel()
                return
            }
            Task { @MainActor in
                // We have the first chunk — check if the full body has arrived.
                // HTTP headers end at \r\n\r\n; everything after is the body.
                self.accumulateBody(connection: connection, buffer: data)
            }
        }
    }

    /// Accumulate HTTP body chunks until Content-Length is satisfied, connection
    /// closes, or the 4 MB hard cap is hit.
    private func accumulateBody(connection: NWConnection, buffer: Data) {
        // Look for end-of-headers in the accumulated data
        let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let headerEndRange = buffer.range(of: headerTerminator) else {
            // Haven't received full headers yet — keep reading
            if buffer.count > Self.maxBodySize {
                smLog.warning("Request too large (\(buffer.count) bytes) — rejecting", category: .server)
                sendResponse(connection: connection, status: 413, body: ["error": "Request entity too large", "max_bytes": Self.maxBodySize])
                return
            }
            receiveNextChunk(connection: connection, buffer: buffer)
            return
        }

        let headerEnd = headerEndRange.upperBound
        let headerData = buffer[buffer.startIndex..<headerEndRange.lowerBound]
        let headerStr = String(data: headerData, encoding: .utf8) ?? ""

        // Parse Content-Length from headers
        var contentLength: Int? = nil
        for line in headerStr.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(val)
                break
            }
        }

        let bodyReceived = buffer.count - headerEnd

        if let cl = contentLength {
            if cl > Self.maxBodySize {
                smLog.warning("Content-Length \(cl) exceeds max \(Self.maxBodySize) — rejecting", category: .server)
                sendResponse(connection: connection, status: 413, body: ["error": "Request entity too large", "max_bytes": Self.maxBodySize])
                return
            }
            if bodyReceived >= cl {
                // Full body received
                Task { @MainActor in
                    await self.processHTTPRequest(data: buffer, connection: connection)
                }
                return
            }
            // Need more data
            receiveNextChunk(connection: connection, buffer: buffer, contentLength: cl, headerEnd: headerEnd)
        } else {
            // No Content-Length header — for GET/DELETE or empty body, process immediately
            Task { @MainActor in
                await self.processHTTPRequest(data: buffer, connection: connection)
            }
        }
    }

    /// Read the next chunk from the connection and accumulate into the buffer.
    private func receiveNextChunk(connection: NWConnection, buffer: Data, contentLength: Int? = nil, headerEnd: Int? = nil) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { @Sendable [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                var accumulated = buffer
                if let data, !data.isEmpty {
                    accumulated.append(data)
                }

                // Hard cap check
                if accumulated.count > Self.maxBodySize {
                    smLog.warning("Accumulated \(accumulated.count) bytes exceeds max — rejecting", category: .server)
                    self.sendResponse(connection: connection, status: 413, body: ["error": "Request entity too large", "max_bytes": Self.maxBodySize])
                    return
                }

                if let cl = contentLength, let he = headerEnd {
                    let bodyReceived = accumulated.count - he
                    if bodyReceived >= cl || isComplete || (data == nil && error != nil) {
                        await self.processHTTPRequest(data: accumulated, connection: connection)
                        return
                    }
                    // Still need more
                    self.receiveNextChunk(connection: connection, buffer: accumulated, contentLength: cl, headerEnd: he)
                } else if isComplete || (data == nil && error != nil) {
                    // Connection closed — process what we have
                    await self.processHTTPRequest(data: accumulated, connection: connection)
                } else {
                    // No content-length, still accumulating headers
                    self.accumulateBody(connection: connection, buffer: accumulated)
                }
            }
        }
    }

    // MARK: - Request Dispatch

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

        // Parse request headers (lines between request line and blank line)
        var requestHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                requestHeaders[key] = value
            }
        }

        // API key auth — skip OPTIONS (preflight) and /health (liveness probes)
        if !checkAPIKey(required: apiKey, provided: requestHeaders["x-screenmuse-key"], method: method, path: path) {
            smLog.warning("[\(reqID)] 401 — invalid or missing X-ScreenMuse-Key", category: .server)
            sendResponse(connection: connection, status: 401, body: [
                "error": "Unauthorized",
                "code": "INVALID_API_KEY",
                "suggestion": "Include your API key in the X-ScreenMuse-Key header"
            ])
            return
        }

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
                    if let n = Int(v) { body[k] = n }
                    else if let d = Double(v) { body[k] = d }
                    else { body[k] = v }
                }
            }
        } else {
            cleanPath = path
        }

        smLog.info("[\(reqID)] → \(method) \(cleanPath) body=\(body.isEmpty ? "{}" : "\(body)")", category: .server)

        // CORS preflight
        if method == "OPTIONS" {
            let headers = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-ScreenMuse-Key\r\n\r\n"
            if let data = headers.data(using: .utf8) {
                connection.send(content: data, completion: .contentProcessed { @Sendable _ in connection.cancel() })
            }
            return
        }

        // ┌──────────────────────────────────────────────────────────────┐
        // │  Route Table                                                  │
        // │  Grouped by category. To add a new route:                     │
        // │    1. Add the case to the appropriate group below             │
        // │    2. Implement the handler in the corresponding extension    │
        // │    3. Add the endpoint to handleVersion() in Server+System   │
        // └──────────────────────────────────────────────────────────────┘
        switch (method, cleanPath) {

        // MARK: Recording — Server+Recording.swift
        case ("POST", "/record"):                await handleRecord(body: body, connection: connection, reqID: reqID)
        case ("POST", "/start"):                 await handleStart(body: body, connection: connection, reqID: reqID)
        case ("POST", "/stop"):
            if await handlePiPStop(body: body, connection: connection, reqID: reqID) { return }
            await handleStop(body: body, connection: connection, reqID: reqID)
        case ("POST", "/pause"):                 await handlePause(body: body, connection: connection, reqID: reqID)
        case ("POST", "/resume"):                await handleResume(body: body, connection: connection, reqID: reqID)
        case ("POST", "/chapter"):               handleChapter(body: body, connection: connection, reqID: reqID)
        case ("POST", "/highlight"):             handleHighlight(body: body, connection: connection, reqID: reqID)
        case ("POST", "/note"):                  handleNote(body: body, connection: connection, reqID: reqID)
        case ("POST", "/screenshot"):            await handleScreenshot(body: body, connection: connection, reqID: reqID)
        case ("POST", "/start/pip"):             await handleStartPiP(body: body, connection: connection, reqID: reqID)

        // MARK: Export — Server+Export.swift
        case ("POST", "/export"):                await handleExport(body: body, connection: connection, reqID: reqID)
        case ("POST", "/trim"):                  await handleTrim(body: body, connection: connection, reqID: reqID)
        case ("POST", "/speedramp"):             await handleSpeedRamp(body: body, connection: connection, reqID: reqID)
        case ("POST", "/concat"):                await handleConcat(body: body, connection: connection, reqID: reqID)
        case ("POST", "/frames"):                await handleFrames(body: body, connection: connection, reqID: reqID)
        case ("POST", "/frame"):                 await handleFrame(body: body, connection: connection, reqID: reqID)
        case ("POST", "/thumbnail"):             await handleThumbnail(body: body, connection: connection, reqID: reqID)
        case ("POST", "/crop"):                  await handleCrop(body: body, connection: connection, reqID: reqID)
        case ("POST", "/ocr"):                   await handleOCR(body: body, connection: connection, reqID: reqID)

        // MARK: Stream — Server+Stream.swift
        case ("GET", "/stream"):                 handleStream(body: body, connection: connection, reqID: reqID)
        case ("GET", "/stream/status"):          handleStreamStatus(body: body, connection: connection, reqID: reqID)

        // MARK: Window — Server+Window.swift
        case ("GET", "/windows"):                await handleWindows(body: body, connection: connection, reqID: reqID)
        case ("POST", "/window/focus"):          handleWindowFocus(body: body, connection: connection, reqID: reqID)
        case ("POST", "/window/position"):       handleWindowPosition(body: body, connection: connection, reqID: reqID)
        case ("POST", "/window/hide-others"):    handleWindowHideOthers(body: body, connection: connection, reqID: reqID)

        // MARK: Jobs — Server+System.swift
        case ("GET", _) where cleanPath.hasPrefix("/job/"):
            let jobID = String(cleanPath.dropFirst("/job/".count))
            await handleJob(jobID: jobID, connection: connection, reqID: reqID)
        case ("GET", "/jobs"):                   await handleJobs(connection: connection, reqID: reqID)

        // MARK: System — Server+System.swift
        case ("GET", "/health"):                 handleHealth(body: body, connection: connection, reqID: reqID)
        case ("GET", "/status"):                 handleStatus(body: body, connection: connection, reqID: reqID)
        case ("GET", "/debug"):                  handleDebug(body: body, connection: connection, reqID: reqID)
        case ("GET", "/logs"):                   handleLogs(body: body, connection: connection, reqID: reqID)
        case ("GET", "/report"):                 handleReport(body: body, connection: connection, reqID: reqID)
        case ("GET", "/version"):                handleVersion(body: body, connection: connection, reqID: reqID)
        case ("GET", "/recordings"):             handleRecordings(body: body, connection: connection, reqID: reqID)
        case ("DELETE", "/recording"):           handleDeleteRecording(body: body, connection: connection, reqID: reqID)
        case ("GET", "/openapi"):                handleOpenAPI(body: body, connection: connection, reqID: reqID)
        case ("GET", "/system/clipboard"):       handleSystemClipboard(body: body, connection: connection, reqID: reqID)
        case ("GET", "/system/active-window"):   handleSystemActiveWindow(body: body, connection: connection, reqID: reqID)
        case ("GET", "/system/running-apps"):    handleSystemRunningApps(body: body, connection: connection, reqID: reqID)

        // MARK: Media & Batch — Server+Media.swift
        case ("GET", "/timeline"):               handleTimeline(body: body, connection: connection, reqID: reqID)
        case ("POST", "/validate"):              await handleValidate(body: body, connection: connection, reqID: reqID)
        case ("POST", "/annotate"):              await handleAnnotate(body: body, connection: connection, reqID: reqID)
        case ("POST", "/script"):                await handleScript(body: body, connection: connection, reqID: reqID)
        case ("POST", "/script/batch"):          await handleScriptBatch(body: body, connection: connection, reqID: reqID)
        case ("POST", "/upload/icloud"):         handleUploadICloud(body: body, connection: connection, reqID: reqID)

        // MARK: Sessions — SessionRegistry
        case ("GET", "/sessions"):               handleSessions(body: body, connection: connection, reqID: reqID)
        case ("GET", _) where cleanPath.hasPrefix("/session/"):
            let sid = String(cleanPath.dropFirst("/session/".count))
            handleGetSession(sessionID: sid, connection: connection, reqID: reqID)
        case ("DELETE", _) where cleanPath.hasPrefix("/session/"):
            let sid = String(cleanPath.dropFirst("/session/".count))
            handleDeleteSession(sessionID: sid, connection: connection, reqID: reqID)

        default:
            smLog.warning("[\(reqID)] 404 — \(method) \(cleanPath) not found", category: .server)
            sendResponse(connection: connection, status: 404, body: ["error": "not found"])
        }
    }

    // MARK: - Shared Helpers

    /// POST the recording-complete payload to a webhook URL.
    /// Retries up to 3 times with exponential backoff (0s, 2s, 8s).
    /// Does not block the response to the caller.
    static let webhookBackoffSeconds: [Double] = [0, 2, 8]

    func fireWebhook(_ webhookURL: URL?, videoURL: URL, sessionID: String?, elapsed: TimeInterval) {
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
            let maxRetries = Self.webhookBackoffSeconds.count
            for attempt in 0..<maxRetries {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(Self.webhookBackoffSeconds[attempt] * 1_000_000_000))
                }
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("ScreenMuse/1.1", forHTTPHeaderField: "User-Agent")
                    request.timeoutInterval = 10
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if code >= 200 && code < 300 {
                        smLog.info("Webhook: delivered → \(url.host ?? url.absoluteString) HTTP \(code)\(attempt > 0 ? " (attempt \(attempt+1))" : "")", category: .server)
                        smLog.usage("WEBHOOK FIRED", details: ["url": url.host ?? "?", "status": "\(code)"])
                        return  // success, done
                    }
                    smLog.warning("Webhook: attempt \(attempt+1) got HTTP \(code) → \(url.host ?? "?")", category: .server)
                } catch {
                    smLog.warning("Webhook: attempt \(attempt+1) failed → \(error.localizedDescription)", category: .server)
                }
            }
            smLog.error("Webhook: all \(maxRetries) attempts failed → \(url.absoluteString)", category: .server)
        }
    }

    // MARK: - Async Job Dispatch

    /// Wraps a long-running endpoint for async execution. If `body["async"]` is true,
    /// returns 202 with a job ID immediately and fires the handler in a background Task.
    /// The handler's `sendResponse` call is intercepted via `activeJobID` and routed to the JobQueue.
    ///
    /// Returns `true` if async dispatch was triggered (caller should `return` immediately).
    func dispatchAsync(
        endpoint: String,
        body: [String: Any],
        connection: NWConnection,
        reqID: Int,
        handler: @escaping @MainActor ([String: Any], NWConnection, Int) async -> Void
    ) async -> Bool {
        guard body["async"] as? Bool == true else { return false }
        let jobID = await JobQueue.shared.create(endpoint: endpoint)
        sendResponse(connection: connection, status: 202, body: [
            "job_id": jobID, "status": "pending", "poll": "/job/\(jobID)"
        ])
        Task { @MainActor in
            await JobQueue.shared.setRunning(jobID)
            var syncBody = body
            syncBody.removeValue(forKey: "async")
            // Create a dummy connection mapped to the job ID.
            // When sendResponse is called with this connection, it routes to the JobQueue.
            let dummyConn = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
            let connID = ObjectIdentifier(dummyConn)
            self.jobConnections[connID] = jobID
            await handler(syncBody, dummyConn, reqID)
            // If mapping is still present (handler didn't call sendResponse), clean up
            if self.jobConnections.removeValue(forKey: connID) != nil {
                await JobQueue.shared.fail(jobID, error: "Handler completed without sending a response")
            }
        }
        return true
    }

    /// Compute average brightness of a CGImage (0.0 = black, 1.0 = white).
    func averageBrightness(of cgImage: CGImage) -> Double {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return 0 }

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
            totalBrightness += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }
        return totalBrightness / Double(pixelCount)
    }

    /// Build an enriched stop response with video metadata.
    /// Never returns undefined/null for required fields — uses sensible defaults.
    func enrichedStopResponse(
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

        let asset = AVURLAsset(url: videoURL)
        var width = 0
        var height = 0
        var fps: Double = 0
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

        var windowInfo: [String: Any] = [:]
        if let app = windowApp { windowInfo["app"] = app }
        if let pid = windowPid { windowInfo["pid"] = pid }
        if let title = windowTitle { windowInfo["title"] = title }
        if !windowInfo.isEmpty {
            resp["window"] = windowInfo
        }

        return resp
    }

    func structuredError(_ error: Error) -> [String: Any] {
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

    func sendResponse(connection: NWConnection, status: Int, body: [String: Any]) {
        // If running inside an async job, route result to the JobQueue instead of the wire.
        let connID = ObjectIdentifier(connection)
        if let jobID = jobConnections.removeValue(forKey: connID) {
            Task {
                if status >= 200 && status < 400 {
                    await JobQueue.shared.complete(jobID, result: body)
                } else {
                    await JobQueue.shared.fail(jobID, error: body["error"] as? String ?? "Unknown error")
                }
            }
            return
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let statusTexts = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        let statusText = statusTexts[status] ?? "Unknown"
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(jsonStr)"

        guard let responseData = response.data(using: .utf8) else { return }
        connection.send(content: responseData, completion: .contentProcessed { @Sendable _ in
            connection.cancel()
        })
    }
}
