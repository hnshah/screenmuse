import XCTest
@testable import ScreenMuseCore
import Foundation

/// Integration tests for Playwright npm package
/// Priority: HIGH - Key integration for automated browser recording
final class PlaywrightIntegrationTests: XCTestCase {
    
    var screenmuse: ScreenMuseAPI!
    var testPort: UInt16 = 7823
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Start ScreenMuse API server for integration tests
        screenmuse = try await ScreenMuseAPI(port: testPort)
        try await screenmuse.start()
    }
    
    override func tearDown() async throws {
        try await screenmuse.stop()
        try await super.tearDown()
    }
    
    // MARK: - Playwright Package Integration Tests
    
    func testPlaywrightPackageCanConnect() async throws {
        // Given: ScreenMuse running
        XCTAssertTrue(screenmuse.isRunning)
        
        // When: Playwright package connects
        let response = try await sendHTTPRequest(
            method: "GET",
            path: "/status"
        )
        
        // Then: Connection successful
        XCTAssertEqual(response.statusCode, 200)
    }
    
    func testPlaywrightCanStartRecording() async throws {
        // Given: Playwright test scenario
        let requestBody = """
        {
            "name": "playwright-test",
            "config": {
                "focus_window": "Safari",
                "position": {"x": 0, "y": 0, "width": 1920, "height": 1080},
                "hide_others": true
            }
        }
        """
        
        // When: Playwright starts recording via API
        let response = try await sendHTTPRequest(
            method: "POST",
            path: "/start",
            body: requestBody
        )
        
        // Then: Recording starts successfully
        XCTAssertEqual(response.statusCode, 200)
        
        let data = try JSONDecoder().decode(StartResponse.self, from: response.data)
        XCTAssertEqual(data.status, "recording")
        XCTAssertEqual(data.name, "playwright-test")
    }
    
    func testPlaywrightWindowDetection() async throws {
        // Given: Browser launched via Playwright
        // Simulate: Launch browser window
        try await simulateBrowserLaunch(browser: "Chrome")
        
        // When: Detecting browser window
        let response = try await sendHTTPRequest(
            method: "GET",
            path: "/window/list"
        )
        
        // Then: Should find Chrome window
        XCTAssertEqual(response.statusCode, 200)
        
        let data = try JSONDecoder().decode(WindowListResponse.self, from: response.data)
        XCTAssertTrue(data.windows.contains { $0.appName == "Chrome" })
    }
    
    func testPlaywrightTestFixture() async throws {
        // Given: Playwright test with automatic recording
        // Simulate: test.beforeEach() → screenmuse.start()
        
        let beforeEachRequest = """
        {
            "name": "test-fixture-recording",
            "auto_stop_on_error": true
        }
        """
        
        // When: Test starts
        let startResponse = try await sendHTTPRequest(
            method: "POST",
            path: "/start",
            body: beforeEachRequest
        )
        
        XCTAssertEqual(startResponse.statusCode, 200)
        
        // Simulate: test runs
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        
        // Simulate: test.afterEach() → screenmuse.stop()
        let stopResponse = try await sendHTTPRequest(
            method: "POST",
            path: "/stop"
        )
        
        // Then: Recording saved automatically
        XCTAssertEqual(stopResponse.statusCode, 200)
        
        let stopData = try JSONDecoder().decode(StopResponse.self, from: stopResponse.data)
        XCTAssertTrue(stopData.video_path.contains("test-fixture-recording"))
    }
    
    func testCleanRecordingSetup() async throws {
        // Given: Playwright clean recording workflow
        
        // Step 1: Focus target window
        let focusRequest = """
        {
            "app": "Safari",
            "bundleID": "com.apple.Safari"
        }
        """
        
        let focusResponse = try await sendHTTPRequest(
            method: "POST",
            path: "/window/focus",
            body: focusRequest
        )
        XCTAssertEqual(focusResponse.statusCode, 200)
        
        // Step 2: Position window
        let positionRequest = """
        {
            "app": "Safari",
            "bounds": {"x": 0, "y": 0, "width": 1920, "height": 1080}
        }
        """
        
        let positionResponse = try await sendHTTPRequest(
            method: "POST",
            path: "/window/position",
            body: positionRequest
        )
        XCTAssertEqual(positionResponse.statusCode, 200)
        
        // Step 3: Hide other windows
        let hideRequest = """
        {
            "except": "Safari"
        }
        """
        
        let hideResponse = try await sendHTTPRequest(
            method: "POST",
            path: "/window/hide-others",
            body: hideRequest
        )
        XCTAssertEqual(hideResponse.statusCode, 200)
        
        // Step 4: Start recording
        let startResponse = try await sendHTTPRequest(
            method: "POST",
            path: "/start",
            body: """
            {"name": "clean-recording"}
            """
        )
        XCTAssertEqual(startResponse.statusCode, 200)
        
        // Then: Clean recording environment established
        let statusResponse = try await sendHTTPRequest(
            method: "GET",
            path: "/status"
        )
        let statusData = try JSONDecoder().decode(StatusResponse.self, from: statusResponse.data)
        XCTAssertTrue(statusData.is_recording)
    }
    
    func testGIFExportFromPlaywright() async throws {
        // Given: Recorded video from Playwright test
        
        // Start recording
        _ = try await sendHTTPRequest(
            method: "POST",
            path: "/start",
            body: """
            {"name": "playwright-gif-test"}
            """
        )
        
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s recording
        
        // Stop recording
        let stopResponse = try await sendHTTPRequest(
            method: "POST",
            path: "/stop"
        )
        
        let stopData = try JSONDecoder().decode(StopResponse.self, from: stopResponse.data)
        
        // When: Exporting as GIF (Playwright option: gif: true)
        let exportRequest = """
        {
            "source": "\(stopData.video_path)",
            "format": "gif",
            "fps": 10,
            "scale": 800
        }
        """
        
        let exportResponse = try await sendHTTPRequest(
            method: "POST",
            path: "/export",
            body: exportRequest
        )
        
        // Then: GIF created
        XCTAssertEqual(exportResponse.statusCode, 200)
        
        let exportData = try JSONDecoder().decode(ExportResponse.self, from: exportResponse.data)
        XCTAssertTrue(exportData.output_path.hasSuffix(".gif"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportData.output_path))
    }
    
    // MARK: - Playwright Error Scenarios
    
    func testPlaywrightHandlesRecordingFailure() async throws {
        // Given: Recording already in progress
        _ = try await sendHTTPRequest(
            method: "POST",
            path: "/start",
            body: """
            {"name": "first-recording"}
            """
        )
        
        // When: Playwright tries to start another recording
        let secondStart = try await sendHTTPRequest(
            method: "POST",
            path: "/start",
            body: """
            {"name": "second-recording"}
            """
        )
        
        // Then: Clear error message returned
        XCTAssertEqual(secondStart.statusCode, 409) // Conflict
        
        let errorData = try JSONDecoder().decode(ErrorResponse.self, from: secondStart.data)
        XCTAssertTrue(errorData.error.contains("already recording"))
    }
    
    func testPlaywrightVideoOnTestFailure() async throws {
        // Given: Playwright test that will fail
        
        // Start recording
        _ = try await sendHTTPRequest(
            method: "POST",
            path: "/start",
            body: """
            {
                "name": "failing-test",
                "save_on_failure": true
            }
            """
        )
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // When: Test fails (simulated)
        let stopOnFailure = try await sendHTTPRequest(
            method: "POST",
            path: "/stop",
            body: """
            {
                "reason": "test_failure",
                "keep_video": true
            }
            """
        )
        
        // Then: Video saved for debugging
        XCTAssertEqual(stopOnFailure.statusCode, 200)
        
        let stopData = try JSONDecoder().decode(StopResponse.self, from: stopOnFailure.data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stopData.video_path))
    }
    
    // MARK: - Playwright-Specific Features
    
    func testPlaywrightChapterMarkers() async throws {
        // Given: Recording with Playwright test steps
        _ = try await sendHTTPRequest(
            method: "POST",
            path: "/start",
            body: """
            {"name": "chapter-test"}
            """
        )
        
        // When: Marking chapters for each test step
        let chapters = [
            "Navigate to homepage",
            "Click login button",
            "Enter credentials",
            "Submit form"
        ]
        
        for (index, chapterName) in chapters.enumerated() {
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2s between steps
            
            let response = try await sendHTTPRequest(
                method: "POST",
                path: "/chapter",
                body: """
                {"name": "\(chapterName)"}
                """
            )
            
            XCTAssertEqual(response.statusCode, 200)
        }
        
        // Then: All chapters recorded
        let statusResponse = try await sendHTTPRequest(
            method: "GET",
            path: "/status"
        )
        
        let statusData = try JSONDecoder().decode(StatusResponse.self, from: statusResponse.data)
        XCTAssertEqual(statusData.chapters, chapters.count)
    }
    
    func testPlaywrightMultipleBrowsers() async throws {
        // Given: Playwright launches multiple browsers
        try await simulateBrowserLaunch(browser: "Chrome")
        try await simulateBrowserLaunch(browser: "Firefox")
        try await simulateBrowserLaunch(browser: "Safari")
        
        // When: Listing windows
        let response = try await sendHTTPRequest(
            method: "GET",
            path: "/window/list"
        )
        
        // Then: All browsers detected
        XCTAssertEqual(response.statusCode, 200)
        
        let data = try JSONDecoder().decode(WindowListResponse.self, from: response.data)
        XCTAssertTrue(data.windows.contains { $0.appName.contains("Chrome") })
        XCTAssertTrue(data.windows.contains { $0.appName.contains("Firefox") })
        XCTAssertTrue(data.windows.contains { $0.appName.contains("Safari") })
    }
    
    // MARK: - Helper Methods
    
    private func sendHTTPRequest(
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
    
    private func simulateBrowserLaunch(browser: String) async throws {
        // Simulate browser launch (would actually use NSWorkspace in real implementation)
        // For tests, just verify the API can handle it
    }
}

// MARK: - Response Models

struct StartResponse: Codable {
    let status: String
    let name: String
    let session_id: String
}

struct StopResponse: Codable {
    let status: String
    let video_path: String
    let duration: Double
}

struct StatusResponse: Codable {
    let is_recording: Bool
    let is_paused: Bool
    let elapsed_time: Double
    let name: String?
    let chapters: Int
    let highlights: Int
}

struct WindowListResponse: Codable {
    let windows: [WindowInfo]
    
    struct WindowInfo: Codable {
        let appName: String
        let bundleID: String
        let windowTitle: String
    }
}

struct ExportResponse: Codable {
    let status: String
    let output_path: String
    let format: String
}

struct ErrorResponse: Codable {
    let error: String
    let code: String?
}
