import Foundation
import Network

// MARK: - Stream Handlers (/stream, /stream/status)

extension ScreenMuseServer {

    func handleStream(body: [String: Any], connection: NWConnection, reqID: Int) {
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
    }

    func handleStreamStatus(body: [String: Any], connection: NWConnection, reqID: Int) {
        sendResponse(connection: connection, status: 200, body: [
            "active_clients": streamManager.activeClientCount,
            "total_frames_sent": streamManager.totalFramesSent
        ])
    }
}
