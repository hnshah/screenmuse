#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation

/// Tests for the Prometheus-style metrics registry: counter aggregation,
/// label canonicalization (so ephemeral IDs don't explode cardinality),
/// and exposition-format rendering.
final class MetricsRegistryTests: XCTestCase {

    // MARK: - Canonicalize

    func testCanonicalizeRewritesJobID() {
        XCTAssertEqual(MetricsRegistry.canonicalize("/job/abc123"), "/job/:id")
        XCTAssertEqual(MetricsRegistry.canonicalize("/job/"), "/job/:id")
    }

    func testCanonicalizeRewritesSessionID() {
        XCTAssertEqual(MetricsRegistry.canonicalize("/session/xyz456"), "/session/:id")
    }

    func testCanonicalizeLeavesStaticRoutesAlone() {
        XCTAssertEqual(MetricsRegistry.canonicalize("/start"), "/start")
        XCTAssertEqual(MetricsRegistry.canonicalize("/window/focus"), "/window/focus")
        XCTAssertEqual(MetricsRegistry.canonicalize("/system/running-apps"), "/system/running-apps")
    }

    // MARK: - escapeLabel

    func testEscapeLabelEscapesBackslashes() {
        XCTAssertEqual(MetricsRegistry.escapeLabel(#"a\b"#), #"a\\b"#)
    }

    func testEscapeLabelEscapesQuotes() {
        XCTAssertEqual(MetricsRegistry.escapeLabel(#"he said "hi""#), #"he said \"hi\""#)
    }

    func testEscapeLabelEscapesNewlines() {
        XCTAssertEqual(MetricsRegistry.escapeLabel("a\nb"), "a\\nb")
    }

    // MARK: - formatGauge

    func testFormatGaugeIntegersRenderAsInt() {
        XCTAssertEqual(MetricsRegistry.formatGauge(42.0), "42")
        XCTAssertEqual(MetricsRegistry.formatGauge(0), "0")
        XCTAssertEqual(MetricsRegistry.formatGauge(-7), "-7")
    }

    func testFormatGaugeFractionsRenderAsFloat() {
        XCTAssertEqual(MetricsRegistry.formatGauge(3.14), "3.140")
        XCTAssertEqual(MetricsRegistry.formatGauge(0.5), "0.500")
    }

    // MARK: - Record + snapshot + Prometheus rendering

    func testRecordAndSnapshotReflectsCounts() async {
        let registry = MetricsRegistry()
        await registry.recordRequest(method: "GET", route: "/status", status: 200)
        await registry.recordRequest(method: "GET", route: "/status", status: 200)
        await registry.recordRequest(method: "POST", route: "/start", status: 409)

        let snap = await registry.snapshot()
        XCTAssertEqual(snap.totalRequests, 3)
        let statusGet = snap.requestCounts[
            MetricsRegistry.RequestKey(method: "GET", route: "/status", status: 200)
        ]
        XCTAssertEqual(statusGet, 2)
        let startPost = snap.requestCounts[
            MetricsRegistry.RequestKey(method: "POST", route: "/start", status: 409)
        ]
        XCTAssertEqual(startPost, 1)
    }

    func testPrometheusTextIncludesInfoGauge() async {
        let registry = MetricsRegistry()
        let text = await registry.prometheusText(gauges: [:], version: "1.7.0")
        XCTAssertTrue(text.contains("screenmuse_info{version=\"1.7.0\"} 1"),
                      "info gauge must be emitted with the version label")
        XCTAssertTrue(text.contains("# TYPE screenmuse_info gauge"),
                      "TYPE line must precede each metric")
    }

    func testPrometheusTextIncludesCallerGauges() async {
        let registry = MetricsRegistry()
        let text = await registry.prometheusText(
            gauges: [
                "screenmuse_active_recordings": 1,
                "screenmuse_disk_free_bytes": 500_000_000
            ],
            version: "dev"
        )
        XCTAssertTrue(text.contains("screenmuse_active_recordings 1"))
        XCTAssertTrue(text.contains("screenmuse_disk_free_bytes 500000000"))
    }

    func testPrometheusTextRendersRequestCounter() async {
        let registry = MetricsRegistry()
        await registry.recordRequest(method: "POST", route: "/start", status: 200)
        let text = await registry.prometheusText(gauges: [:], version: "dev")
        XCTAssertTrue(text.contains(#"screenmuse_http_requests_total{method="POST",route="/start",status="200"} 1"#))
        XCTAssertTrue(text.contains("screenmuse_requests_total 1"),
                      "the aggregate counter must also be emitted")
    }

    func testPrometheusTextCanonicalizesJobIDs() async {
        let registry = MetricsRegistry()
        await registry.recordRequest(method: "GET", route: "/job/aaa111", status: 200)
        await registry.recordRequest(method: "GET", route: "/job/bbb222", status: 200)
        let text = await registry.prometheusText(gauges: [:], version: "dev")
        XCTAssertTrue(text.contains(#"route="/job/:id""#),
                      "per-job IDs must collapse to /job/:id to bound cardinality")
        XCTAssertFalse(text.contains("aaa111"))
        XCTAssertFalse(text.contains("bbb222"))
        XCTAssertTrue(text.contains("} 2"),
                      "canonicalized counter should show 2 (one per request)")
    }

    func testResetClearsCounters() async {
        let registry = MetricsRegistry()
        await registry.recordRequest(method: "GET", route: "/status", status: 200)
        await registry.recordRequestDuration(route: "/status", seconds: 0.05)
        await registry.reset()
        let snap = await registry.snapshot()
        XCTAssertEqual(snap.totalRequests, 0)
        XCTAssertTrue(snap.requestCounts.isEmpty)
        XCTAssertTrue(snap.histograms.isEmpty,
                      "reset must clear histogram state as well as counters")
    }

    // MARK: - Histograms

    func testHistogramIncrementsCumulativeBuckets() async {
        let registry = MetricsRegistry()
        // 3 fast requests: should land in every bucket >= 0.025
        await registry.recordRequestDuration(route: "/status", seconds: 0.02)
        await registry.recordRequestDuration(route: "/status", seconds: 0.03)
        await registry.recordRequestDuration(route: "/status", seconds: 0.04)
        let snap = await registry.snapshot()
        let h = snap.histograms["/status"]
        XCTAssertNotNil(h)
        XCTAssertEqual(h?.count, 3)
        // Bucket 0 (0.005) shouldn't have anything (all observations > 5ms)
        XCTAssertEqual(h?.bucketCounts[0], 0)
        // Bucket 1 (0.01) also empty
        XCTAssertEqual(h?.bucketCounts[1], 0)
        // Bucket 2 (0.025) catches the 0.02 observation only
        XCTAssertEqual(h?.bucketCounts[2], 1)
        // Bucket 3 (0.05) catches all three
        XCTAssertEqual(h?.bucketCounts[3], 3)
        // Bucket 4 (0.1) cumulative = still 3
        XCTAssertEqual(h?.bucketCounts[4], 3)
        // Sum should equal 0.02 + 0.03 + 0.04 = 0.09 (floating-point tolerant)
        XCTAssertEqual(h?.sum ?? 0, 0.09, accuracy: 0.001)
    }

    func testHistogramClampsNegativeDurations() async {
        let registry = MetricsRegistry()
        await registry.recordRequestDuration(route: "/status", seconds: -0.1)
        let snap = await registry.snapshot()
        let h = snap.histograms["/status"]
        XCTAssertEqual(h?.count, 1)
        // Negative clamps to 0 → lands in every bucket
        XCTAssertEqual(h?.bucketCounts[0], 1)
        XCTAssertEqual(h?.sum ?? -1, 0, accuracy: 0.0001)
    }

    func testHistogramCanonicalizesJobIDs() async {
        let registry = MetricsRegistry()
        await registry.recordRequestDuration(route: "/job/abc", seconds: 0.05)
        await registry.recordRequestDuration(route: "/job/xyz", seconds: 0.05)
        let snap = await registry.snapshot()
        XCTAssertEqual(snap.histograms.count, 1, "job histograms must collapse into /job/:id")
        XCTAssertEqual(snap.histograms["/job/:id"]?.count, 2)
    }

    func testPrometheusHistogramRendersBucketSumCount() async {
        let registry = MetricsRegistry()
        await registry.recordRequestDuration(route: "/status", seconds: 0.03)
        let text = await registry.prometheusText(gauges: [:], version: "dev")
        XCTAssertTrue(text.contains("# TYPE screenmuse_http_request_duration_seconds histogram"))
        XCTAssertTrue(text.contains(#"screenmuse_http_request_duration_seconds_bucket{route="/status",le="0.05"}"#))
        XCTAssertTrue(text.contains(#"screenmuse_http_request_duration_seconds_bucket{route="/status",le="+Inf"} 1"#))
        XCTAssertTrue(text.contains(#"screenmuse_http_request_duration_seconds_sum{route="/status"}"#))
        XCTAssertTrue(text.contains(#"screenmuse_http_request_duration_seconds_count{route="/status"} 1"#))
    }

    func testPrometheusHistogramSortedRouteOrder() async {
        let registry = MetricsRegistry()
        await registry.recordRequestDuration(route: "/zulu", seconds: 0.05)
        await registry.recordRequestDuration(route: "/alpha", seconds: 0.05)
        let text = await registry.prometheusText(gauges: [:], version: "dev")
        let alphaIdx = text.range(of: "route=\"/alpha\"")?.lowerBound
        let zuluIdx = text.range(of: "route=\"/zulu\"")?.lowerBound
        XCTAssertNotNil(alphaIdx)
        XCTAssertNotNil(zuluIdx)
        if let a = alphaIdx, let z = zuluIdx {
            XCTAssertLessThan(a, z)
        }
    }

    func testFormatBucketIntegerNoDecimals() {
        XCTAssertEqual(MetricsRegistry.formatBucket(1), "1")
        XCTAssertEqual(MetricsRegistry.formatBucket(10), "10")
    }

    func testFormatBucketTrimsTrailingZeros() {
        XCTAssertEqual(MetricsRegistry.formatBucket(0.5), "0.5")
        XCTAssertEqual(MetricsRegistry.formatBucket(0.025), "0.025")
        XCTAssertEqual(MetricsRegistry.formatBucket(0.1), "0.1")
    }

    func testDefaultBucketsCoverExpectedRange() {
        // Sanity check the declared shape so a future edit doesn't
        // silently drop buckets or introduce duplicates.
        XCTAssertEqual(MetricsRegistry.defaultBuckets.first, 0.005)
        XCTAssertEqual(MetricsRegistry.defaultBuckets.last, 30)
        XCTAssertEqual(MetricsRegistry.defaultBuckets.count, 12)
        // Must be strictly ascending
        let sorted = MetricsRegistry.defaultBuckets.sorted()
        XCTAssertEqual(sorted, MetricsRegistry.defaultBuckets)
    }

    func testPrometheusOutputIsSortedAndStable() async {
        let registry = MetricsRegistry()
        await registry.recordRequest(method: "POST", route: "/zulu", status: 200)
        await registry.recordRequest(method: "GET", route: "/alpha", status: 200)
        await registry.recordRequest(method: "POST", route: "/mike", status: 200)
        let text = await registry.prometheusText(gauges: [:], version: "dev")
        // Alpha should appear before Mike should appear before Zulu when sorted by route.
        guard let alphaIdx = text.range(of: "/alpha"),
              let mikeIdx = text.range(of: "/mike"),
              let zuluIdx = text.range(of: "/zulu") else {
            XCTFail("expected all three routes in output")
            return
        }
        XCTAssertLessThan(alphaIdx.lowerBound, mikeIdx.lowerBound)
        XCTAssertLessThan(mikeIdx.lowerBound, zuluIdx.lowerBound)
    }
}
#endif
