#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation
import Network

/// Resilience tests: concurrent /start spam, /metrics exposition format,
/// disk-space guard refusal path, and unknown-route floods. These
/// complement HTTPIntegrationTests by exercising failure modes instead
/// of happy paths.
///
/// NOTE: All tests use a dedicated port (7826) so they never collide
/// with a running production instance on 7823 or the port
/// HTTPIntegrationTests uses (7825).
final class ResilienceTests: XCTestCase {

    static let testPort: UInt16 = 7826

    override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run {
            try ScreenMuseServer.shared.start(port: Self.testPort)
            ScreenMuseServer.shared.apiKey = nil
            // Clear the metrics registry so assertions see a clean slate.
        }
        await MetricsRegistry.shared.reset()
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    override func tearDown() async throws {
        await MainActor.run {
            ScreenMuseServer.shared.stop()
            // Restore the disk-space guard to its default so other tests
            // that share the singleton are unaffected.
            ScreenMuseServer.shared.diskSpaceGuard = DiskSpaceGuard()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await super.tearDown()
    }

    // MARK: - HTTP helpers

    private func req(
        _ method: String,
        _ path: String,
        body: String? = nil
    ) async throws -> (Int, Data) {
        let url = URL(string: "http://127.0.0.1:\(Self.testPort)\(path)")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        if let b = body {
            request.httpBody = b.data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    // MARK: - /metrics Prometheus exposition

    func testMetricsEndpointReturnsPrometheusText() async throws {
        // Hit /status once so there's at least one request counted.
        _ = try await req("GET", "/status")
        // Small pause: the metrics recording fires into an actor from a
        // non-awaited Task in sendResponse, so the counter update can
        // lag the HTTP response by a few milliseconds.
        try await Task.sleep(nanoseconds: 50_000_000)

        let (status, data) = try await req("GET", "/metrics")
        XCTAssertEqual(status, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("# TYPE screenmuse_info gauge"),
                      "metrics must include the info gauge TYPE line")
        XCTAssertTrue(text.contains("screenmuse_info{version="),
                      "metrics must include an info gauge labeled with a version")
        XCTAssertTrue(text.contains("screenmuse_http_requests_total"),
                      "metrics must include the request counter")
        XCTAssertTrue(text.contains("screenmuse_uptime_seconds"),
                      "metrics must include uptime")
        XCTAssertTrue(text.contains("screenmuse_active_recordings"),
                      "metrics must include active-recordings gauge")
        XCTAssertTrue(text.contains("screenmuse_disk_free_bytes"),
                      "metrics must include disk-free gauge")
    }

    func testMetricsContentTypeIsPlainText() async throws {
        let url = URL(string: "http://127.0.0.1:\(Self.testPort)/metrics")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("text/plain"),
                      "metrics must be served as text/plain (Prometheus exposition format)")
    }

    // MARK: - Disk-space guard

    func testStartRejectsWhenDiskIsLow() async throws {
        // Swap in a guard with an absurd threshold so /start can never pass.
        await MainActor.run {
            ScreenMuseServer.shared.diskSpaceGuard = DiskSpaceGuard(minFreeBytes: Int64.max / 2)
        }
        defer {
            Task { await MainActor.run { ScreenMuseServer.shared.diskSpaceGuard = DiskSpaceGuard() } }
        }

        let (status, data) = try await req("POST", "/start", body: #"{"name":"test"}"#)
        XCTAssertEqual(status, 507, "low-disk refusal must return 507 Insufficient Storage")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        XCTAssertEqual(json["code"] as? String, "DISK_SPACE_LOW")
        XCTAssertNotNil(json["free_bytes"])
        XCTAssertNotNil(json["required_bytes"])
        XCTAssertNotNil(json["suggestion"])
    }

    func testRecordRejectsWhenDiskIsLow() async throws {
        await MainActor.run {
            ScreenMuseServer.shared.diskSpaceGuard = DiskSpaceGuard(minFreeBytes: Int64.max / 2)
        }
        defer {
            Task { await MainActor.run { ScreenMuseServer.shared.diskSpaceGuard = DiskSpaceGuard() } }
        }
        let (status, _) = try await req("POST", "/record", body: #"{"duration_seconds": 5}"#)
        XCTAssertEqual(status, 507)
    }

    func testBrowserRejectsWhenDiskIsLow() async throws {
        await MainActor.run {
            ScreenMuseServer.shared.diskSpaceGuard = DiskSpaceGuard(minFreeBytes: Int64.max / 2)
        }
        defer {
            Task { await MainActor.run { ScreenMuseServer.shared.diskSpaceGuard = DiskSpaceGuard() } }
        }
        let (status, _) = try await req("POST", "/browser",
                                        body: #"{"url":"https://example.com","duration_seconds":5}"#)
        XCTAssertEqual(status, 507,
                       "/browser must reject low-disk requests before touching the runner")
    }

    // MARK: - Route flood: 200× unknown routes do not crash or degrade

    func testUnknownRouteFloodReturnsAll404s() async throws {
        let iterations = 50
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let (status, _) = try await self.req("GET", "/flood-\(i)-\(UUID().uuidString)")
                    return status
                }
            }
            var statuses: [Int] = []
            for try await s in group { statuses.append(s) }
            XCTAssertEqual(statuses.count, iterations)
            XCTAssertTrue(statuses.allSatisfy { $0 == 404 },
                          "all unknown-route flood requests must return 404 cleanly")
        }
    }

    // MARK: - Metrics recording survives concurrent load

    func testMetricsCounterCapturesConcurrentRequests() async throws {
        await MetricsRegistry.shared.reset()
        let iterations = 20
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    _ = try await self.req("GET", "/status")
                }
            }
            try await group.waitForAll()
        }
        // Let any lagging metric-record Task settle.
        try await Task.sleep(nanoseconds: 200_000_000)
        let snap = await MetricsRegistry.shared.snapshot()
        // We expect at least `iterations` counted requests — plus the /status
        // request issued in testMetricsEndpointReturnsPrometheusText if it
        // somehow runs concurrently, but tests run sequentially so this is tight.
        XCTAssertGreaterThanOrEqual(
            snap.totalRequests,
            iterations,
            "metrics registry must capture every concurrent request"
        )
    }
}
#endif
