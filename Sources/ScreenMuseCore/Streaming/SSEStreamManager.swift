import CoreImage
import AppKit
import Foundation
import Network
@preconcurrency import ScreenCaptureKit

/// Manages Server-Sent Events (SSE) connections for real-time frame streaming.
///
/// Agents connect to `GET /stream` and receive a continuous push of JPEG/PNG
/// frames captured from the primary display, useful for watching what's
/// happening on screen without polling.
///
/// SSE wire format:
///   event: frame
///   data: {"ts":1711299600.0,"width":1280,"height":720,"format":"jpeg","size":14321,"data":"<base64>"}
///
/// Heartbeat every 15s (keeps TCP alive through proxies):
///   :keep-alive
///
/// Config (via URL query params):
///   fps      — frames per second, 1–30 (default 2)
///   scale    — max width in pixels (default 1280)
///   format   — "jpeg" or "png" (default jpeg)
///   quality  — JPEG quality 0–100 (default 60)
///
/// Usage:
///   curl -N "http://localhost:7823/stream"
///   curl -N "http://localhost:7823/stream?fps=5&scale=640&quality=80"
///
/// Node.js (no EventSource dep):
///   const http = require('http');
///   const req = http.get('http://localhost:7823/stream?fps=2', res => {
///     res.on('data', chunk => { /* parse SSE lines */ });
///   });
@MainActor
public final class SSEStreamManager {

    // MARK: - Types

    public struct StreamConfig: Sendable {
        public var fps: Int = 2       // 1–30 frames per second
        public var scale: Int = 1280  // max output width in pixels
        public var format: Format = .jpeg
        public var quality: Int = 60  // JPEG quality 0–100

        public enum Format: String, Sendable {
            case jpeg, png
        }

        public init(fps: Int = 2, scale: Int = 1280, format: Format = .jpeg, quality: Int = 60) {
            self.fps = min(30, max(1, fps))
            self.scale = min(3840, max(64, scale))
            self.format = format
            self.quality = min(100, max(1, quality))
        }
    }

    private struct Client {
        let id: String
        let connection: NWConnection
        let config: StreamConfig
        var framesSent: Int = 0
        var lastSentAt: Date = .distantPast
    }

    // MARK: - State

    private var clients: [Client] = []
    private var captureTimer: DispatchSourceTimer?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var cachedDisplay: SCDisplay?
    private var displayCacheTime: Date = .distantPast
    private var tickCount: UInt64 = 0

    // MARK: - Public Interface

    public var activeClientCount: Int { clients.count }
    public var totalFramesSent: Int { clients.reduce(0) { $0 + $1.framesSent } }

    /// Add a new SSE client connection. Sends the SSE handshake headers and starts the timer.
    public func addClient(_ connection: NWConnection, config: StreamConfig) {
        let id = UUID().uuidString
        var client = Client(id: id, connection: connection, config: config)
        client.lastSentAt = .distantPast

        // Detect disconnect
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.removeClient(id: id) }
            default:
                break
            }
        }

        clients.append(client)
        smLog.info("SSEStreamManager: +client id=\(id) fps=\(config.fps) scale=\(config.scale) format=\(config.format.rawValue) total=\(clients.count)", category: .capture)
        smLog.usage("STREAM CONNECT", details: ["fps": "\(config.fps)", "scale": "\(config.scale)"])

        // Send initial hello event
        let helloPayload: [String: Any] = [
            "event": "connected",
            "client_id": id,
            "fps": config.fps,
            "scale": config.scale,
            "format": config.format.rawValue,
            "quality": config.quality,
            "server": "ScreenMuse"
        ]
        sendSSEEvent(to: connection, event: "hello", payload: helloPayload)

        if clients.count == 1 {
            startTimer()
        }
    }

    private func removeClient(id: String) {
        guard let client = clients.first(where: { $0.id == id }) else { return }
        smLog.info("SSEStreamManager: -client id=\(id) frames_sent=\(client.framesSent) remaining=\(clients.count - 1)", category: .capture)
        smLog.usage("STREAM DISCONNECT", details: ["id": id, "frames": "\(client.framesSent)"])
        clients.removeAll { $0.id == id }
        if clients.isEmpty {
            stopTimer()
            cachedDisplay = nil
        }
    }

    // MARK: - Capture Timer

    /// Timer fires at 30 Hz (max supported fps). Each client has its own
    /// interval, so we skip frames for clients that want lower fps.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(flags: [], queue: .global(qos: .userInteractive))
        // 30 Hz base rate
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        timer.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
        timer.resume()
        captureTimer = timer
        smLog.info("SSEStreamManager: timer started (30Hz base)", category: .capture)
    }

    private func stopTimer() {
        captureTimer?.cancel()
        captureTimer = nil
        tickCount = 0
        smLog.info("SSEStreamManager: timer stopped", category: .capture)
    }

    // MARK: - Tick

    private func tick() async {
        guard !clients.isEmpty else { return }
        tickCount &+= 1

        // Heartbeat every ~15 seconds (30Hz × 450 ≈ 15s)
        if tickCount % 450 == 0 {
            for client in clients {
                sendSSEHeartbeat(to: client.connection)
            }
        }

        let now = Date()

        // Determine which clients need a frame right now
        let clientsNeedingFrame = clients.filter { client in
            let interval = 1.0 / Double(client.config.fps)
            return now.timeIntervalSince(client.lastSentAt) >= interval - 0.010 // 10ms tolerance
        }
        guard !clientsNeedingFrame.isEmpty else { return }

        // Refresh display reference every 60 seconds
        let displayAge = now.timeIntervalSince(displayCacheTime)
        if cachedDisplay == nil || displayAge > 60 {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedDisplay = content?.displays.first
            displayCacheTime = now
        }
        guard let display = cachedDisplay else { return }

        // Capture at the highest scale any client needs (one screenshot → multiple scaled outputs)
        let maxScale = clientsNeedingFrame.map { $0.config.scale }.max() ?? 1280

        let streamCfg = SCStreamConfiguration()
        streamCfg.width = maxScale * 2    // Retina: capture 2× then let CIFilter downscale
        streamCfg.height = maxScale * 2
        streamCfg.minimumFrameInterval = .zero
        streamCfg.pixelFormat = kCVPixelFormatType_32BGRA

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: streamCfg
        ) else {
            // Display disappeared — clear cache so we refetch next tick
            cachedDisplay = nil
            return
        }

        let srcWidth = cgImage.width
        let srcHeight = cgImage.height
        let ciImage = CIImage(cgImage: cgImage)

        // Encode and send for each client
        for client in clientsNeedingFrame {
            let targetWidth = min(client.config.scale, srcWidth)
            let targetHeight = Int(Double(targetWidth) * Double(srcHeight) / Double(srcWidth))

            var scaledCI = ciImage
            if targetWidth < srcWidth {
                let sx = Double(targetWidth) / Double(srcWidth)
                let sy = Double(targetHeight) / Double(srcHeight)
                if let f = CIFilter(name: "CILanczosScaleTransform") {
                    f.setValue(ciImage, forKey: kCIInputImageKey)
                    f.setValue(Float(sx), forKey: kCIInputScaleKey)
                    f.setValue(Float(sy / sx), forKey: kCIInputAspectRatioKey)
                    scaledCI = f.outputImage ?? ciImage
                }
            }

            let renderRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            guard let outCGImage = ciContext.createCGImage(scaledCI, from: renderRect) else { continue }

            let imageData: Data?
            switch client.config.format {
            case .jpeg:
                imageData = encodeJPEG(outCGImage, quality: Double(client.config.quality) / 100.0)
            case .png:
                imageData = encodePNG(outCGImage)
            }
            guard let data = imageData else { continue }

            let payload: [String: Any] = [
                "ts": now.timeIntervalSince1970,
                "width": targetWidth,
                "height": targetHeight,
                "format": client.config.format.rawValue,
                "size": data.count,
                "data": data.base64EncodedString()
            ]
            sendSSEEvent(to: client.connection, event: "frame", payload: payload)

            // Update client state
            if let idx = clients.firstIndex(where: { $0.id == client.id }) {
                clients[idx].lastSentAt = now
                clients[idx].framesSent += 1
            }
        }
    }

    // MARK: - Image Encoding

    private func encodeJPEG(_ cgImage: CGImage, quality: Double) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func encodePNG(_ cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    // MARK: - SSE Writing

    /// Send the HTTP SSE response headers. Must be called exactly once per connection,
    /// before any event data. Does NOT close the connection.
    public func sendSSEHandshake(to connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/event-stream\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: keep-alive\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "X-Accel-Buffering: no\r\n" +
            "X-ScreenMuse-Version: \(ScreenMuseServer.currentVersion)\r\n" +
            "\r\n"
        guard let data = headers.data(using: .utf8) else { return }
        // isComplete: false — keeps the connection open
        connection.send(content: data, contentContext: .defaultMessage,
                        isComplete: false, completion: .contentProcessed { @Sendable _ in })
    }

    private func sendSSEEvent(to connection: NWConnection, event: String, payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        // SSE format: "event: name\ndata: {json}\n\n"
        let sseStr = "event: \(event)\ndata: \(jsonStr)\n\n"
        guard let sseData = sseStr.data(using: .utf8) else { return }
        connection.send(content: sseData, contentContext: .defaultMessage,
                        isComplete: false, completion: .contentProcessed { @Sendable error in
            if let error {
                smLog.debug("SSEStreamManager: send failed — \(error.localizedDescription)", category: .capture)
            }
        })
    }

    private func sendSSEHeartbeat(to connection: NWConnection) {
        guard let data = ":keep-alive\n\n".data(using: .utf8) else { return }
        connection.send(content: data, contentContext: .defaultMessage,
                        isComplete: false, completion: .contentProcessed { @Sendable _ in })
    }
}
