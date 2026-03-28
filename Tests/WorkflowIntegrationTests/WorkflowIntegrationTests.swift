import XCTest
@testable import ScreenMuseCore
import Foundation

/// End-to-end workflow integration tests
/// Priority: HIGH - Verify complete user journeys
final class WorkflowIntegrationTests: XCTestCase {
    
    var screenmuse: ScreenMuseAPI!
    
    override func setUp() async throws {
        try await super.setUp()
        screenmuse = try await ScreenMuseAPI(port: 7823)
        try await screenmuse.start()
    }
    
    override func tearDown() async throws {
        try await screenmuse.stop()
        try await super.tearDown()
    }
    
    // MARK: - Complete Recording Workflows
    
    func testCompleteRecordingWorkflow() async throws {
        // Given: User wants to record a demo
        
        // Step 1: Start recording
        let startResponse = try await apiCall(
            method: "POST",
            path: "/start",
            body: ["name": "complete-demo"]
        )
        
        XCTAssertEqual(startResponse.status, 200)
        let sessionId = startResponse.data["session_id"] as! String
        
        // Step 2: Record for 2 seconds
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Step 3: Add chapter markers
        _ = try await apiCall(
            method: "POST",
            path: "/chapter",
            body: ["name": "Step 1: Setup"]
        )
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        _ = try await apiCall(
            method: "POST",
            path: "/chapter",
            body: ["name": "Step 2: Execute"]
        )
        
        // Step 4: Mark highlight
        _ = try await apiCall(
            method: "POST",
            path: "/highlight"
        )
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Step 5: Stop recording
        let stopResponse = try await apiCall(
            method: "POST",
            path: "/stop"
        )
        
        XCTAssertEqual(stopResponse.status, 200)
        let videoPath = stopResponse.data["video_path"] as! String
        
        // Step 6: Export as GIF
        let exportResponse = try await apiCall(
            method: "POST",
            path: "/export",
            body: [
                "source": videoPath,
                "format": "gif",
                "fps": 10,
                "scale": 800
            ]
        )
        
        XCTAssertEqual(exportResponse.status, 200)
        let gifPath = exportResponse.data["output_path"] as! String
        
        // Then: Complete workflow succeeded
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gifPath))
        XCTAssertTrue(gifPath.hasSuffix(".gif"))
    }
    
    func testPiPRecordingWorkflow() async throws {
        // Given: User wants Picture-in-Picture recording
        
        // Step 1: Start main recording (full screen)
        let mainResponse = try await apiCall(
            method: "POST",
            path: "/start",
            body: [
                "name": "main-recording",
                "region": "fullScreen"
            ]
        )
        
        XCTAssertEqual(mainResponse.status, 200)
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Step 2: Start PiP recording (webcam or window)
        let pipResponse = try await apiCall(
            method: "POST",
            path: "/pip/start",
            body: [
                "source": "camera",
                "position": "bottom-right",
                "size": ["width": 320, "height": 240]
            ]
        )
        
        XCTAssertEqual(pipResponse.status, 200)
        
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Step 3: Stop both
        _ = try await apiCall(method: "POST", path: "/pip/stop")
        
        let stopResponse = try await apiCall(method: "POST", path: "/stop")
        
        // Then: Composite video with PiP created
        let videoPath = stopResponse.data["video_path"] as! String
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoPath))
    }
    
    func testConcatMultipleRecordingsWorkflow() async throws {
        // Given: User records multiple clips
        
        var clips: [String] = []
        
        // Record clip 1
        _ = try await apiCall(method: "POST", path: "/start", body: ["name": "clip1"])
        try await Task.sleep(nanoseconds: 500_000_000)
        var stopResponse = try await apiCall(method: "POST", path: "/stop")
        clips.append(stopResponse.data["video_path"] as! String)
        
        // Record clip 2
        _ = try await apiCall(method: "POST", path: "/start", body: ["name": "clip2"])
        try await Task.sleep(nanoseconds: 500_000_000)
        stopResponse = try await apiCall(method: "POST", path: "/stop")
        clips.append(stopResponse.data["video_path"] as! String)
        
        // Record clip 3
        _ = try await apiCall(method: "POST", path: "/start", body: ["name": "clip3"])
        try await Task.sleep(nanoseconds: 500_000_000)
        stopResponse = try await apiCall(method: "POST", path: "/stop")
        clips.append(stopResponse.data["video_path"] as! String)
        
        // When: Concatenating clips
        let concatResponse = try await apiCall(
            method: "POST",
            path: "/export/concat",
            body: [
                "clips": clips,
                "output": "concatenated.mp4"
            ]
        )
        
        // Then: Final video created
        XCTAssertEqual(concatResponse.status, 200)
        let outputPath = concatResponse.data["output_path"] as! String
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
    }
    
    func testTrimAndCropWorkflow() async throws {
        // Given: User records and wants to trim + crop
        
        // Step 1: Record
        _ = try await apiCall(method: "POST", path: "/start", body: ["name": "trim-crop-test"])
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3s recording
        let stopResponse = try await apiCall(method: "POST", path: "/stop")
        
        let originalVideo = stopResponse.data["video_path"] as! String
        
        // Step 2: Trim to middle 1 second
        let trimResponse = try await apiCall(
            method: "POST",
            path: "/export/trim",
            body: [
                "source": originalVideo,
                "start": 1.0,
                "end": 2.0
            ]
        )
        
        let trimmedVideo = trimResponse.data["output_path"] as! String
        
        // Step 3: Crop center region
        let cropResponse = try await apiCall(
            method: "POST",
            path: "/export/crop",
            body: [
                "source": trimmedVideo,
                "rect": ["x": 100, "y": 100, "width": 1200, "height": 800]
            ]
        )
        
        // Then: Final cropped video created
        XCTAssertEqual(cropResponse.status, 200)
        let finalVideo = cropResponse.data["output_path"] as! String
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalVideo))
    }
    
    func testSpeedRampWithIdleDetectionWorkflow() async throws {
        // Given: User records with idle periods
        
        // Start recording
        _ = try await apiCall(method: "POST", path: "/start", body: ["name": "speedramp-test"])
        
        // Active period
        for _ in 0..<10 {
            _ = try await apiCall(method: "POST", path: "/cursor/move", body: ["x": 100, "y": 100])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        // Idle period (no cursor movement)
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s idle
        
        // Active again
        for _ in 0..<10 {
            _ = try await apiCall(method: "POST", path: "/cursor/move", body: ["x": 200, "y": 200])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        // Stop recording
        let stopResponse = try await apiCall(method: "POST", path: "/stop")
        let videoPath = stopResponse.data["video_path"] as! String
        
        // When: Applying speed ramp
        let speedrampResponse = try await apiCall(
            method: "POST",
            path: "/export/speedramp",
            body: [
                "source": videoPath,
                "max_speed": 3.0,
                "idle_threshold": 1.0
            ]
        )
        
        // Then: Faster video created (idle parts sped up)
        XCTAssertEqual(speedrampResponse.status, 200)
        let outputPath = speedrampResponse.data["output_path"] as! String
        
        let originalDuration = stopResponse.data["duration"] as! Double
        let speedrampDuration = speedrampResponse.data["duration"] as! Double
        
        XCTAssertLessThan(speedrampDuration, originalDuration)
    }
    
    // MARK: - Window Management Workflows
    
    func testWindowFocusAndRecordWorkflow() async throws {
        // Given: User wants to record specific window
        
        // Step 1: Focus Safari
        let focusResponse = try await apiCall(
            method: "POST",
            path: "/window/focus",
            body: ["app": "Safari"]
        )
        
        XCTAssertEqual(focusResponse.status, 200)
        
        // Step 2: Position window
        _ = try await apiCall(
            method: "POST",
            path: "/window/position",
            body: [
                "app": "Safari",
                "bounds": ["x": 0, "y": 0, "width": 1920, "height": 1080]
            ]
        )
        
        // Step 3: Hide other windows
        _ = try await apiCall(
            method: "POST",
            path: "/window/hide-others",
            body: ["except": "Safari"]
        )
        
        // Step 4: Start recording window
        let startResponse = try await apiCall(
            method: "POST",
            path: "/start",
            body: [
                "name": "safari-demo",
                "region": "window",
                "window": "Safari"
            ]
        )
        
        XCTAssertEqual(startResponse.status, 200)
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Step 5: Stop
        let stopResponse = try await apiCall(method: "POST", path: "/stop")
        
        // Then: Recording created
        XCTAssertTrue(FileManager.default.fileExists(atPath: stopResponse.data["video_path"] as! String))
    }
    
    // MARK: - OCR Workflows
    
    func testOCRDuringRecordingWorkflow() async throws {
        // Given: Recording in progress
        _ = try await apiCall(method: "POST", path: "/start", body: ["name": "ocr-test"])
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // When: Running OCR on current screen
        let ocrResponse = try await apiCall(
            method: "POST",
            path: "/ocr/screen",
            body: [
                "region": ["x": 0, "y": 0, "width": 1920, "height": 1080],
                "mode": "fast"
            ]
        )
        
        XCTAssertEqual(ocrResponse.status, 200)
        let text = ocrResponse.data["text"] as! String
        
        // Add note with OCR result
        _ = try await apiCall(
            method: "POST",
            path: "/note",
            body: ["text": "OCR detected: \(text)"]
        )
        
        // Stop recording
        let stopResponse = try await apiCall(method: "POST", path: "/stop")
        
        // Then: Recording has OCR note
        let videoPath = stopResponse.data["video_path"] as! String
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoPath))
    }
    
    // MARK: - Webhook Workflows
    
    func testWebhookNotificationWorkflow() async throws {
        // Given: Webhook configured for recording complete
        let webhookURL = "https://webhook.site/test"
        
        // Start with webhook
        _ = try await apiCall(
            method: "POST",
            path: "/start",
            body: [
                "name": "webhook-test",
                "webhook": webhookURL
            ]
        )
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // When: Recording stops
        let stopResponse = try await apiCall(method: "POST", path: "/stop")
        
        // Then: Webhook should be called (verified externally)
        // For test, just verify response includes webhook info
        XCTAssertNotNil(stopResponse.data["webhook_sent"])
    }
    
    // MARK: - Batch Script Workflows
    
    func testBatchScriptExecutionWorkflow() async throws {
        // Given: User wants to run script during recording
        
        _ = try await apiCall(method: "POST", path: "/start", body: ["name": "script-test"])
        
        // When: Executing batch operations
        let script = [
            ["action": "chapter", "name": "Part 1"],
            ["action": "wait", "duration": 1.0],
            ["action": "highlight"],
            ["action": "wait", "duration": 1.0],
            ["action": "chapter", "name": "Part 2"],
            ["action": "note", "text": "Important moment"]
        ]
        
        let scriptResponse = try await apiCall(
            method: "POST",
            path: "/script/execute",
            body: ["commands": script]
        )
        
        XCTAssertEqual(scriptResponse.status, 200)
        
        // Stop
        let stopResponse = try await apiCall(method: "POST", path: "/stop")
        
        // Then: All timeline events created
        let timeline = stopResponse.data["timeline"] as! [String: Any]
        XCTAssertEqual((timeline["chapters"] as! [Any]).count, 2)
        XCTAssertEqual((timeline["highlights"] as! [Any]).count, 1)
        XCTAssertEqual((timeline["notes"] as! [Any]).count, 1)
    }
    
    // MARK: - Error Recovery Workflows
    
    func testErrorRecoveryWorkflow() async throws {
        // Given: Recording encounters error
        
        _ = try await apiCall(method: "POST", path: "/start", body: ["name": "error-test"])
        
        // Simulate: Disk full error (mocked)
        // When: Error occurs
        let errorResponse = try await apiCall(
            method: "POST",
            path: "/simulate-error",
            body: ["error": "disk_full"]
        )
        
        // Then: Recording auto-saves what it has
        XCTAssertEqual(errorResponse.status, 500)
        
        // Recovery: Get partial recording
        let statusResponse = try await apiCall(method: "GET", path: "/status")
        XCTAssertNotNil(statusResponse.data["partial_recording"])
    }
    
    // MARK: - Helper Methods
    
    private func apiCall(
        method: String,
        path: String,
        body: [String: Any]? = nil
    ) async throws -> (status: Int, data: [String: Any]) {
        let url = URL(string: "http://localhost:7823\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        
        return (statusCode, json)
    }
}
