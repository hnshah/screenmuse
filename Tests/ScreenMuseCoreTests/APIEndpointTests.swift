import XCTest
@testable import ScreenMuseCore
import Foundation

/// Tests for HTTP API endpoints
/// Priority: CRITICAL - Agent control surface
final class APIEndpointTests: XCTestCase {
    
    var server: ScreenMuseServer!
    let testPort: UInt16 = 7824 // Different from production port (7823)
    
    override func setUp() async throws {
        try await super.setUp()
        server = try await ScreenMuseServer(port: testPort)
        try await server.start()
    }
    
    override func tearDown() async throws {
        try await server.stop()
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func sendRequest(
        method: String,
        path: String,
        body: String? = nil
    ) async throws -> (statusCode: Int, data: Data) {
        let url = URL(string: "http://localhost:\(testPort)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        if let body = body {
            request.httpBody = body.data(using: .utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (statusCode, data)
    }
    
    // MARK: - Start Endpoint Tests
    
    func testStartEndpoint() async throws {
        // Given: Valid start request
        let json = #"{"name": "test-recording"}"#
        
        // When: Sending POST /start
        let response = try await sendRequest(
            method: "POST",
            path: "/start",
            body: json
        )
        
        // Then: Should return 200 with recording status
        XCTAssertEqual(response.statusCode, 200)
        
        let data = try JSONDecoder().decode(StartResponse.self, from: response.data)
        XCTAssertEqual(data.status, "recording")
        XCTAssertEqual(data.name, "test-recording")
        XCTAssertNotNil(data.session_id)
    }
    
    func testStartWithCustomConfig() async throws {
        // Given: Start request with audio source
        let json = #"{"name": "audio-test", "audio_source": "system"}"#
        
        // When: Starting with config
        let response = try await sendRequest(
            method: "POST",
            path: "/start",
            body: json
        )
        
        // Then: Config should be applied
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(StartResponse.self, from: response.data)
        XCTAssertEqual(data.audio_source, "system")
    }
    
    func testStartWhileRecording() async throws {
        // Given: Already recording
        _ = try await sendRequest(
            method: "POST",
            path: "/start",
            body: #"{"name": "first"}"#
        )
        
        // When: Attempting second start
        let response = try await sendRequest(
            method: "POST",
            path: "/start",
            body: #"{"name": "second"}"#
        )
        
        // Then: Should return error
        XCTAssertEqual(response.statusCode, 409) // Conflict
        let data = try JSONDecoder().decode(ErrorResponse.self, from: response.data)
        XCTAssertTrue(data.error.contains("already recording"))
    }
    
    // MARK: - Stop Endpoint Tests
    
    func testStopEndpoint() async throws {
        // Given: A recording in progress
        _ = try await sendRequest(
            method: "POST",
            path: "/start",
            body: #"{"name": "test"}"#
        )
        
        // Wait a bit
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // When: Stopping
        let response = try await sendRequest(
            method: "POST",
            path: "/stop"
        )
        
        // Then: Should return video path
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(StopResponse.self, from: response.data)
        XCTAssertTrue(data.video_path.hasSuffix(".mp4"))
        XCTAssertGreaterThan(data.duration, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.video_path))
    }
    
    func testStopWithoutRecording() async throws {
        // Given: Not recording
        
        // When: Attempting to stop
        let response = try await sendRequest(
            method: "POST",
            path: "/stop"
        )
        
        // Then: Should return error
        XCTAssertEqual(response.statusCode, 400) // Bad Request
        let data = try JSONDecoder().decode(ErrorResponse.self, from: response.data)
        XCTAssertTrue(data.error.contains("not recording"))
    }
    
    // MARK: - Status Endpoint Tests
    
    func testStatusWhileRecording() async throws {
        // Given: Recording in progress
        _ = try await sendRequest(
            method: "POST",
            path: "/start",
            body: #"{"name": "test"}"#
        )
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // When: Checking status
        let response = try await sendRequest(
            method: "GET",
            path: "/status"
        )
        
        // Then: Should show recording state
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(StatusResponse.self, from: response.data)
        XCTAssertTrue(data.is_recording)
        XCTAssertFalse(data.is_paused)
        XCTAssertGreaterThan(data.elapsed_time, 0)
        XCTAssertEqual(data.name, "test")
    }
    
    func testStatusWhenIdle() async throws {
        // Given: No recording
        
        // When: Checking status
        let response = try await sendRequest(
            method: "GET",
            path: "/status"
        )
        
        // Then: Should show idle state
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(StatusResponse.self, from: response.data)
        XCTAssertFalse(data.is_recording)
        XCTAssertFalse(data.is_paused)
        XCTAssertEqual(data.elapsed_time, 0)
    }
    
    // MARK: - Chapter Endpoint Tests
    
    func testAddChapter() async throws {
        // Given: Recording in progress
        _ = try await sendRequest(
            method: "POST",
            path: "/start",
            body: #"{"name": "test"}"#
        )
        
        // When: Adding chapter
        let response = try await sendRequest(
            method: "POST",
            path: "/chapter",
            body: #"{"name": "Step 1"}"#
        )
        
        // Then: Should succeed
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(ChapterResponse.self, from: response.data)
        XCTAssertEqual(data.chapter_name, "Step 1")
        XCTAssertGreaterThan(data.timestamp, 0)
    }
    
    func testAddChapterWithoutRecording() async throws {
        // Given: Not recording
        
        // When: Adding chapter
        let response = try await sendRequest(
            method: "POST",
            path: "/chapter",
            body: #"{"name": "Step 1"}"#
        )
        
        // Then: Should return error
        XCTAssertEqual(response.statusCode, 400)
    }
    
    // MARK: - Highlight Endpoint Tests
    
    func testMarkHighlight() async throws {
        // Given: Recording
        _ = try await sendRequest(
            method: "POST",
            path: "/start",
            body: #"{"name": "test"}"#
        )
        
        // When: Marking highlight
        let response = try await sendRequest(
            method: "POST",
            path: "/highlight"
        )
        
        // Then: Should succeed
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(HighlightResponse.self, from: response.data)
        XCTAssertTrue(data.highlight_set)
    }
    
    // MARK: - Error Handling Tests
    
    func testInvalidRoute() async throws {
        // When: Accessing non-existent endpoint
        let response = try await sendRequest(
            method: "GET",
            path: "/nonexistent"
        )
        
        // Then: Should return 404
        XCTAssertEqual(response.statusCode, 404)
    }
    
    func testMalformedJSON() async throws {
        // When: Sending invalid JSON
        let response = try await sendRequest(
            method: "POST",
            path: "/start",
            body: "not-valid-json"
        )
        
        // Then: Should return 400
        XCTAssertEqual(response.statusCode, 400)
        let data = try JSONDecoder().decode(ErrorResponse.self, from: response.data)
        XCTAssertTrue(data.error.contains("invalid JSON") || data.error.contains("parse"))
    }
    
    func testMissingRequiredField() async throws {
        // When: Sending incomplete JSON
        let response = try await sendRequest(
            method: "POST",
            path: "/start",
            body: "{}" // Missing "name" field
        )
        
        // Then: Should return 400
        XCTAssertEqual(response.statusCode, 400)
        let data = try JSONDecoder().decode(ErrorResponse.self, from: response.data)
        XCTAssertTrue(data.error.contains("name"))
    }
    
    func testWrongHTTPMethod() async throws {
        // When: Using wrong HTTP method
        let response = try await sendRequest(
            method: "GET",
            path: "/start" // Should be POST
        )
        
        // Then: Should return 405 Method Not Allowed
        XCTAssertEqual(response.statusCode, 405)
    }
    
    // MARK: - Pause/Resume Endpoint Tests
    
    func testPauseEndpoint() async throws {
        // Given: Recording
        _ = try await sendRequest(
            method: "POST",
            path: "/start",
            body: #"{"name": "test"}"#
        )
        
        // When: Pausing
        let response = try await sendRequest(
            method: "POST",
            path: "/pause"
        )
        
        // Then: Should succeed
        XCTAssertEqual(response.statusCode, 200)
        
        // Verify status
        let statusResponse = try await sendRequest(
            method: "GET",
            path: "/status"
        )
        let status = try JSONDecoder().decode(StatusResponse.self, from: statusResponse.data)
        XCTAssertTrue(status.is_paused)
    }
    
    func testResumeEndpoint() async throws {
        // Given: Paused recording
        _ = try await sendRequest(
            method: "POST",
            path: "/start",
            body: #"{"name": "test"}"#
        )
        _ = try await sendRequest(method: "POST", path: "/pause")
        
        // When: Resuming
        let response = try await sendRequest(
            method: "POST",
            path: "/resume"
        )
        
        // Then: Should succeed
        XCTAssertEqual(response.statusCode, 200)
        
        // Verify status
        let statusResponse = try await sendRequest(
            method: "GET",
            path: "/status"
        )
        let status = try JSONDecoder().decode(StatusResponse.self, from: statusResponse.data)
        XCTAssertFalse(status.is_paused)
    }
    
    // MARK: - Version Endpoint Tests
    
    func testVersionEndpoint() async throws {
        // When: Getting version
        let response = try await sendRequest(
            method: "GET",
            path: "/version"
        )
        
        // Then: Should return version info
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(VersionResponse.self, from: response.data)
        XCTAssertFalse(data.version.isEmpty)
        XCTAssertGreaterThan(data.endpoints.count, 0)
    }
    
    // MARK: - OpenAPI Spec Tests
    
    func testOpenAPIEndpoint() async throws {
        // When: Getting OpenAPI spec
        let response = try await sendRequest(
            method: "GET",
            path: "/openapi"
        )
        
        // Then: Should return valid OpenAPI JSON
        XCTAssertEqual(response.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["openapi"] as? String, "3.0.0")
        XCTAssertNotNil(json?["paths"])
    }
}

// MARK: - Response Models

struct StartResponse: Codable {
    let status: String
    let name: String
    let session_id: String
    let audio_source: String?
}

struct StopResponse: Codable {
    let status: String
    let video_path: String
    let duration: Double
    let size_bytes: Int
}

struct StatusResponse: Codable {
    let is_recording: Bool
    let is_paused: Bool
    let elapsed_time: Double
    let name: String?
    let chapters: Int
    let highlights: Int
}

struct ChapterResponse: Codable {
    let chapter_name: String
    let timestamp: Double
}

struct HighlightResponse: Codable {
    let highlight_set: Bool
}

struct ErrorResponse: Codable {
    let error: String
}

struct VersionResponse: Codable {
    let version: String
    let endpoints: [String]
}
