import XCTest
@testable import ScreenMuseCore
import Foundation

/// Tests for streaming functionality (SSE, frame streaming)
/// Priority: MEDIUM - Important for live preview and monitoring
final class StreamingTests: XCTestCase {
    
    var streamingServer: StreamingServer!
    let testPort: UInt16 = 7825
    
    override func setUp() async throws {
        try await super.setUp()
        streamingServer = try await StreamingServer(port: testPort)
    }
    
    override func tearDown() async throws {
        try await streamingServer.stop()
        try await super.tearDown()
    }
    
    // MARK: - Start/Stop Stream Tests
    
    func testStartSSEStream() async throws {
        // When: Starting SSE stream
        try await streamingServer.startStream(
            fps: 10,
            scale: 800
        )
        
        // Then: Stream should be active
        XCTAssertTrue(streamingServer.isStreaming)
        XCTAssertEqual(streamingServer.fps, 10)
        XCTAssertEqual(streamingServer.scale, 800)
    }
    
    func testStopSSEStream() async throws {
        // Given: Running stream
        try await streamingServer.startStream(fps: 10, scale: 800)
        XCTAssertTrue(streamingServer.isStreaming)
        
        // When: Stopping stream
        try await streamingServer.stopStream()
        
        // Then: Stream should be inactive
        XCTAssertFalse(streamingServer.isStreaming)
    }
    
    func testStartStreamTwice() async throws {
        // Given: Already streaming
        try await streamingServer.startStream(fps: 10, scale: 800)
        
        // When: Starting again
        do {
            try await streamingServer.startStream(fps: 15, scale: 1200)
            XCTFail("Should throw error when starting twice")
        } catch StreamingError.alreadyStreaming {
            // Expected
        }
    }
    
    func testStopWithoutStart() async throws {
        // Given: Not streaming
        XCTAssertFalse(streamingServer.isStreaming)
        
        // When: Attempting to stop
        do {
            try await streamingServer.stopStream()
            XCTFail("Should throw error when stopping without start")
        } catch StreamingError.notStreaming {
            // Expected
        }
    }
    
    // MARK: - Frame Rate Tests
    
    func testFrameRateControl() async throws {
        // Given: Different FPS values
        let fpsValues = [5, 10, 15, 30, 60]
        
        for fps in fpsValues {
            // When: Starting with specific FPS
            try await streamingServer.startStream(fps: fps, scale: 800)
            
            // Then: Should use specified FPS
            XCTAssertEqual(streamingServer.fps, fps)
            
            // Stop for next iteration
            try await streamingServer.stopStream()
        }
    }
    
    func testInvalidFrameRate() async throws {
        // When: Attempting invalid FPS
        do {
            try await streamingServer.startStream(fps: 0, scale: 800)
            XCTFail("Should throw error for invalid FPS")
        } catch StreamingError.invalidFrameRate {
            // Expected
        }
        
        do {
            try await streamingServer.startStream(fps: 200, scale: 800)
            XCTFail("Should throw error for too high FPS")
        } catch StreamingError.invalidFrameRate {
            // Expected
        }
    }
    
    func testFrameRatePerformance() async throws {
        // Given: High frame rate stream
        try await streamingServer.startStream(fps: 30, scale: 800)
        
        // When: Collecting frames for 1 second
        var frameCount = 0
        let startTime = Date()
        
        // Simulate frame collection
        while Date().timeIntervalSince(startTime) < 1.0 {
            if let _ = try await streamingServer.getNextFrame() {
                frameCount += 1
            }
            try await Task.sleep(nanoseconds: 33_000_000) // ~30fps
        }
        
        // Then: Should get approximately target FPS
        XCTAssertGreaterThan(frameCount, 20) // At least 20 frames
        XCTAssertLessThan(frameCount, 40)    // Not more than 40 frames
    }
    
    // MARK: - Scale Parameter Tests
    
    func testScaleParameter() async throws {
        // Given: Different scale values
        let scales = [400, 800, 1200, 1920]
        
        for scale in scales {
            // When: Starting with specific scale
            try await streamingServer.startStream(fps: 10, scale: scale)
            
            // Then: Should use specified scale
            XCTAssertEqual(streamingServer.scale, scale)
            
            // Stop for next iteration
            try await streamingServer.stopStream()
        }
    }
    
    func testInvalidScale() async throws {
        // When: Attempting invalid scale
        do {
            try await streamingServer.startStream(fps: 10, scale: 0)
            XCTFail("Should throw error for zero scale")
        } catch StreamingError.invalidScale {
            // Expected
        }
        
        do {
            try await streamingServer.startStream(fps: 10, scale: -100)
            XCTFail("Should throw error for negative scale")
        } catch StreamingError.invalidScale {
            // Expected
        }
    }
    
    func testScaleQuality() async throws {
        // Given: High-res stream
        try await streamingServer.startStream(fps: 10, scale: 1920)
        
        // When: Getting frame
        guard let frame = try await streamingServer.getNextFrame() else {
            XCTFail("Should get frame")
            return
        }
        
        // Then: Frame should match scale
        XCTAssertLessThanOrEqual(frame.width, 1920)
    }
    
    // MARK: - Client Connection Tests
    
    func testClientConnection() async throws {
        // Given: SSE endpoint
        try await streamingServer.startStream(fps: 10, scale: 800)
        
        // When: Client connects
        let url = URL(string: "http://localhost:\(testPort)/stream")!
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        
        // Create connection
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        
        // Then: Should accept connection
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
    }
    
    func testMultipleClients() async throws {
        // Given: Streaming server
        try await streamingServer.startStream(fps: 10, scale: 800)
        
        // When: Multiple clients connect
        let client1 = try await connectSSEClient(port: testPort)
        let client2 = try await connectSSEClient(port: testPort)
        let client3 = try await connectSSEClient(port: testPort)
        
        // Then: All should connect successfully
        XCTAssertEqual(client1.statusCode, 200)
        XCTAssertEqual(client2.statusCode, 200)
        XCTAssertEqual(client3.statusCode, 200)
        
        // Server should track connected clients
        XCTAssertEqual(streamingServer.connectedClients, 3)
    }
    
    func testClientDisconnection() async throws {
        // Given: Connected client
        try await streamingServer.startStream(fps: 10, scale: 800)
        let client = try await connectSSEClient(port: testPort)
        XCTAssertEqual(streamingServer.connectedClients, 1)
        
        // When: Client disconnects (simulated by closing connection)
        // In real implementation, this would be handled by connection closure
        try await streamingServer.disconnectClient(id: client.clientId)
        
        // Then: Client count should decrease
        XCTAssertEqual(streamingServer.connectedClients, 0)
    }
    
    // MARK: - Frame Delivery Tests
    
    func testFrameDelivery() async throws {
        // Given: Streaming with clients
        try await streamingServer.startStream(fps: 10, scale: 800)
        
        // When: Getting frames
        var receivedFrames: [StreamFrame] = []
        for _ in 0..<5 {
            if let frame = try await streamingServer.getNextFrame() {
                receivedFrames.append(frame)
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        
        // Then: Should receive frames
        XCTAssertGreaterThan(receivedFrames.count, 0)
        
        // Frames should have timestamps
        for frame in receivedFrames {
            XCTAssertGreaterThan(frame.timestamp, 0)
        }
    }
    
    func testFrameSequencing() async throws {
        // Given: Streaming
        try await streamingServer.startStream(fps: 30, scale: 800)
        
        // When: Collecting sequential frames
        var frames: [StreamFrame] = []
        for _ in 0..<10 {
            if let frame = try await streamingServer.getNextFrame() {
                frames.append(frame)
            }
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        
        // Then: Timestamps should be increasing
        for i in 1..<frames.count {
            XCTAssertGreaterThan(frames[i].timestamp, frames[i-1].timestamp)
        }
    }
    
    // MARK: - SSE Format Tests
    
    func testSSEEventFormat() async throws {
        // Given: Streaming frame
        try await streamingServer.startStream(fps: 10, scale: 800)
        
        guard let frame = try await streamingServer.getNextFrame() else {
            XCTFail("Should get frame")
            return
        }
        
        // When: Formatting as SSE event
        let sseEvent = streamingServer.formatAsSSE(frame: frame)
        
        // Then: Should match SSE format
        XCTAssertTrue(sseEvent.hasPrefix("data: "))
        XCTAssertTrue(sseEvent.hasSuffix("\n\n"))
        
        // Should contain frame data
        XCTAssertTrue(sseEvent.contains("timestamp"))
        XCTAssertTrue(sseEvent.contains("data"))
    }
    
    func testSSEHeartbeat() async throws {
        // Given: Streaming with idle period
        try await streamingServer.startStream(fps: 10, scale: 800)
        try await streamingServer.enableHeartbeat(interval: 1.0)
        
        // When: Waiting for heartbeat
        var receivedHeartbeat = false
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < 2.0 {
            if let event = try await streamingServer.getNextEvent() {
                if event.type == .heartbeat {
                    receivedHeartbeat = true
                    break
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        // Then: Should receive heartbeat
        XCTAssertTrue(receivedHeartbeat)
    }
    
    // MARK: - Error Handling Tests
    
    func testStreamingWithoutRecording() async throws {
        // Given: No recording in progress
        
        // When: Attempting to stream
        do {
            try await streamingServer.startStream(fps: 10, scale: 800)
            // May succeed depending on implementation (could stream desktop)
        } catch StreamingError.noActiveRecording {
            // Expected if streaming requires active recording
        }
    }
    
    func testNetworkError() async throws {
        // Given: Simulated network issue
        try await streamingServer.startStream(fps: 10, scale: 800)
        
        // When: Simulating network failure
        try await streamingServer.simulateNetworkError()
        
        // Then: Should handle gracefully
        let status = try await streamingServer.getStatus()
        XCTAssertTrue(status.hasError || !status.isStreaming)
    }
    
    // MARK: - Performance Tests
    
    func testStreamingPerformance() async throws {
        measure {
            let expectation = expectation(description: "Start stream")
            
            Task {
                try await streamingServer.startStream(fps: 30, scale: 1920)
                try await streamingServer.stopStream()
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 2.0)
        }
    }
    
    func testFrameProcessingPerformance() async throws {
        try await streamingServer.startStream(fps: 30, scale: 1920)
        
        measure {
            let expectation = expectation(description: "Process frame")
            
            Task {
                _ = try await streamingServer.getNextFrame()
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 0.1)
        }
    }
    
    // MARK: - Helper Methods
    
    private func connectSSEClient(port: UInt16) async throws -> (statusCode: Int, clientId: String) {
        let url = URL(string: "http://localhost:\(port)/stream")!
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        
        let (_, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let clientId = UUID().uuidString
        
        return (statusCode, clientId)
    }
}

// MARK: - Supporting Types

enum StreamingError: Error {
    case alreadyStreaming
    case notStreaming
    case invalidFrameRate
    case invalidScale
    case noActiveRecording
    case networkError
    case clientDisconnected
}

struct StreamFrame {
    let timestamp: Double
    let data: Data
    let width: Int
    let height: Int
    let sequenceNumber: Int
}

struct StreamStatus {
    let isStreaming: Bool
    let fps: Int
    let scale: Int
    let connectedClients: Int
    let framesDelivered: Int
    let hasError: Bool
}

enum SSEEventType {
    case frame
    case heartbeat
    case error
    case status
}

struct SSEEvent {
    let type: SSEEventType
    let data: String
    let id: String?
}
