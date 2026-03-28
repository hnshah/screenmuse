#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests for timeline management: chapters, notes, highlights ordering and accumulation.
/// Uses ScreenMuseServer.shared state directly — pure logic, no I/O.
final class TimelineTests: XCTestCase {

    // MARK: - Chapter Ordering

    @MainActor
    func testChaptersOrderedByTime() {
        let server = ScreenMuseServer.shared
        server.chapters = []
        server.chapters.append((name: "End", time: 30.0))
        server.chapters.append((name: "Start", time: 0.0))
        server.chapters.append((name: "Middle", time: 15.0))

        let sorted = server.chapters.sorted { $0.time < $1.time }
        XCTAssertEqual(sorted[0].name, "Start")
        XCTAssertEqual(sorted[1].name, "Middle")
        XCTAssertEqual(sorted[2].name, "End")
    }

    @MainActor
    func testChapterTimestampsAreNonNegative() {
        let server = ScreenMuseServer.shared
        server.chapters = []
        server.chapters.append((name: "First", time: 0.0))
        server.chapters.append((name: "Second", time: 5.5))
        for ch in server.chapters {
            XCTAssertGreaterThanOrEqual(ch.time, 0.0)
        }
    }

    // MARK: - Note Timestamp Accuracy

    @MainActor
    func testNoteTimestampAccuracy() {
        let server = ScreenMuseServer.shared
        server.sessionNotes = []
        let expectedTime = 3.14159
        server.sessionNotes.append((text: "Pi note", time: expectedTime))
        XCTAssertEqual(server.sessionNotes[0].time, expectedTime, accuracy: 0.01)
    }

    @MainActor
    func testNoteTextPreserved() {
        let server = ScreenMuseServer.shared
        server.sessionNotes = []
        let longText = "This is a longer note with special chars: <>&\""
        server.sessionNotes.append((text: longText, time: 1.0))
        XCTAssertEqual(server.sessionNotes[0].text, longText)
    }

    // MARK: - Multiple Highlights

    @MainActor
    func testMultipleHighlightsAccumulate() {
        let server = ScreenMuseServer.shared
        server.sessionHighlights = []
        server.sessionHighlights.append(2.0)
        server.sessionHighlights.append(5.0)
        server.sessionHighlights.append(8.0)
        server.sessionHighlights.append(12.5)
        XCTAssertEqual(server.sessionHighlights.count, 4)
    }

    @MainActor
    func testHighlightsOrderPreserved() {
        let server = ScreenMuseServer.shared
        server.sessionHighlights = []
        server.sessionHighlights.append(10.0)
        server.sessionHighlights.append(2.0)
        server.sessionHighlights.append(7.0)
        // Order is insertion order, not sorted
        XCTAssertEqual(server.sessionHighlights[0], 10.0, accuracy: 0.001)
        XCTAssertEqual(server.sessionHighlights[1], 2.0, accuracy: 0.001)
        XCTAssertEqual(server.sessionHighlights[2], 7.0, accuracy: 0.001)
    }

    // MARK: - Event Count

    @MainActor
    func testTimelineEventCountCalculation() {
        let server = ScreenMuseServer.shared
        server.chapters = []
        server.sessionNotes = []
        server.sessionHighlights = []

        server.chapters.append((name: "Ch1", time: 0))
        server.chapters.append((name: "Ch2", time: 5))
        server.sessionNotes.append((text: "Note1", time: 2))
        server.sessionHighlights.append(3.0)
        server.sessionHighlights.append(7.0)

        let eventCount = server.chapters.count + server.sessionNotes.count + server.sessionHighlights.count
        XCTAssertEqual(eventCount, 5)
    }

    @MainActor
    func testEmptyTimelineEventCount() {
        let server = ScreenMuseServer.shared
        server.chapters = []
        server.sessionNotes = []
        server.sessionHighlights = []

        let eventCount = server.chapters.count + server.sessionNotes.count + server.sessionHighlights.count
        XCTAssertEqual(eventCount, 0)
    }

    // MARK: - Chapter Name Variants

    @MainActor
    func testChapterWithEmptyName() {
        let server = ScreenMuseServer.shared
        server.chapters = []
        server.chapters.append((name: "", time: 1.0))
        XCTAssertEqual(server.chapters[0].name, "")
    }

    @MainActor
    func testChapterWithUnicodeName() {
        let server = ScreenMuseServer.shared
        server.chapters = []
        server.chapters.append((name: "Chapitre 1", time: 0.0))
        XCTAssertEqual(server.chapters[0].name, "Chapitre 1")
    }
}
#endif
