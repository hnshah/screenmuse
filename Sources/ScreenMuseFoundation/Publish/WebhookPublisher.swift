import Foundation

/// Generic webhook publisher — POSTs a JSON metadata envelope to an
/// arbitrary URL.
///
/// Works with Zapier, n8n, Slack incoming webhooks, Discord, or any custom
/// HTTP endpoint that expects a JSON body.  Does NOT upload the file bytes
/// (pair with HTTPPutPublisher first, then reference the resulting URL in
/// the metadata).
public struct WebhookPublisher: Publisher {

    public let name = "webhook"

    public init() {}

    public func publish(video: URL, config: PublishConfig) async throws -> PublishResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: video.path) else {
            throw PublishError.fileNotFound(video.path)
        }

        let fileSize = (try? fm.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0

        // Pre-serialize in a pure helper so the non-Sendable [String: Any]
        // dict never crosses the URLSession await boundary — keeps Swift 6
        // strict concurrency happy.
        let payloadData: Data
        do {
            payloadData = try Self.buildWebhookPayload(
                video: video,
                fileSize: fileSize,
                config: config
            )
        } catch {
            throw PublishError.networkFailure("payload encoding failed: \(error.localizedDescription)")
        }

        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ScreenMuse/1.1", forHTTPHeaderField: "User-Agent")
        for (k, v) in config.extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        if let token = config.apiToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payloadData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PublishError.networkFailure(error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""

        if code < 200 || code >= 300 {
            if code == 401 || code == 403 { throw PublishError.unauthorized }
            throw PublishError.httpFailed(code, Self.tail(body))
        }

        return PublishResult(
            destination: name,
            url: config.url.absoluteString,
            statusCode: code,
            responseBody: Self.tail(body),
            bytesSent: Int64(request.httpBody?.count ?? 0)
        )
    }

    static func tail(_ s: String) -> String {
        s.count > 512 ? String(s.suffix(512)) : s
    }

    /// Build the webhook envelope bytes. Pure, synchronous, no
    /// non-Sendable state leaks — the `[String: Any]` dict lives
    /// only inside this function.
    static func buildWebhookPayload(
        video: URL,
        fileSize: Int,
        config: PublishConfig
    ) throws -> Data {
        let sizeMB = (Double(fileSize) / 1_048_576 * 100).rounded() / 100
        var payload: [String: Any] = [
            "event": "recording.published",
            "video_path": video.path,
            "filename": video.lastPathComponent,
            "size_bytes": fileSize,
            "size_mb": sizeMB,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        // Merge caller metadata in — everything string-typed so the shape
        // stays stable for downstream parsers.
        for (k, v) in config.metadata { payload[k] = v }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
