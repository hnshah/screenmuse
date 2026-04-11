import Foundation

/// Narration provider using Anthropic's Claude vision API.
///
/// Uses the `/v1/messages` endpoint with multimodal content blocks
/// (base64 image source) and a strict JSON-schema system prompt.
///
/// API key resolution order:
///   1. `config.apiKey` (per-request override)
///   2. `ANTHROPIC_API_KEY` environment variable
public struct ClaudeNarrationProvider: NarrationProvider {

    public let name = "anthropic"
    public let defaultModel = "claude-sonnet-4-6"

    /// Default API endpoint (messages API). Override via `config.endpoint`
    /// for custom routing (e.g. a local proxy, Bedrock, etc.).
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init() {}

    public func narrate(
        frames: [NarrationFrame],
        config: NarrationConfig
    ) async throws -> NarrationResult {
        guard !frames.isEmpty else { throw NarrationError.noFramesExtracted }

        let key = config.apiKey
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        guard let apiKey = key, !apiKey.isEmpty else {
            throw NarrationError.missingAPIKey("Anthropic Claude")
        }

        let endpoint = config.endpoint ?? Self.defaultEndpoint
        let system = NarrationPrompt.systemInstruction(
            style: config.style,
            maxChapters: config.maxChapters,
            language: config.language
        )

        // Content blocks: one "image" block per frame, interleaved with a
        // short text block telling Claude what timestamp each frame
        // corresponds to.
        var userContent: [[String: Any]] = []
        userContent.append([
            "type": "text",
            "text": "Here are \(frames.count) frames from a screen recording, in order. Generate the narration JSON."
        ])
        for frame in frames {
            userContent.append([
                "type": "text",
                "text": "Frame at t=\(String(format: "%.2f", frame.time))s:"
            ])
            userContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": frame.imageData.base64EncodedString()
                ]
            ])
        }

        let payload: [String: Any] = [
            "model": config.model,
            "max_tokens": 2048,
            "temperature": config.temperature,
            "system": system,
            "messages": [
                ["role": "user", "content": userContent]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw NarrationError.providerRequestFailed("could not encode Claude payload: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NarrationError.providerUnreachable(endpoint.absoluteString)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NarrationError.providerRequestFailed("no HTTPURLResponse from Claude")
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NarrationError.providerHTTPStatus(http.statusCode, tail(body))
        }

        // Claude messages API response shape:
        //   { "content": [ {"type": "text", "text": "…"} ], … }
        // There may be multiple content blocks; concatenate all text ones.
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw NarrationError.providerResponseMalformed("missing content array in Claude reply")
        }
        let combined = content
            .compactMap { block -> String? in
                if (block["type"] as? String) == "text" {
                    return block["text"] as? String
                }
                return nil
            }
            .joined(separator: "\n")
        guard !combined.isEmpty else {
            throw NarrationError.providerResponseMalformed("no text content blocks in Claude reply")
        }

        return try NarrationPrompt.parseResult(
            reply: combined,
            provider: name,
            model: config.model
        )
    }

    private func tail(_ s: String) -> String {
        s.count > 512 ? String(s.suffix(512)) : s
    }
}
