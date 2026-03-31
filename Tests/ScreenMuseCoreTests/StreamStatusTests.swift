#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation
import Network

/// Tests for the SSE stream status endpoint (/stream/status).
///
/// These tests verify that the stream status response has the correct shape
/// without requiring an active SSE stream or Screen Recording permission.
/// They use the live HTTP integration test infrastructure (NWListener on port 7826).
final class StreamStatusTests: XCTestCase {

    static let testPort: UInt16 = 7826

    override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run {
            try ScreenMuseServer.shared.start(port: StreamStatusTests.testPort)
            ScreenMuseServer.shared.apiKey = nil
        }
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    override func tearDown() async throws {
        await MainActor.run {
            ScreenMuseServer.shared.stop()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await super.tearDown()
    }

    private func req(_ method: String, _ path: String) async throws -> (Int, [String: Any]) {
        let url = URL(string: "http://127.0.0.1:\(StreamStatusTests.testPort)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    // MARK: - Stream Status

    func testStreamStatusReturns200() async throws {
        let (status, _) = try await req("GET", "/stream/status")
        XCTAssertEqual(status, 200, "GET /stream/status should return 200")
    }

    func testStreamStatusHasActiveClientsField() async throws {
        let (_, json) = try await req("GET", "/stream/status")
        XCTAssertNotNil(json["active_clients"], "Response should include active_clients field")
    }

    func testStreamStatusActiveClientsIsNonNegative() async throws {
        let (_, json) = try await req("GET", "/stream/status")
        if let count = json["active_clients"] as? Int {
            XCTAssertGreaterThanOrEqual(count, 0, "active_clients should be non-negative")
        } else {
            XCTFail("active_clients should be an Int")
        }
    }

    func testStreamStatusHasTotalFramesSentField() async throws {
        let (_, json) = try await req("GET", "/stream/status")
        XCTAssertNotNil(json["total_frames_sent"], "Response should include total_frames_sent field")
    }

    func testStreamStatusTotalFramesIsNonNegative() async throws {
        let (_, json) = try await req("GET", "/stream/status")
        if let frames = json["total_frames_sent"] as? Int {
            XCTAssertGreaterThanOrEqual(frames, 0, "total_frames_sent should be non-negative")
        } else {
            XCTFail("total_frames_sent should be an Int")
        }
    }

    func testStreamStatusInitiallyHasZeroActiveClients() async throws {
        let (_, json) = try await req("GET", "/stream/status")
        // Without any active SSE connections, active_clients should be 0
        let count = json["active_clients"] as? Int ?? -1
        XCTAssertEqual(count, 0, "No active SSE clients on fresh server")
    }

    func testStreamStatusRequiresAuth() async throws {
        // Enable auth and verify /stream/status is protected
        await MainActor.run {
            ScreenMuseServer.shared.apiKey = "stream-test-key"
        }
        defer {
            Task { @MainActor in
                ScreenMuseServer.shared.apiKey = nil
            }
        }
        let (status, json) = try await req("GET", "/stream/status")
        XCTAssertEqual(status, 401, "GET /stream/status should require auth when key is set")
        XCTAssertNotNil(json["error"], "401 response should include error field")
    }
}
#endif
