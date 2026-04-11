import Foundation

/// Slack publisher — POSTs a notification message to an incoming webhook URL.
///
/// Why webhook-only in v1: real file upload via Slack's API requires OAuth
/// tokens, the `files.getUploadURLExternal` flow (two requests), and a
/// follow-up `files.completeUploadExternal` call. Webhooks are one request,
/// zero auth plumbing, and cover the most common agent use case: "tell me
/// when the recording is done and give me a link I can follow manually".
///
/// For the file itself, pair this with `HTTPPutPublisher` to upload the
/// video to S3/R2 first, then pass the resulting URL into the Slack
/// webhook's `video_url` metadata field so the message contains the link.
public struct SlackPublisher: Publisher {

    public let name = "slack"

    public init() {}

    public func publish(video: URL, config: PublishConfig) async throws -> PublishResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: video.path) else {
            throw PublishError.fileNotFound(video.path)
        }

        let fileSize = (try? fm.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0

        // Pre-serialize the Block Kit payload in a pure helper so the
        // non-Sendable [String: Any] dict never crosses the URLSession
        // await boundary — keeps Swift 6 strict concurrency happy.
        let payloadData: Data
        do {
            payloadData = try Self.buildSlackPayload(
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
        for (k, v) in config.extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
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

        // Slack returns "ok" (text, not JSON) with 200 on success, and a
        // non-200 status code for bad webhooks. Anything in [200,299] is OK.
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

    /// Build the Slack Block Kit payload bytes. Pure, synchronous,
    /// no non-Sendable state leaks out — the `[String: Any]` dict
    /// exists only inside this function.
    static func buildSlackPayload(
        video: URL,
        fileSize: Int,
        config: PublishConfig
    ) throws -> Data {
        let sizeMB = Double(fileSize) / 1_048_576
        let filename = config.filename ?? video.lastPathComponent
        let durationStr = config.metadata["duration"] ?? "unknown"
        let videoURL = config.metadata["video_url"]

        var fields: [[String: Any]] = [
            ["type": "mrkdwn", "text": "*File*\n\(filename)"],
            ["type": "mrkdwn", "text": "*Size*\n\(String(format: "%.1f MB", sizeMB))"],
            ["type": "mrkdwn", "text": "*Duration*\n\(durationStr)"]
        ]
        for (k, v) in config.metadata where k != "duration" && k != "video_url" {
            fields.append(["type": "mrkdwn", "text": "*\(k.capitalized)*\n\(v)"])
        }

        var blocks: [[String: Any]] = [
            [
                "type": "header",
                "text": ["type": "plain_text", "text": "📹 ScreenMuse recording ready"]
            ],
            [
                "type": "section",
                "fields": fields
            ]
        ]
        if let videoLink = videoURL, URL(string: videoLink) != nil {
            blocks.append([
                "type": "actions",
                "elements": [[
                    "type": "button",
                    "text": ["type": "plain_text", "text": "Open video"],
                    "url": videoLink,
                    "style": "primary"
                ]]
            ])
        }

        let payload: [String: Any] = [
            "text": "ScreenMuse recording ready: \(filename) (\(String(format: "%.1f MB", sizeMB)))",
            "blocks": blocks
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
