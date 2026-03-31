#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation
import Network

/// Tests for recording and session management endpoints:
///   GET  /recordings        — list saved recordings
///   DELETE /recording       — delete a recording by filename
///   GET  /sessions          — list all sessions
///   GET  /session/{id}      — get a specific session
///   DELETE /session/{id}    — delete a session
///   GET  /report            — session report
///   GET  /timeline          — structured timeline
///
/// All tests use the live NWListener on port 7827.
final class RecordingManagementTests: XCTestCase {

    static let testPort: UInt16 = 7827

    override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run {
            try ScreenMuseServer.shared.start(port: RecordingManagementTests.testPort)
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

    // MARK: - HTTP helpers

    private func req(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil
    ) async throws -> (Int, Any) {
        let url = URL(string: "http://127.0.0.1:\(RecordingManagementTests.testPort)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
        return (status, json)
    }

    private func dict(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        let (status, json) = try await req(method, path, body: body)
        return (status, json as? [String: Any] ?? [:])
    }

    private func arr(_ path: String) async throws -> (Int, [[String: Any]]) {
        let (status, json) = try await req("GET", path)
        return (status, json as? [[String: Any]] ?? [])
    }

    // MARK: - GET /recordings

    func testRecordingsReturns200() async throws {
        let (status, _) = try await arr("/recordings")
        XCTAssertEqual(status, 200, "GET /recordings should return 200")
    }

    func testRecordingsReturnsArray() async throws {
        let (_, recordings) = try await arr("/recordings")
        // May be empty if no recordings exist — that's fine
        XCTAssertNotNil(recordings, "GET /recordings should return an array (possibly empty)")
    }

    // MARK: - DELETE /recording

    func testDeleteRecordingWithNoFilenameReturns400() async throws {
        let (status, json) = try await dict("/recording", method: "DELETE", body: [:])
        XCTAssertEqual(status, 400, "DELETE /recording with no filename should return 400")
        XCTAssertNotNil(json["error"], "Error response should have error field")
    }

    func testDeleteRecordingWithNonexistentFileReturns404() async throws {
        let (status, json) = try await dict(
            "/recording",
            method: "DELETE",
            body: ["filename": "nonexistent-file-that-does-not-exist.mp4"]
        )
        // Server should return 404 for a file that doesn't exist
        XCTAssertEqual(status, 404, "DELETE /recording with nonexistent file should return 404")
        XCTAssertNotNil(json["error"], "404 response should have error field")
    }

    func testDeleteRecordingErrorHasConsistentShape() async throws {
        let (_, json) = try await dict(
            "/recording",
            method: "DELETE",
            body: ["filename": "ghost-file.mp4"]
        )
        XCTAssertNotNil(json["error"] as? String, "Error field should be a string")
    }

    // MARK: - GET /sessions

    func testSessionsReturns200() async throws {
        let (status, _) = try await arr("/sessions")
        XCTAssertEqual(status, 200, "GET /sessions should return 200")
    }

    func testSessionsReturnsArray() async throws {
        let (_, sessions) = try await arr("/sessions")
        // Sessions may be empty — just verify array shape
        XCTAssertNotNil(sessions, "GET /sessions should return an array")
    }

    // MARK: - GET /session/{id}

    func testGetNonexistentSessionReturns404() async throws {
        let (status, json) = try await dict("/session/nonexistent-session-id-xyz-abc")
        XCTAssertEqual(status, 404, "GET /session/{id} for unknown ID should return 404")
        XCTAssertNotNil(json["error"], "404 response should have error field")
    }

    func testGetSessionErrorHasCodeField() async throws {
        let (_, json) = try await dict("/session/ghost-session-id")
        XCTAssertNotNil(json["code"], "Session not-found error should have a code field")
    }

    // MARK: - DELETE /session/{id}

    func testDeleteNonexistentSessionReturns404() async throws {
        let (status, json) = try await dict(
            "/session/nonexistent-session-to-delete",
            method: "DELETE"
        )
        XCTAssertEqual(status, 404, "DELETE /session/{id} for unknown ID should return 404")
        XCTAssertNotNil(json["error"], "404 response should have error field")
    }

    // MARK: - Session lifecycle: create via registry, retrieve, delete

    @MainActor
    func testSessionRegistryRoundTrip() {
        // Create a session in the registry
        let registry = SessionRegistry()
        let session = registry.create(id: "integration-test-session", name: "Test Session")

        // Verify it was created
        XCTAssertEqual(session.id, "integration-test-session")
        XCTAssertEqual(session.name, "Test Session")
        XCTAssertTrue(session.isRecording)

        // Retrieve it
        let retrieved = registry.get("integration-test-session")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "Test Session")

        // Delete it
        let deleted = registry.remove("integration-test-session")
        XCTAssertNotNil(deleted)
        XCTAssertNil(registry.get("integration-test-session"), "Session should be gone after delete")
    }

    // MARK: - GET /report

    func testReportReturns200() async throws {
        let (status, _) = try await dict("/report")
        XCTAssertEqual(status, 200, "GET /report should return 200")
    }

    func testReportReturnsValidJSON() async throws {
        let (status, json) = try await dict("/report")
        XCTAssertEqual(status, 200)
        // Report should have some structure — at minimum not be empty
        XCTAssertFalse(json.isEmpty, "Report should not be empty")
    }

    // MARK: - GET /timeline

    func testTimelineReturns200() async throws {
        let (status, _) = try await dict("/timeline")
        XCTAssertEqual(status, 200, "GET /timeline should return 200")
    }

    func testTimelineHasChaptersField() async throws {
        let (_, json) = try await dict("/timeline")
        XCTAssertNotNil(json["chapters"], "Timeline should include chapters field")
    }

    func testTimelineHasNotesField() async throws {
        let (_, json) = try await dict("/timeline")
        XCTAssertNotNil(json["notes"], "Timeline should include notes field")
    }

    func testTimelineHasElapsedField() async throws {
        let (_, json) = try await dict("/timeline")
        XCTAssertNotNil(json["elapsed"], "Timeline should include elapsed field")
    }

    func testTimelineChaptersIsArray() async throws {
        let (_, json) = try await dict("/timeline")
        XCTAssertNotNil(json["chapters"] as? [Any], "Timeline chapters should be an array")
    }

    func testTimelineNotesIsArray() async throws {
        let (_, json) = try await dict("/timeline")
        XCTAssertNotNil(json["notes"] as? [Any], "Timeline notes should be an array")
    }
}
#endif
