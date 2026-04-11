import Foundation

// MARK: - Narration Provider Protocol

/// A backend that turns frames + a prompt into structured narration.
///
/// Three built-in providers:
///   * `OllamaNarrationProvider` — local, default, zero-cost (requires Ollama)
///   * `ClaudeNarrationProvider` — Anthropic's Claude (vision)
///   * Custom providers can be plugged in by conforming to this protocol.
public protocol NarrationProvider: Sendable {
    /// Wire name exposed via `/narrate` response and `provider` request param.
    var name: String { get }

    /// Default model identifier used when the caller omits `model`.
    var defaultModel: String { get }

    /// Generate narration for the supplied frames.
    /// Must return `NarrationResult` with at least an empty array — never throw
    /// on "no narration generated", prefer an empty result.
    func narrate(frames: [NarrationFrame], config: NarrationConfig) async throws -> NarrationResult
}

// MARK: - Shared types

/// A single frame extracted from a recording, with its timestamp and image bytes.
public struct NarrationFrame: Sendable {
    public let time: Double    // seconds into the video
    public let imageData: Data // JPEG-encoded frame bytes
    public let width: Int
    public let height: Int

    public init(time: Double, imageData: Data, width: Int, height: Int) {
        self.time = time
        self.imageData = imageData
        self.width = width
        self.height = height
    }
}

/// Per-request configuration passed to a provider.
public struct NarrationConfig: Sendable {
    public let model: String
    public let style: String       // "technical", "casual", "tutorial"
    public let maxChapters: Int
    public let language: String    // ISO 639-1 code, default "en"
    public let apiKey: String?     // Claude/OpenAI API key, nil for local providers
    public let endpoint: URL?      // override endpoint (e.g. OLLAMA_HOST)
    public let temperature: Double // sampling temperature
    public let requestTimeout: TimeInterval

    public init(
        model: String,
        style: String = "technical",
        maxChapters: Int = 5,
        language: String = "en",
        apiKey: String? = nil,
        endpoint: URL? = nil,
        temperature: Double = 0.3,
        requestTimeout: TimeInterval = 120
    ) {
        self.model = model
        self.style = style
        self.maxChapters = maxChapters
        self.language = language
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.temperature = temperature
        self.requestTimeout = requestTimeout
    }
}

/// One line of narration aligned to a video timestamp.
public struct NarrationEntry: Codable, Sendable {
    public let time: Double
    public let text: String

    public init(time: Double, text: String) {
        self.time = time
        self.text = text
    }
}

/// Chapter suggestion — agents can accept these and POST /chapter for each.
public struct ChapterSuggestion: Codable, Sendable {
    public let time: Double
    public let name: String

    public init(time: Double, name: String) {
        self.time = time
        self.name = name
    }
}

/// Result returned by every provider.
public struct NarrationResult: Codable, Sendable {
    public let narration: [NarrationEntry]
    public let suggestedChapters: [ChapterSuggestion]
    public let provider: String
    public let model: String

    enum CodingKeys: String, CodingKey {
        case narration
        case suggestedChapters = "suggested_chapters"
        case provider, model
    }

    public init(
        narration: [NarrationEntry],
        suggestedChapters: [ChapterSuggestion],
        provider: String,
        model: String
    ) {
        self.narration = narration
        self.suggestedChapters = suggestedChapters
        self.provider = provider
        self.model = model
    }
}

// MARK: - Errors

public enum NarrationError: Error, LocalizedError {
    case noFramesExtracted
    case providerRequestFailed(String)
    case providerHTTPStatus(Int, String)
    case providerResponseMalformed(String)
    case providerUnreachable(String)
    case missingAPIKey(String)
    case unsupportedProvider(String)

    public var errorDescription: String? {
        switch self {
        case .noFramesExtracted:
            return "no frames could be extracted from the video"
        case .providerRequestFailed(let msg):
            return "narration request failed: \(msg)"
        case .providerHTTPStatus(let code, let body):
            return "narration provider returned HTTP \(code): \(body)"
        case .providerResponseMalformed(let msg):
            return "narration provider returned an unparseable response: \(msg)"
        case .providerUnreachable(let host):
            return "could not reach narration provider at \(host)"
        case .missingAPIKey(let provider):
            return "\(provider) requires an API key (set ANTHROPIC_API_KEY / OPENAI_API_KEY or pass `api_key` in the request)"
        case .unsupportedProvider(let name):
            return "unsupported narration provider '\(name)' — use 'ollama', 'anthropic', or register a custom provider"
        }
    }
}

// MARK: - Prompt

/// The strict JSON-schema prompt shared by every built-in provider.
///
/// Separated into a free struct so the Ollama, Claude, and OpenAI providers
/// can reuse the same text and stay consistent.  Keep the schema shape in
/// sync with `NarrationResult.Codable`.
public struct NarrationPrompt: Sendable {
    public static func systemInstruction(style: String, maxChapters: Int, language: String) -> String {
        return """
        You are analyzing frames from a screen recording to generate \
        timestamped narration. The frames are presented in timestamp order, \
        each labeled with its time in seconds.

        Respond ONLY with a single JSON object matching exactly this schema \
        (no markdown fences, no commentary):

        {
          "narration": [
            {"time": <number>, "text": "<one-sentence description>"}
          ],
          "suggested_chapters": [
            {"time": <number>, "name": "<2-4 word chapter label>"}
          ]
        }

        Rules:
          - Produce one narration entry per frame.
          - Produce at most \(maxChapters) chapter suggestions, only at \
            meaningful transitions.
          - Narration style: \(style).
          - Write all text in language: \(language).
          - Times must be numeric seconds (floats allowed).
          - Do not include any commentary outside the JSON.
        """
    }

    /// Parse the LLM's text reply into a `NarrationResult`. Robust to
    /// accidental markdown fences because agents sometimes wrap JSON in
    /// ```json ... ``` even when told not to.
    public static func parseResult(
        reply: String,
        provider: String,
        model: String
    ) throws -> NarrationResult {
        let stripped = stripFences(reply)
        guard let data = stripped.data(using: .utf8) else {
            throw NarrationError.providerResponseMalformed("could not encode reply as UTF-8")
        }
        do {
            let decoder = JSONDecoder()
            var partial = try decoder.decode(NarrationResult.self, from: data)
            // The decoder may succeed without populating provider/model
            // because they're not part of the LLM reply — fill them in.
            partial = NarrationResult(
                narration: partial.narration,
                suggestedChapters: partial.suggestedChapters,
                provider: provider,
                model: model
            )
            return partial
        } catch {
            // Fall back: try to find a top-level {...} substring.
            if let extracted = extractJSONObject(from: stripped),
               let d = extracted.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(NarrationResult.self, from: d) {
                return NarrationResult(
                    narration: parsed.narration,
                    suggestedChapters: parsed.suggestedChapters,
                    provider: provider,
                    model: model
                )
            }
            throw NarrationError.providerResponseMalformed(error.localizedDescription)
        }
    }

    /// Strip ```json fences that some models still emit.
    static func stripFences(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("```") {
            if let endOfFirstLine = out.firstIndex(of: "\n") {
                out = String(out[out.index(after: endOfFirstLine)...])
            }
            if out.hasSuffix("```") {
                out = String(out.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    /// Extract the first balanced {…} object out of an arbitrary string.
    /// Used as a fallback when the LLM wraps its JSON in prose.
    static func extractJSONObject(from s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var idx = start
        while idx < s.endIndex {
            let c = s[idx]
            if escape { escape = false; idx = s.index(after: idx); continue }
            if c == "\\" { escape = true; idx = s.index(after: idx); continue }
            if c == "\"" { inString.toggle() }
            if !inString {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(s[start...idx]) }
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }
}
