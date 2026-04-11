import Foundation
import Network

// MARK: - Publish Handler (POST /publish)
//
// Routes a recording to an external destination (Slack webhook, presigned
// HTTP PUT, generic webhook). Long-running for large files — supports
// async=true dispatch through the job queue.

extension ScreenMuseServer {

    func handlePublish(body: [String: Any], connection: NWConnection, reqID: Int) async {
        if await dispatchAsync(endpoint: "/publish", body: body, connection: connection, reqID: reqID,
                               handler: { b, c, r in await self.handlePublish(body: b, connection: c, reqID: r) }) { return }

        // ── Resolve source video ───────────────────────────────────────
        guard let src = resolveSourceURL(from: body, fallback: currentVideoURL),
              FileManager.default.fileExists(atPath: src.path) else {
            sendResponse(connection: connection, status: 404, body: [
                "error": "no video available — record first or pass 'source': '/path/to/video.mp4'",
                "code": "NO_VIDEO"
            ])
            return
        }

        // ── Destination + publisher lookup ─────────────────────────────
        let destinationName = (body["destination"] as? String ?? "webhook").lowercased()
        guard let publisher = PublisherRegistry.publisher(named: destinationName) else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "unknown destination '\(destinationName)'",
                "code": "UNKNOWN_DESTINATION",
                "known_destinations": PublisherRegistry.known
            ])
            return
        }

        // ── URL + headers + metadata ───────────────────────────────────
        guard let urlString = body["url"] as? String, let url = URL(string: urlString) else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "'url' is required and must be a valid URL",
                "code": "MISSING_URL"
            ])
            return
        }

        let extraHeaders = (body["headers"] as? [String: Any]).flatMap { dict -> [String: String] in
            dict.compactMapValues { $0 as? String }
        } ?? [:]
        let metadata = (body["metadata"] as? [String: Any]).flatMap { dict -> [String: String] in
            dict.compactMapValues { v in
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
                return nil
            }
        } ?? [:]
        let timeout = (body["timeout"] as? Double) ?? 120
        let apiToken = body["api_token"] as? String
        let filename = body["filename"] as? String

        let config = PublishConfig(
            url: url,
            extraHeaders: extraHeaders,
            metadata: metadata,
            timeout: timeout,
            apiToken: apiToken,
            filename: filename
        )

        smLog.info("[\(reqID)] /publish destination=\(destinationName) url=\(url.host ?? url.absoluteString) file=\(src.lastPathComponent)", category: .server)
        smLog.usage("PUBLISH", details: [
            "destination": destinationName,
            "host": url.host ?? "?",
            "file": src.lastPathComponent
        ])

        // ── Execute the publisher ──────────────────────────────────────
        do {
            let result = try await publisher.publish(video: src, config: config)
            smLog.info("[\(reqID)] ✅ /publish done — \(result.bytesSent) bytes to \(destinationName)", category: .server)
            smLog.usage("PUBLISH DONE", details: [
                "destination": destinationName,
                "bytes": "\(result.bytesSent)",
                "status": "\(result.statusCode)"
            ])
            sendResponse(connection: connection, status: 200, body: [
                "destination": result.destination,
                "url": result.url ?? "",
                "status_code": result.statusCode,
                "response_body": result.responseBody ?? "",
                "bytes_sent": result.bytesSent,
                "source": src.path
            ])
        } catch let error as PublishError {
            smLog.error("[\(reqID)] /publish failed: \(error.localizedDescription)", category: .server)
            let status: Int
            let code: String
            switch error {
            case .fileNotFound:      status = 404; code = "FILE_NOT_FOUND"
            case .invalidDestination:status = 400; code = "UNKNOWN_DESTINATION"
            case .invalidURL:        status = 400; code = "INVALID_URL"
            case .missingURL:        status = 400; code = "MISSING_URL"
            case .fileReadFailed:    status = 500; code = "FILE_READ_FAILED"
            case .httpFailed(let c, _): status = (c >= 400 && c < 500) ? 400 : 502; code = "UPSTREAM_HTTP_\(c)"
            case .networkFailure:    status = 503; code = "UPSTREAM_UNREACHABLE"
            case .unauthorized:      status = 401; code = "UPSTREAM_UNAUTHORIZED"
            }
            sendResponse(connection: connection, status: status, body: [
                "error": error.localizedDescription,
                "code": code,
                "destination": destinationName
            ])
        } catch {
            smLog.error("[\(reqID)] /publish failed (unknown): \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: [
                "error": error.localizedDescription,
                "code": "PUBLISH_ERROR",
                "destination": destinationName
            ])
        }
    }
}
