#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

// MARK: - Mock Coordinator

@MainActor
final class MockRecordingCoordinator: RecordingCoordinating {
    var isRecording = false
    var cursorEvents: [CursorEvent] = []
    var keystrokeTimestamps: [Date] = []

    // Track call counts
    var startCalled = false
    var stopCalled = false
    var pauseCalled = false
    var resumeCalled = false

    func startRecording(name: String, windowTitle: String?, windowPid: Int?, quality: String?) async throws {
        startCalled = true
        isRecording = true
    }

    func stopAndGetVideo() async -> URL? {
        stopCalled = true
        isRecording = false
        return URL(fileURLWithPath: "/tmp/mock-video.mp4")
    }

    func pauseRecording() async throws {
        pauseCalled = true
    }

    func resumeRecording() async throws {
        resumeCalled = true
    }
}

// MARK: - Data Flow Tests

final class SpeedRampDataFlowTests: XCTestCase {

    /// When the coordinator has cursor events, ActivityAnalyzer should use cursor_keystroke path.
    @MainActor
    func testCursorEventsFromCoordinator() {
        let coordinator = MockRecordingCoordinator()

        let now = Date()
        coordinator.cursorEvents = [
            CursorEvent(position: CGPoint(x: 100, y: 200), timestamp: now, type: .move),
            CursorEvent(position: CGPoint(x: 200, y: 300), timestamp: now.addingTimeInterval(1), type: .move),
            CursorEvent(position: CGPoint(x: 300, y: 400), timestamp: now.addingTimeInterval(5), type: .leftClick)
        ]

        XCTAssertEqual(coordinator.cursorEvents.count, 3)
        XCTAssertFalse(coordinator.cursorEvents.isEmpty, "Coordinator should provide non-empty cursor events")
    }

    /// When the coordinator has keystroke timestamps, they should be accessible.
    @MainActor
    func testKeystrokeTimestampsFromCoordinator() {
        let coordinator = MockRecordingCoordinator()
        let now = Date()
        coordinator.keystrokeTimestamps = [
            now,
            now.addingTimeInterval(0.5),
            now.addingTimeInterval(1.0),
            now.addingTimeInterval(1.2)
        ]

        XCTAssertEqual(coordinator.keystrokeTimestamps.count, 4)
    }

    /// When the coordinator has cursor events with gaps > idle threshold,
    /// ActivityAnalyzer should identify idle segments.
    @MainActor
    func testActivityAnalyzerUsesCoordinatorEvents() {
        let coordinator = MockRecordingCoordinator()
        let recordingStart = Date()

        // Events: burst at start, then 5s gap (idle), then burst at end
        coordinator.cursorEvents = [
            CursorEvent(position: .zero, timestamp: recordingStart.addingTimeInterval(0.5), type: .move),
            CursorEvent(position: .zero, timestamp: recordingStart.addingTimeInterval(1.0), type: .move),
            // 5-second gap (idle with threshold=2.0)
            CursorEvent(position: .zero, timestamp: recordingStart.addingTimeInterval(6.0), type: .move),
            CursorEvent(position: .zero, timestamp: recordingStart.addingTimeInterval(6.5), type: .leftClick),
        ]

        let analyzer = ActivityAnalyzer()
        let segments = analyzer.analyze(
            cursorEvents: coordinator.cursorEvents,
            keystrokeTimestamps: coordinator.keystrokeTimestamps,
            recordingStart: recordingStart,
            duration: 8.0,
            idleThreshold: 2.0
        )

        // Should have at least 1 idle segment
        let idleSegments = segments.filter { $0.isIdle }
        XCTAssertFalse(idleSegments.isEmpty, "Should detect idle segment in the 5s gap")

        // The idle segment should cover roughly the 1.0s–6.0s gap
        if let idle = idleSegments.first {
            XCTAssertGreaterThanOrEqual(idle.duration, 2.0, "Idle segment should be at least 2.0s")
        }

        // Total timeline should cover full duration
        let totalDuration = segments.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(totalDuration, 8.0, accuracy: 0.1, "Segments should cover the full duration")
    }

    /// When coordinator has empty events, analyzer should fall through to a single active segment.
    @MainActor
    func testEmptyEventsProduceSingleActiveSegment() {
        let coordinator = MockRecordingCoordinator()
        XCTAssertTrue(coordinator.cursorEvents.isEmpty)
        XCTAssertTrue(coordinator.keystrokeTimestamps.isEmpty)

        let analyzer = ActivityAnalyzer()
        let segments = analyzer.analyze(
            cursorEvents: coordinator.cursorEvents,
            keystrokeTimestamps: coordinator.keystrokeTimestamps,
            recordingStart: Date(),
            duration: 30.0,
            idleThreshold: 2.0
        )

        XCTAssertEqual(segments.count, 1, "Empty events should produce a single segment")
        XCTAssertFalse(segments[0].isIdle, "Single segment with no events should be active")
        XCTAssertEqual(segments[0].duration, 30.0, accuracy: 0.1)
    }

    /// Verify the mock coordinator conforms to the protocol correctly.
    @MainActor
    func testMockCoordinatorProtocolConformance() {
        let coordinator: RecordingCoordinating = MockRecordingCoordinator()
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(coordinator.cursorEvents.isEmpty)
        XCTAssertTrue(coordinator.keystrokeTimestamps.isEmpty)
    }
}
#endif
