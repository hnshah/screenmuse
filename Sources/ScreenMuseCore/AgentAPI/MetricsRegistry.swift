import Foundation

/// Thread-safe counters and gauges for the `GET /metrics` endpoint.
///
/// Produces Prometheus text format (v0.0.4) so any standard scraper can
/// consume it. Intentionally minimal — we count HTTP requests by route
/// + method + status, track recording + job state as gauges, and emit
/// a `screenmuse_info` gauge with the build version so dashboards can
/// filter by release without needing a separate label.
///
/// Usage from the HTTP server:
///     MetricsRegistry.shared.recordRequest(method: "POST", route: "/start", status: 200)
///     let text = await MetricsRegistry.shared.prometheusText(gauges: [
///         "screenmuse_active_recordings": isRecording ? 1 : 0,
///         …
///     ])
public actor MetricsRegistry {

    public static let shared = MetricsRegistry()

    /// Key identifying a unique counter bucket. We strip path parameters
    /// from routes (e.g. `/job/abc123` → `/job/:id`) before recording so
    /// the cardinality doesn't explode with one counter per job id.
    public struct RequestKey: Hashable, Sendable {
        public let method: String
        public let route: String
        public let status: Int
    }

    // Counters
    private var requestCounts: [RequestKey: Int] = [:]
    private var totalRequests: Int = 0
    private var startTime: Date = Date()

    // MARK: - Record

    /// Record an HTTP response. Canonicalises `/job/foo` → `/job/:id`
    /// and `/session/foo` → `/session/:id` to keep label cardinality
    /// bounded.
    public func recordRequest(method: String, route: String, status: Int) {
        let key = RequestKey(
            method: method.uppercased(),
            route: Self.canonicalize(route),
            status: status
        )
        requestCounts[key, default: 0] += 1
        totalRequests += 1
    }

    /// Reset all counters — used by tests to isolate assertions.
    public func reset() {
        requestCounts.removeAll()
        totalRequests = 0
        startTime = Date()
    }

    // MARK: - Snapshot

    /// Observable snapshot of the registry without side effects.
    public func snapshot() -> Snapshot {
        Snapshot(
            totalRequests: totalRequests,
            requestCounts: requestCounts,
            uptime: Date().timeIntervalSince(startTime)
        )
    }

    public struct Snapshot: Sendable {
        public let totalRequests: Int
        public let requestCounts: [RequestKey: Int]
        public let uptime: TimeInterval
    }

    // MARK: - Prometheus rendering

    /// Render the registry + caller-supplied gauges as Prometheus text.
    /// Gauges are passed in from the caller so the HTTP handler can
    /// include live state (active recordings, job counts, disk free)
    /// that doesn't belong in this actor.
    public func prometheusText(
        gauges: [String: Double],
        version: String
    ) -> String {
        var lines: [String] = []

        // Info gauge — constant 1, labeled with the version. Dashboards
        // use `{job="screenmuse"} screenmuse_info{version="1.7"}` to
        // pin a build to a time window.
        lines.append("# HELP screenmuse_info Constant 1 gauge labeled with version.")
        lines.append("# TYPE screenmuse_info gauge")
        lines.append("screenmuse_info{version=\"\(Self.escapeLabel(version))\"} 1")

        // Request counter — one line per (method, route, status) tuple.
        if !requestCounts.isEmpty {
            lines.append("# HELP screenmuse_http_requests_total Total HTTP requests processed, by route and status.")
            lines.append("# TYPE screenmuse_http_requests_total counter")
            // Sort for deterministic output so tests can assert stably.
            let sorted = requestCounts.sorted { lhs, rhs in
                if lhs.key.route != rhs.key.route { return lhs.key.route < rhs.key.route }
                if lhs.key.method != rhs.key.method { return lhs.key.method < rhs.key.method }
                return lhs.key.status < rhs.key.status
            }
            for (key, count) in sorted {
                let labels = "method=\"\(Self.escapeLabel(key.method))\",route=\"\(Self.escapeLabel(key.route))\",status=\"\(key.status)\""
                lines.append("screenmuse_http_requests_total{\(labels)} \(count)")
            }
        }

        // Total request counter — useful for basic alerts without grouping.
        lines.append("# HELP screenmuse_requests_total Total HTTP requests processed.")
        lines.append("# TYPE screenmuse_requests_total counter")
        lines.append("screenmuse_requests_total \(totalRequests)")

        // Uptime gauge — useful for alerting on recent restarts.
        lines.append("# HELP screenmuse_uptime_seconds Seconds since the metrics registry was last reset.")
        lines.append("# TYPE screenmuse_uptime_seconds gauge")
        lines.append("screenmuse_uptime_seconds \(Int(Date().timeIntervalSince(startTime)))")

        // Caller-supplied gauges (active recordings, disk free, etc.).
        for (name, value) in gauges.sorted(by: { $0.key < $1.key }) {
            lines.append("# HELP \(name) ScreenMuse gauge")
            lines.append("# TYPE \(name) gauge")
            lines.append("\(name) \(Self.formatGauge(value))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    /// Canonicalize a path so ephemeral ids don't explode metric cardinality.
    /// E.g. `/job/abc123` → `/job/:id`, `/session/xyz-456` → `/session/:id`.
    /// Pure string manipulation so tests can cover every rewrite case.
    static func canonicalize(_ path: String) -> String {
        if path.hasPrefix("/job/") { return "/job/:id" }
        if path.hasPrefix("/session/") { return "/session/:id" }
        return path
    }

    /// Prometheus requires a limited set of characters inside label values —
    /// we escape `\`, `"` and newlines per the exposition-format spec.
    static func escapeLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Emit Int gauges as integers and fractional gauges with fixed precision.
    static func formatGauge(_ value: Double) -> String {
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.3f", value)
    }
}
