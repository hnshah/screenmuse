import Foundation

// MARK: - Publisher Protocol

/// A destination that can receive a ScreenMuse recording artifact.
///
/// Three built-ins:
///   * `SlackPublisher`     — POSTs a notification message with metadata
///                             to an incoming-webhook URL. No file upload.
///   * `HTTPPutPublisher`   — PUTs the raw file bytes to a caller-supplied
///                             URL. Works with S3, Cloudflare R2, GCS, and
///                             any S3-compatible presigned URL — caller
///                             handles signing so we avoid SigV4 entirely.
///   * `WebhookPublisher`   — POSTs a JSON metadata envelope to an
///                             arbitrary URL (Zapier, n8n, custom
///                             HTTP endpoints).
///
/// Custom destinations can be plugged in by conforming to this protocol.
public protocol Publisher: Sendable {
    /// Wire name as it appears in the `destination` request field.
    var name: String { get }

    /// Upload or notify for a completed recording.
    /// The result describes what the destination returned so agents can
    /// navigate back to it (URL, remote path, etc.).
    func publish(video: URL, config: PublishConfig) async throws -> PublishResult
}

// MARK: - Shared types

/// Per-request configuration passed to every publisher.
public struct PublishConfig: Sendable {
    public let url: URL
    public let extraHeaders: [String: String]
    public let metadata: [String: String]
    public let timeout: TimeInterval
    public let apiToken: String?
    public let filename: String?

    public init(
        url: URL,
        extraHeaders: [String: String] = [:],
        metadata: [String: String] = [:],
        timeout: TimeInterval = 120,
        apiToken: String? = nil,
        filename: String? = nil
    ) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.metadata = metadata
        self.timeout = timeout
        self.apiToken = apiToken
        self.filename = filename
    }
}

/// What a publish attempt returned to the caller.
public struct PublishResult: Codable, Sendable {
    public let destination: String
    public let url: String?        // remote URL (if applicable)
    public let statusCode: Int     // HTTP status code
    public let responseBody: String?
    public let bytesSent: Int64

    enum CodingKeys: String, CodingKey {
        case destination
        case url
        case statusCode = "status_code"
        case responseBody = "response_body"
        case bytesSent = "bytes_sent"
    }

    public init(
        destination: String,
        url: String?,
        statusCode: Int,
        responseBody: String?,
        bytesSent: Int64
    ) {
        self.destination = destination
        self.url = url
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.bytesSent = bytesSent
    }
}

// MARK: - Errors

public enum PublishError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidDestination(String)
    case invalidURL(String)
    case missingURL
    case fileReadFailed(String)
    case httpFailed(Int, String)
    case networkFailure(String)
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p):         return "file not found: \(p)"
        case .invalidDestination(let d):   return "unknown destination '\(d)' — use 'slack', 'http_put', or 'webhook'"
        case .invalidURL(let u):           return "invalid URL: \(u)"
        case .missingURL:                  return "destination 'url' is required"
        case .fileReadFailed(let msg):     return "could not read file: \(msg)"
        case .httpFailed(let code, let body): return "destination returned HTTP \(code): \(body)"
        case .networkFailure(let msg):     return "network failure: \(msg)"
        case .unauthorized:                return "destination rejected the request (401/403). Check your API token."
        }
    }
}

// MARK: - Publisher factory

public enum PublisherRegistry {
    /// Resolve a publisher by wire name. Returns nil for unknown names so
    /// the HTTP handler can surface a structured 400.
    public static func publisher(named name: String) -> Publisher? {
        switch name.lowercased() {
        case "slack":     return SlackPublisher()
        case "http_put", "s3", "r2", "gcs":
            return HTTPPutPublisher()
        case "webhook":   return WebhookPublisher()
        default:          return nil
        }
    }

    /// Known destination names in preference order.
    public static let known = ["slack", "http_put", "webhook"]
}
