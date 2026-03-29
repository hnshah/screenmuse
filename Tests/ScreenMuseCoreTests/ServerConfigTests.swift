#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests for ScreenMuseServer configuration:
///   - Default port (7823)
///   - SCREENMUSE_PORT env var override
///   - Port stored in public `port` property after start()
///   - API key loading priorities
///
/// NOTE: These tests don't start the real NWListener. They verify config
/// parsing and state, not network connectivity (that's for integration tests).
final class ServerConfigTests: XCTestCase {

    // MARK: - Default Port

    @MainActor
    func testDefaultPort() {
        let server = ScreenMuseServer.shared
        // Before start() the stored port should be the compiled default
        // We can't easily test env-var override here without actually calling start(),
        // but we can verify the property exists and has a sane value.
        XCTAssertGreaterThan(server.port, 0)
        XCTAssertLessThanOrEqual(server.port, UInt16(65535))
    }

    // MARK: - API Key State

    @MainActor
    func testAPIKeyCanBeSetAndRead() {
        let server = ScreenMuseServer.shared
        let saved = server.apiKey
        defer { server.apiKey = saved }

        server.apiKey = "test-key-abc123"
        XCTAssertEqual(server.apiKey, "test-key-abc123")
    }

    @MainActor
    func testAPIKeyCanBeCleared() {
        let server = ScreenMuseServer.shared
        let saved = server.apiKey
        defer { server.apiKey = saved }

        server.apiKey = "some-key"
        server.apiKey = nil
        XCTAssertNil(server.apiKey)
    }

    // MARK: - Enriched Stop Response Format

    @MainActor
    func testEnrichedStopResponseContainsRequiredFields() {
        // Create a temp video file to satisfy the URL requirement
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-\(UUID().uuidString).mp4")
        // Write minimal bytes so attributesOfItem doesn't throw
        try? Data().write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let server = ScreenMuseServer.shared
        let resp = server.enrichedStopResponse(
            videoURL: tmpURL,
            elapsed: 12.5,
            sessionID: "test-session-id",
            chapters: [("Intro", 0.0), ("Demo", 5.0)],
            notes: [("Test note", 3.2)]
        )

        // Required top-level keys
        XCTAssertNotNil(resp["path"])
        XCTAssertNotNil(resp["video_path"])
        XCTAssertNotNil(resp["duration"])
        XCTAssertNotNil(resp["size"])
        XCTAssertNotNil(resp["size_mb"])
        XCTAssertNotNil(resp["session_id"])
        XCTAssertNotNil(resp["chapters"])
        XCTAssertNotNil(resp["notes"])

        // Verify values
        XCTAssertEqual(resp["path"] as? String, tmpURL.path)
        XCTAssertEqual(resp["video_path"] as? String, tmpURL.path)
        XCTAssertEqual(resp["duration"] as? TimeInterval, 12.5, accuracy: 0.001)
        XCTAssertEqual(resp["session_id"] as? String, "test-session-id")

        let chapters = resp["chapters"] as? [[String: Any]] ?? []
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0]["name"] as? String, "Intro")
        XCTAssertEqual(chapters[1]["name"] as? String, "Demo")

        let notes = resp["notes"] as? [[String: Any]] ?? []
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0]["text"] as? String, "Test note")
    }

    @MainActor
    func testEnrichedStopResponseNoDuration_KeyIsNamedDuration() {
        // Regression: the key must be "duration", NOT "elapsed" — TypeScript client depends on this
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-\(UUID().uuidString).mp4")
        try? Data().write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let server = ScreenMuseServer.shared
        let resp = server.enrichedStopResponse(
            videoURL: tmpURL,
            elapsed: 7.0,
            sessionID: nil,
            chapters: [],
            notes: []
        )

        XCTAssertNotNil(resp["duration"], "'duration' key missing — TypeScript client uses resp.duration")
        XCTAssertNil(resp["elapsed"], "'elapsed' key should not be present at top level of stop response")
    }

    @MainActor
    func testEnrichedStopResponseSizeMBRoundsTo2Decimals() {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-\(UUID().uuidString).mp4")
        // Write ~1.5 MB
        let data = Data(repeating: 0, count: 1_572_864)
        try? data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let server = ScreenMuseServer.shared
        let resp = server.enrichedStopResponse(videoURL: tmpURL, elapsed: 1.0, sessionID: nil, chapters: [], notes: [])
        let sizeMB = resp["size_mb"] as? Double ?? 0.0

        // Should be 1.50 (2 decimal places)
        XCTAssertEqual(sizeMB * 100, (sizeMB * 100).rounded(), accuracy: 0.001, "size_mb should be rounded to 2 decimal places")
        XCTAssertGreaterThan(sizeMB, 1.4)
        XCTAssertLessThan(sizeMB, 1.6)
    }

    // MARK: - structuredError

    @MainActor
    func testStructuredErrorPermissionDenied() {
        let server = ScreenMuseServer.shared
        let err = server.structuredError(RecordingError.permissionDenied("Screen Recording access denied"))
        XCTAssertEqual(err["code"] as? String, "PERMISSION_DENIED")
        XCTAssertNotNil(err["suggestion"])
    }

    @MainActor
    func testStructuredErrorNotRecording() {
        let server = ScreenMuseServer.shared
        let err = server.structuredError(RecordingError.notRecording)
        XCTAssertEqual(err["code"] as? String, "NOT_RECORDING")
    }

    @MainActor
    func testStructuredErrorWindowNotFound() {
        let server = ScreenMuseServer.shared
        let err = server.structuredError(RecordingError.windowNotFound("MyApp"))
        XCTAssertEqual(err["code"] as? String, "WINDOW_NOT_FOUND")
        XCTAssertEqual(err["query"] as? String, "MyApp")
    }
}
#endif
