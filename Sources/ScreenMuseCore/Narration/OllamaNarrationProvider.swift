import Foundation

/// Local narration provider using Ollama (https://ollama.com).
///
/// Hits the Ollama HTTP API at `$OLLAMA_HOST` (or
/// `http://localhost:11434` by default). Works with any multimodal model
/// the user has pulled — `llava:7b`, `llava:13b`, `bakllava`, etc.
///
/// Why this is the default:
///   * Zero cost per request
///   * Zero API-key plumbing
///   * Keeps frames off any cloud provider
///   * Respects agent workloads that want fully offline operation
public struct OllamaNarrationProvider: NarrationProvider {

    public let name = "ollama"
    public let defaultModel = "llava:7b"

    public init() {}

    /// Base URL resolution in priority order:
    ///   1. `config.endpoint` (per-request override)
    ///   2. `OLLAMA_HOST` environment variable
    ///   3. `http://localhost:11434`
    static func resolveBaseURL(override: URL?) -> URL {
        if let url = override { return url }
        if let envHost = ProcessInfo.processInfo.environment["OLLAMA_HOST"],
           !envHost.isEmpty {
            let normalized = envHost.hasPrefix("http") ? envHost : "http://\(envHost)"
            if let url = URL(string: normalized) { return url }
        }
        return URL(string: "http://localhost:11434")!
    }

    public func narrate(
        frames: [NarrationFrame],
        config: NarrationConfig
    ) async throws -> NarrationResult {
        guard !frames.isEmpty else { throw NarrationError.noFramesExtracted }

        let base = Self.resolveBaseURL(override: config.endpoint)
        let chatURL = base.appendingPathComponent("api/chat")

        // Build the Ollama /api/chat payload. Ollama accepts images as an
        // array of base64 strings on each message.
        let system = NarrationPrompt.systemInstruction(
            style: config.style,
            maxChapters: config.maxChapters,
            language: config.language
        )

        let frameLines = frames.map { f in
            "Frame at t=\(String(format: "%.2f", f.time))s"
        }
        let userText = """
        Here are \(frames.count) frames from a screen recording, in order:
        \(frameLines.joined(separator: "\n"))

        Generate the narration JSON now.
        """

        let imagesBase64 = frames.map { $0.imageData.base64EncodedString() }

        let payload: [String: Any] = [
            "model": config.model,
            "stream": false,
            "format": "json",
            "options": [
                "temperature": config.temperature
            ],
            "messages": [
                ["role": "system", "content": system],
                [
                    "role": "user",
                    "content": userText,
                    "images": imagesBase64
                ]
            ]
        ]

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.requestTimeout
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw NarrationError.providerRequestFailed("could not encode Ollama payload: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NarrationError.providerUnreachable(base.absoluteString)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NarrationError.providerRequestFailed("no HTTPURLResponse from Ollama")
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NarrationError.providerHTTPStatus(http.statusCode, tail(body))
        }

        // Ollama /api/chat response shape:
        //   { "message": { "content": "…" }, "done": true, … }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NarrationError.providerResponseMalformed("missing message.content in Ollama reply")
        }

        return try NarrationPrompt.parseResult(
            reply: content,
            provider: name,
            model: config.model
        )
    }

    // MARK: - Helpers

    /// Keep Ollama error bodies bounded so 500s with huge HTML don't fill logs.
    private func tail(_ s: String) -> String {
        s.count > 512 ? String(s.suffix(512)) : s
    }

    /// Ping the Ollama base URL to see if it's reachable. Used by the
    /// server to produce a helpful 503 error when the user hasn't started
    /// Ollama yet.
    public static func isReachable(base: URL? = nil) async -> Bool {
        let url = resolveBaseURL(override: base).appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
