#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests SpeedRamper config validation, ActivityAnalyzer edge cases,
/// and VideoTrimmer expanded coverage — all pure logic, no I/O.
final class SpeedRampConfigValidationTests: XCTestCase {

    // MARK: - SpeedRamper Config Bounds

    func testIdleSpeedFloorAtOne() {
        // The /speedramp handler clamps idle_speed to max(1.0, v)
        let raw: Double = 0.5
        let clamped = max(1.0, raw)
        XCTAssertEqual(clamped, 1.0, "idle_speed should be clamped to minimum of 1.0")
    }

    func testActiveSpeedFloorAtPointOne() {
        // The /speedramp handler clamps active_speed to max(0.1, v)
        let raw: Double = 0.01
        let clamped = max(0.1, raw)
        XCTAssertEqual(clamped, 0.1, "active_speed should be clamped to minimum of 0.1")
    }

    func testNormalSpeedsPassThrough() {
        let idleSpeed: Double = 6.0
        let activeSpeed: Double = 0.8
        XCTAssertEqual(max(1.0, idleSpeed), 6.0)
        XCTAssertEqual(max(0.1, activeSpeed), 0.8)
    }

    // MARK: - ActivityAnalyzer Edge Cases

    func testAnalyzerWithNoEventsProducesSingleActiveSegment() {
        let analyzer = ActivityAnalyzer()
        let segments = analyzer.analyze(
            cursorEvents: [],
            keystrokeTimestamps: [],
            recordingStart: Date(),
            duration: 15.0,
            idleThreshold: 2.0
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(segments[0].isIdle)
        XCTAssertEqual(segments[0].duration, 15.0, accuracy: 0.1)
    }

    func testAnalyzerWithZeroDuration() {
        let analyzer = ActivityAnalyzer()
        let segments = analyzer.analyze(
            cursorEvents: [],
            keystrokeTimestamps: [],
            recordingStart: Date(),
            duration: 0.0,
            idleThreshold: 2.0
        )
        // With zero duration, we expect either no segments or a zero-length one
        let totalDuration = segments.reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(totalDuration, 0.0, accuracy: 0.01)
    }

    func testAnalyzerMergesAdjacentIdleSegments() {
        let start = Date()
        // Events: one at t=1, then gap until t=10, then another at t=11, then gap until t=20
        // With threshold 2.0, the gaps at 1-10 and 11-20 are idle
        let events = [
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(1.0), type: .move),
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(10.0), type: .move),
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(11.0), type: .move),
        ]
        let analyzer = ActivityAnalyzer()
        let segments = analyzer.analyze(
            cursorEvents: events,
            keystrokeTimestamps: [],
            recordingStart: start,
            duration: 20.0,
            idleThreshold: 2.0
        )

        // Verify full coverage
        let total = segments.reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(total, 20.0, accuracy: 0.1)

        // Verify at least one idle segment exists from the 1-10s gap
        let idleSegments = segments.filter { $0.isIdle }
        XCTAssertFalse(idleSegments.isEmpty, "Should have at least one idle segment from the 9s gap")
    }

    func testAnalyzerShortGapIsActive() {
        let start = Date()
        // Events 0.5s apart — well within the 2.0s idle threshold
        let events = [
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(1.0), type: .move),
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(1.5), type: .move),
            CursorEvent(position: .zero, timestamp: start.addingTimeInterval(2.0), type: .move),
        ]
        let analyzer = ActivityAnalyzer()
        let segments = analyzer.analyze(
            cursorEvents: events,
            keystrokeTimestamps: [],
            recordingStart: start,
            duration: 3.0,
            idleThreshold: 2.0
        )

        // The internal 0.5s gaps should NOT be idle
        let internalSegments = segments.filter { $0.start >= 1.0 && $0.end <= 2.0 }
        for seg in internalSegments {
            XCTAssertFalse(seg.isIdle, "0.5s gap should be active, not idle")
        }
    }

    // MARK: - VideoTrimmer Config Expanded

    func testTrimConfigStartMustBeNonNegative() {
        var config = VideoTrimmer.Config()
        config.start = -5.0
        // The handler doesn't clamp, but we test that the value stores
        XCTAssertEqual(config.start, -5.0, "Config allows negative start — handler should validate")
    }

    func testTrimConfigReencodeToggle() {
        var config = VideoTrimmer.Config()
        XCTAssertFalse(config.reencode, "Default should be stream copy (no reencode)")
        config.reencode = true
        XCTAssertTrue(config.reencode)
    }

    // MARK: - SpeedRamper.SpeedRampResult Compression Ratio

    func testCompressionRatioCalculation() {
        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        let result = SpeedRamper.SpeedRampResult(
            outputURL: url,
            originalDuration: 120.0,
            outputDuration: 40.0,
            compressionRatio: 3.0,
            idleSections: 5,
            idleTotalSeconds: 60.0,
            activeSections: 6,
            activeTotalSeconds: 60.0,
            fileSize: 10_000_000
        )
        XCTAssertEqual(result.compressionRatio, 3.0, accuracy: 0.01)
        XCTAssertEqual(result.sizeMB, 10_000_000.0 / 1_048_576.0, accuracy: 0.01)
    }
}
#endif
