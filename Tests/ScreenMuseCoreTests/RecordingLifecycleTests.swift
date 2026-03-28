import XCTest
@testable import ScreenMuseCore

/// Critical tests for recording lifecycle
/// Priority: CRITICAL - These test core functionality
final class RecordingLifecycleTests: XCTestCase {
    
    var manager: RecordingManager!
    var testConfig: RecordingConfig!
    
    override func setUp() async throws {
        try await super.setUp()
        manager = RecordingManager()
        testConfig = RecordingConfig(name: "test-recording")
    }
    
    override func tearDown() async throws {
        // Cleanup: stop any running recording
        if manager.isRecording {
            _ = try? await manager.stopRecording()
        }
        try await super.tearDown()
    }
    
    // MARK: - Start Recording Tests
    
    func testStartRecording() async throws {
        // Given: A fresh recording manager
        XCTAssertFalse(manager.isRecording, "Should not be recording initially")
        
        // When: Starting a recording
        try await manager.startRecording(config: testConfig)
        
        // Then: Manager should be in recording state
        XCTAssertTrue(manager.isRecording, "Should be recording after start")
        XCTAssertNotNil(manager.currentSession, "Should have a current session")
        XCTAssertEqual(manager.currentSession?.name, "test-recording")
    }
    
    func testStartRecordingWithCustomConfig() async throws {
        // Given: Custom configuration
        let config = RecordingConfig(
            name: "custom-test",
            audioSource: .systemAudio,
            region: .fullScreen
        )
        
        // When: Starting with custom config
        try await manager.startRecording(config: config)
        
        // Then: Config should be applied
        XCTAssertTrue(manager.isRecording)
        XCTAssertEqual(manager.currentSession?.config.audioSource, .systemAudio)
    }
    
    func testConcurrentStartPrevention() async throws {
        // Given: An already recording manager
        try await manager.startRecording(config: testConfig)
        XCTAssertTrue(manager.isRecording)
        
        // When: Attempting to start another recording
        // Then: Should throw an error
        do {
            try await manager.startRecording(config: RecordingConfig(name: "second"))
            XCTFail("Should throw error when starting concurrent recording")
        } catch RecordingError.alreadyRecording {
            // Expected error
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - Stop Recording Tests
    
    func testStopRecording() async throws {
        // Given: A running recording
        try await manager.startRecording(config: testConfig)
        XCTAssertTrue(manager.isRecording)
        
        // Wait a bit to record something
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        
        // When: Stopping the recording
        let videoURL = try await manager.stopRecording()
        
        // Then: Should have a video file and not be recording
        XCTAssertFalse(manager.isRecording, "Should not be recording after stop")
        XCTAssertNil(manager.currentSession, "Current session should be cleared")
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path), "Video file should exist")
        XCTAssertTrue(videoURL.pathExtension == "mp4", "Should be MP4 file")
    }
    
    func testStopWithoutStart() async throws {
        // Given: A manager that hasn't started recording
        XCTAssertFalse(manager.isRecording)
        
        // When: Attempting to stop
        // Then: Should throw an error
        do {
            _ = try await manager.stopRecording()
            XCTFail("Should throw error when stopping without starting")
        } catch RecordingError.notRecording {
            // Expected error
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - Pause/Resume Tests
    
    func testPauseRecording() async throws {
        // Given: A running recording
        try await manager.startRecording(config: testConfig)
        XCTAssertTrue(manager.isRecording)
        XCTAssertFalse(manager.isPaused)
        
        // When: Pausing
        try await manager.pauseRecording()
        
        // Then: Should be paused
        XCTAssertTrue(manager.isPaused, "Should be paused")
        XCTAssertTrue(manager.isRecording, "Should still be 'recording' (just paused)")
    }
    
    func testResumeRecording() async throws {
        // Given: A paused recording
        try await manager.startRecording(config: testConfig)
        try await manager.pauseRecording()
        XCTAssertTrue(manager.isPaused)
        
        // When: Resuming
        try await manager.resumeRecording()
        
        // Then: Should no longer be paused
        XCTAssertFalse(manager.isPaused, "Should not be paused after resume")
        XCTAssertTrue(manager.isRecording, "Should still be recording")
    }
    
    func testPauseResumeSequence() async throws {
        // Given: A running recording
        try await manager.startRecording(config: testConfig)
        
        // When: Multiple pause/resume cycles
        try await manager.pauseRecording()
        XCTAssertTrue(manager.isPaused)
        
        try await manager.resumeRecording()
        XCTAssertFalse(manager.isPaused)
        
        try await manager.pauseRecording()
        XCTAssertTrue(manager.isPaused)
        
        try await manager.resumeRecording()
        XCTAssertFalse(manager.isPaused)
        
        // Then: Should still be able to stop cleanly
        let videoURL = try await manager.stopRecording()
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path))
    }
    
    func testPauseWithoutRecording() async throws {
        // Given: No recording in progress
        XCTAssertFalse(manager.isRecording)
        
        // When: Attempting to pause
        // Then: Should throw an error
        do {
            try await manager.pauseRecording()
            XCTFail("Should throw error when pausing without recording")
        } catch RecordingError.notRecording {
            // Expected
        }
    }
    
    func testResumeWithoutPause() async throws {
        // Given: Recording but not paused
        try await manager.startRecording(config: testConfig)
        XCTAssertFalse(manager.isPaused)
        
        // When: Attempting to resume
        // Then: Should throw an error
        do {
            try await manager.resumeRecording()
            XCTFail("Should throw error when resuming without pause")
        } catch RecordingError.notPaused {
            // Expected
        }
    }
    
    // MARK: - State Management Tests
    
    func testMultipleStartStopCycles() async throws {
        // Test multiple recordings in sequence
        for i in 1...3 {
            // Start
            let config = RecordingConfig(name: "test-\(i)")
            try await manager.startRecording(config: config)
            XCTAssertTrue(manager.isRecording)
            
            // Wait
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            
            // Stop
            let url = try await manager.stopRecording()
            XCTAssertFalse(manager.isRecording)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
    
    func testRecordingDuration() async throws {
        // Given: A recording
        try await manager.startRecording(config: testConfig)
        
        // When: Recording for a known duration
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        
        // Then: Duration should be approximately 1s
        let elapsed = manager.elapsedTime
        XCTAssertGreaterThan(elapsed, 0.9, "Should have recorded at least 0.9s")
        XCTAssertLessThan(elapsed, 1.2, "Should not exceed 1.2s")
    }
    
    // MARK: - Cleanup Tests
    
    func testCleanupAfterStop() async throws {
        // Given: A recording that stopped
        try await manager.startRecording(config: testConfig)
        let url = try await manager.stopRecording()
        
        // When: Checking manager state
        // Then: Everything should be cleaned up
        XCTAssertNil(manager.currentSession)
        XCTAssertFalse(manager.isRecording)
        XCTAssertFalse(manager.isPaused)
        XCTAssertEqual(manager.elapsedTime, 0)
        
        // But file should still exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
