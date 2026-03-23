import Foundation
import Network

// Local HTTP server for programmatic agent control
// Endpoints:
//   POST /start    body: {"name": "recording-name"}  → {"session_id": "uuid", "status": "recording"}
//   POST /stop     → {"video_path": "/path/video.mp4", "metadata": {...}}
//   POST /chapter  body: {"name": "Chapter name"}   → {"ok": true}
//   POST /highlight → {"ok": true}
//   GET  /status   → {"recording": true, "elapsed": 12.3, "chapters": [...]}

@MainActor
public class ScreenMuseServer {
    public static let shared = ScreenMuseServer()
    private var listener: NWListener?
    public private(set) var isRecording = false
    public private(set) var sessionName: String?
    public private(set) var sessionID: String?
    public private(set) var startTime: Date?
    public private(set) var chapters: [(name: String, time: TimeInterval)] = []
    public private(set) var highlightNextClick = false

    public func start() throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: 7823)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            self.processHTTPRequest(data: data, connection: connection)
        }
    }

    private func processHTTPRequest(data: Data, connection: NWConnection) {
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
            let name = body["name"] as? String ?? "recording-\(Date().timeIntervalSince1970)"
            sessionID = UUID().uuidString
            sessionName = name
            startTime = Date()
            isRecording = true
            chapters = []
            highlightNextClick = false
            sendResponse(connection: connection, status: 200, body: [
                "session_id": sessionID!,
                "status": "recording",
                "name": name
            ])

        case ("POST", "/stop"):
            isRecording = false
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
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
                "video_path": NSHomeDirectory() + "/Movies/ScreenMuse/recording.mp4",
                "metadata": metadata
            ])

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
                "chapters": chapters.map { ["name": $0.name, "time": $0.time] }
            ])

        default:
            sendResponse(connection: connection, status: 404, body: ["error": "not found"])
        }
    }

    private func sendResponse(connection: NWConnection, status: Int, body: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let statusText = status == 200 ? "OK" : status == 400 ? "Bad Request" : "Not Found"
        let response = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(jsonStr)"

        guard let responseData = response.data(using: .utf8) else { return }
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
