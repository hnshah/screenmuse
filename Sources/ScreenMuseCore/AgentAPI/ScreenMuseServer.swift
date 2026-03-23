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
    private let recordingManager = RecordingManager()

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
                sendResponse(connection: connection, status: 409, body: ["error": "already recording"])
                return
            }
            let name = body["name"] as? String ?? "recording-\(Date().timeIntervalSince1970)"
            let config = RecordingConfig(captureSource: .fullScreen, includeSystemAudio: true, includeMicrophone: false)
            do {
                try await recordingManager.startRecording(config: config)
                sessionID = UUID().uuidString
                sessionName = name
                startTime = Date()
                isRecording = true
                chapters = []
                highlightNextClick = false
                currentVideoURL = nil
                sendResponse(connection: connection, status: 200, body: [
                    "session_id": sessionID!,
                    "status": "recording",
                    "name": name
                ])
            } catch {
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }

        case ("POST", "/stop"):
            guard isRecording else {
                sendResponse(connection: connection, status: 409, body: ["error": "not recording"])
                return
            }
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            do {
                let url = try await recordingManager.stopRecording()
                currentVideoURL = url
                isRecording = false
                let metadata: [String: Any] = [
                    "session_id": sessionID ?? "",
                    "name": sessionName ?? "",
                    "elapsed": elapsed,
                    "chapters": chapters.map { ["name": $0.name, "time": $0.time] }
                ]
                sessionID = nil
                sessionName = nil
                startTime = nil
                sendResponse(connection: connection, status: 200, body: [
                    "video_path": url.path,
                    "metadata": metadata
                ])
            } catch {
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
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
