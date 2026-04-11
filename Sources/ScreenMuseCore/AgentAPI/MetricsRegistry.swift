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

    // Histograms — stored per route (status is not a histogram label,
    // since we want "route X's p95 latency regardless of outcome").
    private var histograms: [String: HistogramState] = [:]

    /// Per-histogram state: cumulative bucket counts + sum + total count.
    /// Buckets are pre-shared across all histograms via `defaultBuckets`
    /// so the aggregation stays O(1) per observation.
    struct HistogramState {
        var bucketCounts: [Int]   // parallel to defaultBuckets
        var sum: Double
        var count: Int
    }

    /// Cumulative upper-bound buckets in seconds. Covers the range from
    /// 5ms (a /status request) up to 30s (an /export or /narrate job),
    /// with exponential spacing. `+Inf` is implicit — the `_count` line
    /// captures everything above 30s.
    ///
    /// Chosen so the buckets land on natural SLO targets agents use:
    ///   - p50  ~ 25ms (API handlers that do pure dispatch)
    ///   - p95  ~ 250ms (OCR, /frame, JSON-heavy system endpoints)
    ///   - p99  ~ 2.5s  (anything that touches ffprobe or AVFoundation)
    public static let defaultBuckets: [Double] = [
        0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30
    ]

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

    /// Record a request duration in seconds. Buckets are cumulative so
    /// `{le="0.5"}` includes every request <= 500ms. The histogram is
    /// keyed by route only (no status/method) so p95 per route stays
    /// stable across 4xx spam.
    public func recordRequestDuration(route: String, seconds: Double) {
        // Clamp negatives — a clock skew or a test recording `-0.5s`
        // would permanently skew the histogram.
        let duration = max(0, seconds)
        let canonical = Self.canonicalize(route)

        var state = histograms[canonical] ?? HistogramState(
            bucketCounts: Array(repeating: 0, count: Self.defaultBuckets.count),
            sum: 0,
            count: 0
        )
        // Increment every bucket whose upper bound >= duration (cumulative).
        for (i, upper) in Self.defaultBuckets.enumerated() where duration <= upper {
            state.bucketCounts[i] += 1
        }
        state.sum += duration
        state.count += 1
        histograms[canonical] = state
    }

    /// Reset all counters + histograms — used by tests to isolate assertions.
    public func reset() {
        requestCounts.removeAll()
        histograms.removeAll()
        totalRequests = 0
        startTime = Date()
    }

    // MARK: - Snapshot

    /// Observable snapshot of the registry without side effects.
    public func snapshot() -> Snapshot {
        Snapshot(
            totalRequests: totalRequests,
            requestCounts: requestCounts,
            histograms: histograms.mapValues { PublicHistogramState(
                bucketCounts: $0.bucketCounts,
                sum: $0.sum,
                count: $0.count
            ) },
            uptime: Date().timeIntervalSince(startTime)
        )
    }

    public struct Snapshot: Sendable {
        public let totalRequests: Int
        public let requestCounts: [RequestKey: Int]
        public let histograms: [String: PublicHistogramState]
        public let uptime: TimeInterval
    }

    /// Sendable-safe histogram view. The internal `HistogramState`
    /// struct can't cross actor boundaries directly without
    /// repeating the field list, so we mirror it here.
    public struct PublicHistogramState: Sendable {
        public let bucketCounts: [Int]
        public let sum: Double
        public let count: Int

        public init(bucketCounts: [Int], sum: Double, count: Int) {
            self.bucketCounts = bucketCounts
            self.sum = sum
            self.count = count
        }
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

        // Request-duration histogram. Emits three line families per
        // route: _bucket{le="<upper>"} for every bucket, _sum (total
        // seconds observed), and _count (total observations). Prometheus
        // derives p50/p95/p99 from these at query time via histogram_quantile().
        if !histograms.isEmpty {
            lines.append("# HELP screenmuse_http_request_duration_seconds Request duration in seconds, by route.")
            lines.append("# TYPE screenmuse_http_request_duration_seconds histogram")
            let sortedRoutes = histograms.keys.sorted()
            for route in sortedRoutes {
                guard let state = histograms[route] else { continue }
                let routeLabel = Self.escapeLabel(route)
                // Cumulative bucket lines
                for (i, upper) in Self.defaultBuckets.enumerated() {
                    let count = state.bucketCounts[i]
                    lines.append("screenmuse_http_request_duration_seconds_bucket{route=\"\(routeLabel)\",le=\"\(Self.formatBucket(upper))\"} \(count)")
                }
                // +Inf bucket must equal the total count per Prometheus spec
                lines.append("screenmuse_http_request_duration_seconds_bucket{route=\"\(routeLabel)\",le=\"+Inf\"} \(state.count)")
                // Sum + count
                lines.append("screenmuse_http_request_duration_seconds_sum{route=\"\(routeLabel)\"} \(Self.formatGauge(state.sum))")
                lines.append("screenmuse_http_request_duration_seconds_count{route=\"\(routeLabel)\"} \(state.count)")
            }
        }

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

    /// Format a histogram bucket upper bound for the `le="..."` label.
    /// Whole-second bounds render as integers; subsecond bounds render
    /// with up to 3 decimal digits without trailing zeros.
    static func formatBucket(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int64(value))
        }
        // Render with 3-digit precision and trim trailing zeros.
        var formatted = String(format: "%.3f", value)
        while formatted.hasSuffix("0") { formatted.removeLast() }
        if formatted.hasSuffix(".") { formatted.removeLast() }
        return formatted
    }
}
