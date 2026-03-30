import Foundation

// MARK: - Testable pure-logic helpers extracted from ScreenMuseServer

/// Checks whether a request should be allowed through API key auth.
///
/// Returns `true` if the request is authorized (or auth is not required).
/// Returns `false` if the request should be rejected with 401.
///
/// Rules:
///   - If no API key is configured (`required` is nil), all requests pass.
///   - OPTIONS requests are exempt (CORS preflight).
///   - /health requests are exempt (liveness probes).
///   - Otherwise, the provided key must exactly match the required key.
public func checkAPIKey(required: String?, provided: String?, method: String, path: String) -> Bool {
    guard let required = required, method != "OPTIONS", path != "/health" else { return true }
    return (provided ?? "") == required
}

/// Validates that a capture region falls within the given display bounds.
///
/// Returns `nil` if the region is valid, or an error string describing the problem.
///
/// Note: CGRect normalises negative width/height values (e.g. CGRect with height -100 is stored
/// as origin.y -= 100, height = 100). We therefore validate the raw `size` struct rather than
/// the computed `width`/`height` properties, which would hide negative inputs.
public func validateRegion(_ rect: CGRect, against displayBounds: CGRect) -> String? {
    if rect.size.width <= 0 || rect.size.height <= 0 {
        return "width and height must be greater than 0"
    }
    if rect.origin.x < displayBounds.minX || rect.origin.y < displayBounds.minY ||
       rect.maxX > displayBounds.maxX || rect.maxY > displayBounds.maxY {
        return "Region falls outside display bounds"
    }
    return nil
}

/// Validates the duration parameter for the POST /record convenience endpoint.
///
/// Returns `nil` if the duration is valid, or an error string describing the problem.
public func validateRecordDuration(_ duration: Double?) -> String? {
    guard let d = duration, d > 0, d <= 3600 else {
        return "duration_seconds is required and must be between 1 and 3600"
    }
    return nil
}

/// Parse Content-Length from raw HTTP request headers.
///
/// Returns the integer value of the Content-Length header, or `nil` if not found or malformed.
/// Matching is case-insensitive per HTTP spec.
/// Returns `nil` for negative values — a negative Content-Length is invalid per RFC 7230.
public func parseContentLength(from raw: String) -> Int? {
    let lines = raw.components(separatedBy: "\r\n")
    for line in lines {
        if line.isEmpty { break }
        let lower = line.lowercased()
        if lower.hasPrefix("content-length:") {
            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            guard let parsed = Int(value), parsed >= 0 else { return nil }
            return parsed
        }
    }
    return nil
}
