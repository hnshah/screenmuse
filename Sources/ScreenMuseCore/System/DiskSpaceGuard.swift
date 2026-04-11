import Foundation

/// Pre-flight check that refuses to start a recording / job when the
/// target volume is running out of space. Split into a pure-logic struct
/// so the thresholds and error shape are trivially unit-testable without
/// mocking FileManager.
///
/// Rationale: a recording that fills the disk mid-write produces a
/// corrupted MP4, crashes the write pipeline, and can cascade into
/// other macOS processes failing to save state. Cheaper to refuse up
/// front with a structured error and a clear suggestion.
public struct DiskSpaceGuard: Sendable {

    /// Minimum free disk space required before a recording / job can start.
    /// Defaults to 2 GB — enough for ~5 minutes of high-quality capture plus
    /// some headroom for effects compositing and export.
    public static let defaultMinFreeBytes: Int64 = 2 * 1024 * 1024 * 1024  // 2 GB

    /// Configured minimum. Callers construct their own guard instance so
    /// tests and the HTTP server can set different thresholds.
    public let minFreeBytes: Int64

    public init(minFreeBytes: Int64 = Self.defaultMinFreeBytes) {
        self.minFreeBytes = minFreeBytes
    }

    // MARK: - Inspection (pure-logic)

    /// Decision returned by `evaluate(...)`.
    public enum Decision: Equatable {
        /// There's enough headroom — proceed with the operation.
        case ok
        /// Disk space is below `minFreeBytes`. Includes the measured free
        /// bytes and the required minimum so callers can render a
        /// useful structured error.
        case insufficient(free: Int64, required: Int64)
        /// Free space could not be determined. We default to `.ok` in
        /// production callers so that a filesystem we can't probe doesn't
        /// bring the server to a halt — but expose the fact separately
        /// so test suites can assert they hit this branch.
        case unknown
    }

    /// Pure decision given a free-bytes measurement. Separate from the
    /// stat() call so tests can exercise every branch without touching
    /// the filesystem.
    public func evaluate(freeBytes: Int64?) -> Decision {
        guard let free = freeBytes else { return .unknown }
        if free < minFreeBytes {
            return .insufficient(free: free, required: minFreeBytes)
        }
        return .ok
    }

    // MARK: - Filesystem integration

    /// Measure free bytes on the volume containing the given directory.
    /// Uses `.volumeAvailableCapacityForImportantUsageKey` which respects
    /// reclaimable caches and purgeable storage — the number users see
    /// in Finder's "Available" column, not the raw df output.
    public static func freeBytes(atDirectory url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return important
            }
            if let raw = values.volumeAvailableCapacity {
                return Int64(raw)
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Convenience helper — measures the target directory and returns a
    /// structured error dict if the guard would fail, or `nil` if the
    /// operation can proceed. Integrates with the existing `sendResponse`
    /// error shape used throughout ScreenMuseServer.
    ///
    /// When `freeBytes` can't be determined, we return `nil` (allow the
    /// operation) so transient filesystem hiccups don't lock up the API.
    /// The logger records this case so it's still observable.
    public func checkOrErrorBody(forDirectory url: URL) -> [String: Any]? {
        let free = Self.freeBytes(atDirectory: url)
        let decision = evaluate(freeBytes: free)
        switch decision {
        case .ok, .unknown:
            return nil
        case .insufficient(let actual, let required):
            return [
                "error": "insufficient free disk space: \(Self.formatBytes(actual)) available, \(Self.formatBytes(required)) required",
                "code": "DISK_SPACE_LOW",
                "free_bytes": actual,
                "required_bytes": required,
                "directory": url.path,
                "suggestion": "Free up space, or lower `min_free_disk_gb` in ~/.screenmuse.json"
            ]
        }
    }

    /// Pretty-print a byte count in the biggest fitting unit.
    /// Extracted for readability in error messages + the `/metrics` gauge.
    public static func formatBytes(_ bytes: Int64) -> String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let d = Double(bytes)
        if d >= gb { return String(format: "%.2f GB", d / gb) }
        if d >= mb { return String(format: "%.1f MB", d / mb) }
        if d >= kb { return String(format: "%.0f KB", d / kb) }
        return "\(bytes) B"
    }
}
