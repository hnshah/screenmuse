import Foundation

/// Generic HTTP PUT uploader — streams a file's bytes to a caller-supplied URL.
///
/// Designed for presigned upload URLs from S3, Cloudflare R2, Google Cloud
/// Storage, and any S3-compatible object store. The caller generates the
/// presigned URL on their side (language of their choice), and we do the
/// actual PUT. This keeps AWS SigV4 signing out of the Swift binary
/// entirely — it's a large dependency surface and every object store has
/// its own dialect of canonical-request-generation.
///
/// Also works for any HTTP endpoint that accepts a raw PUT: Uppy Companion,
/// FastAPI `UploadFile`, custom webhook endpoints, etc.
public struct HTTPPutPublisher: Publisher {

    public let name = "http_put"

    public init() {}

    public func publish(video: URL, config: PublishConfig) async throws -> PublishResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: video.path) else {
            throw PublishError.fileNotFound(video.path)
        }

        let fileSize = (try? fm.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0

        // Build the PUT request. We rely on URLSession.upload(for:fromFile:)
        // to stream the file body off disk — no need to instantiate our
        // own InputStream (which isn't Sendable and would trip Swift 6
        // strict concurrency when captured across the upload await).
        var request = URLRequest(url: config.url)
        request.httpMethod = "PUT"
        request.timeoutInterval = max(config.timeout, Double(fileSize / 1_000_000))
        request.setValue(Self.contentType(for: video), forHTTPHeaderField: "Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        for (k, v) in config.extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(
                for: request,
                fromFile: video
            )
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
            bytesSent: Int64(fileSize)
        )
    }

    /// Derive a reasonable Content-Type from the file extension. Falls
    /// back to application/octet-stream.
    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4":  return "video/mp4"
        case "mov":  return "video/quicktime"
        case "webm": return "video/webm"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "json": return "application/json"
        default:     return "application/octet-stream"
        }
    }

    static func tail(_ s: String) -> String {
        s.count > 512 ? String(s.suffix(512)) : s
    }
}
