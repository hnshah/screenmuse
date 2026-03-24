import Foundation
import Network
import ScreenCaptureKit
import AppKit

// Local HTTP server for programmatic agent control
// Endpoints:
//   POST /start    body: {"name": "recording-name"}  → {"session_id": "uuid", "status": "recording"}
//   POST /stop     → {"video_path": "/path/video.mp4", "metadata": {...}}
//   POST /chapter  body: {"name": "Chapter name"}   → {"ok": true}
//   POST /highlight  → {"ok": true}
//   POST /screenshot body: {"path": "/optional/path.png"}  → {"path": "...", "width": N, "height": N}
//   GET  /status     → {"recording": true, "elapsed": 12.3, "chapters": [...]}
//   GET  /status   → {"recording": true, "elapsed": 12.3, "chapters": [...]}

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

    public func start() throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: 7823)
        listener?.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.handleConnection(conn)
            }
        }
        listener?.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(connection)
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                await self.processHTTPRequest(data: data, connection: connection)
            }
        }
    }

    private func processHTTPRequest(data: Data, connection: NWConnection) async {
        guard let raw = String(data: data, encoding: .utf8) else {
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

        switch (method, path) {

        case ("POST", "/start"):
            guard !isRecording else {
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
            do {
                if let coord = coordinator {
                    try await coord.startRecording(name: name, windowTitle: windowTitle, windowPid: windowPid, quality: quality)
                } else {
                    // Fallback: raw recording, no effects
                    let source: CaptureSource
                    if let title = windowTitle {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        if let window = content.windows.first(where: { $0.title?.localizedCaseInsensitiveContains(title) ?? false }) {
                            source = .window(window)
                        } else {
                            sendResponse(connection: connection, status: 404, body: [
                                "error": "Window not found: '\(title)'",
                                "code": "WINDOW_NOT_FOUND",
                                "suggestion": "Call GET /windows to see available windows"
                            ])
                            return
                        }
                    } else {
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
                sendResponse(connection: connection, status: 200, body: resp)
            } catch let err as RecordingError {
                sendResponse(connection: connection, status: 500, body: structuredError(err))
            } catch {
                sendResponse(connection: connection, status: 500, body: [
                    "error": error.localizedDescription,
                    "code": "UNKNOWN_ERROR"
                ])
            }

        case ("POST", "/stop"):
            guard isRecording else {
                sendResponse(connection: connection, status: 409, body: ["error": "not recording"])
                return
            }
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
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
                // Full pipeline: waits for effects compositing to finish
                if let url = await coord.stopAndGetVideo() {
                    currentVideoURL = url
                    sendResponse(connection: connection, status: 200, body: [
                        "video_path": url.path,
                        "metadata": metadata
                    ])
                } else {
                    sendResponse(connection: connection, status: 500, body: ["error": "Recording stopped but video could not be finalized"])
                }
            } else {
                // Fallback: raw stop, no effects
                do {
                    let url = try await recordingManager.stopRecording()
                    currentVideoURL = url
                    sendResponse(connection: connection, status: 200, body: [
                        "video_path": url.path,
                        "metadata": metadata
                    ])
                } catch {
                    sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
                }
            }
            _ = capturedSessionID  // suppress unused warning
            _ = capturedSessionName

        case ("POST", "/pause"):
            guard isRecording else {
                sendResponse(connection: connection, status: 409, body: ["error": "Not recording", "code": "NOT_RECORDING"])
                return
            }
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            do {
                if let coord = coordinator {
                    try await coord.pauseRecording()
                } else {
                    try await recordingManager.pauseRecording()
                }
                sendResponse(connection: connection, status: 200, body: ["status": "paused", "elapsed": elapsed])
            } catch {
                sendResponse(connection: connection, status: 500, body: structuredError(error))
            }

        case ("POST", "/resume"):
            guard isRecording else {
                sendResponse(connection: connection, status: 409, body: ["error": "Not recording", "code": "NOT_RECORDING"])
                return
            }
            do {
                if let coord = coordinator {
                    try await coord.resumeRecording()
                } else {
                    try await recordingManager.resumeRecording()
                }
                let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                sendResponse(connection: connection, status: 200, body: ["status": "recording", "elapsed": elapsed])
            } catch {
                sendResponse(connection: connection, status: 500, body: structuredError(error))
            }

        case ("POST", "/chapter"):
            let name = body["name"] as? String ?? "Chapter"
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            chapters.append((name: name, time: elapsed))
            sendResponse(connection: connection, status: 200, body: ["ok": true, "time": elapsed])

        case ("POST", "/highlight"):
            highlightNextClick = true
            sendResponse(connection: connection, status: 200, body: ["ok": true])

        case ("GET", "/status"):
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            sendResponse(connection: connection, status: 200, body: [
                "recording": isRecording,
                "elapsed": elapsed,
                "session_id": sessionID ?? "",
                "chapters": chapters.map { ["name": $0.name, "time": $0.time] },
                "last_video": currentVideoURL?.path ?? ""
            ])

        case ("GET", "/windows"):
            // List on-screen windows available for capture
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
                sendResponse(connection: connection, status: 200, body: ["windows": windows, "count": windows.count])
            } catch {
                sendResponse(connection: connection, status: 500, body: structuredError(error))
            }

        case ("POST", "/screenshot"):
            // One-shot screenshot using SCScreenshotManager (WWDC23)
            // Optional body: {"path": "/full/path/to/save.png"}
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    sendResponse(connection: connection, status: 500, body: ["error": "No display found"])
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.pixelFormat = kCVPixelFormatType_32BGRA

                // Determine save path
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
                    let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    guard let pngData = rep.representation(using: .png, properties: [:]) else {
                        sendResponse(connection: connection, status: 500, body: ["error": "PNG conversion failed"])
                        return
                    }
                    try pngData.write(to: savePath)
                    sendResponse(connection: connection, status: 200, body: [
                        "path": savePath.path,
                        "width": cgImage.width,
                        "height": cgImage.height,
                        "size": pngData.count
                    ])
                } else {
                    sendResponse(connection: connection, status: 400, body: ["error": "Screenshot API requires macOS 14+"])
                }
            } catch {
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        case ("GET", "/debug"):
            // Diagnostic endpoint — shows save dir, recent recordings, permission status
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
                "server_recording": isRecording
            ])

        default:
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
