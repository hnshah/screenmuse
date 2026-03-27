#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class ActivityAnalyzerTests: XCTestCase {

    let analyzer = ActivityAnalyzer()

    // MARK: - Segment Basics

    func testSegmentDuration() {
        let segment = ActivityAnalyzer.Segment(start: 2.0, end: 5.5, isIdle: true)
        XCTAssertEqual(segment.duration, 3.5, accuracy: 0.001)
    }

    func testSegmentZeroDuration() {
        let segment = ActivityAnalyzer.Segment(start: 3.0, end: 3.0, isIdle: false)
        XCTAssertEqual(segment.duration, 0, accuracy: 0.001)
    }

    // MARK: - Analyze from Events

    func testSingleEventProducesSegments() {
        let start = Date()
        let events = [
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(5.0), type: .move)
        ]

        let segments = analyzer.analyze(
            cursorEvents: events,
            keystrokeTimestamps: [],
            recordingStart: start,
            duration: 10.0,
            idleThreshold: 2.0
        )

        // Should have segments covering 0-10s
        XCTAssertGreaterThan(segments.count, 0)
        let total = segments.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(total, 10.0, accuracy: 0.1)
    }

    func testContinuousActivityProducesNoIdleSegments() {
        let start = Date()
        // Events every 0.5s for 10s — always within idle threshold of 2.0
        var events: [CursorEvent] = []
        for i in stride(from: 0.5, through: 9.5, by: 0.5) {
            events.append(CursorEvent(position: .zero, timestamp: start.addingTimeInterval(i), type: .move))
        }

        let segments = analyzer.analyze(
            cursorEvents: events,
            keystrokeTimestamps: [],
            recordingStart: start,
            duration: 10.0,
            idleThreshold: 2.0
        )

        let idleSegments = segments.filter { $0.isIdle }
        XCTAssertTrue(idleSegments.isEmpty, "Continuous activity should produce no idle segments")
    }

    func testLargeGapDetectedAsIdle() {
        let start = Date()
        // Two bursts with a 10-second gap between them
        let events = [
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(1.0), type: .move),
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(11.0), type: .move),
        ]

        let segments = analyzer.analyze(
            cursorEvents: events,
            keystrokeTimestamps: [],
            recordingStart: start,
            duration: 12.0,
            idleThreshold: 2.0
        )

        let idleSegments = segments.filter { $0.isIdle }
        XCTAssertFalse(idleSegments.isEmpty, "A 10s gap should be detected as idle")

        // The idle segment should be approximately 10s
        let totalIdle = idleSegments.reduce(0) { $0 + $1.duration }
        XCTAssertGreaterThan(totalIdle, 5.0)
    }

    func testKeystrokeTimestampsContributeToActivity() {
        let start = Date()
        // No cursor events, but keystrokes present
        let keystrokes = [
            start.addingTimeInterval(1.0),
            start.addingTimeInterval(1.5),
            start.addingTimeInterval(2.0),
        ]

        let segments = analyzer.analyze(
            cursorEvents: [],
            keystrokeTimestamps: keystrokes,
            recordingStart: start,
            duration: 5.0,
            idleThreshold: 2.0
        )

        // The keystrokes at 1.0-2.0s should create active segments
        XCTAssertGreaterThan(segments.count, 0)
        let activeSegments = segments.filter { !$0.isIdle }
        XCTAssertFalse(activeSegments.isEmpty, "Keystrokes should create active segments")
    }

    func testSegmentsCoverFullDuration() {
        let start = Date()
        let events = [
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(2.0), type: .move),
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(8.0), type: .leftClick),
        ]

        let segments = analyzer.analyze(
            cursorEvents: events,
            keystrokeTimestamps: [],
            recordingStart: start,
            duration: 20.0,
            idleThreshold: 3.0
        )

        let total = segments.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(total, 20.0, accuracy: 0.1, "Segments should cover the entire duration")

        // Verify no gaps: each segment starts where the previous one ended
        for i in 1..<segments.count {
            XCTAssertEqual(segments[i].start, segments[i-1].end, accuracy: 0.001, "No gaps between segments")
        }

        // First segment starts at 0
        XCTAssertEqual(segments.first?.start, 0, accuracy: 0.001)
        // Last segment ends at duration
        XCTAssertEqual(segments.last?.end, 20.0, accuracy: 0.1)
    }
}
#endif
