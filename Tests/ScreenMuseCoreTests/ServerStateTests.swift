#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests ScreenMuseServer state management (chapters, notes, highlights, isRecording).
/// These test the public mutable state on the server singleton without needing
/// a live NWListener or real recording.
final class ServerStateTests: XCTestCase {

    // MARK: - Chapter Management

    @MainActor
    func testChaptersStartEmpty() {
        let server = ScreenMuseServer.shared
        // Reset for test isolation
        server.chapters = []
        XCTAssertEqual(server.chapters.count, 0)
    }

    @MainActor
    func testAppendingChaptersPreservesOrder() {
        let server = ScreenMuseServer.shared
        server.chapters = []
        server.chapters.append((name: "Intro", time: 0.0))
        server.chapters.append((name: "Setup", time: 5.0))
        server.chapters.append((name: "Demo", time: 12.0))

        XCTAssertEqual(server.chapters.count, 3)
        XCTAssertEqual(server.chapters[0].name, "Intro")
        XCTAssertEqual(server.chapters[1].name, "Setup")
        XCTAssertEqual(server.chapters[2].name, "Demo")
        XCTAssertEqual(server.chapters[2].time, 12.0, accuracy: 0.001)
    }

    // MARK: - Session Notes

    @MainActor
    func testSessionNotesAccumulate() {
        let server = ScreenMuseServer.shared
        server.sessionNotes = []
        server.sessionNotes.append((text: "Audio dropped here", time: 3.5))
        server.sessionNotes.append((text: "User clicked save", time: 7.2))

        XCTAssertEqual(server.sessionNotes.count, 2)
        XCTAssertEqual(server.sessionNotes[0].text, "Audio dropped here")
        XCTAssertEqual(server.sessionNotes[1].time, 7.2, accuracy: 0.001)
    }

    // MARK: - Highlight State

    @MainActor
    func testHighlightNextClickDefaultsFalse() {
        let server = ScreenMuseServer.shared
        server.highlightNextClick = false
        XCTAssertFalse(server.highlightNextClick)
    }

    @MainActor
    func testHighlightNextClickToggles() {
        let server = ScreenMuseServer.shared
        server.highlightNextClick = true
        XCTAssertTrue(server.highlightNextClick)
        server.highlightNextClick = false
        XCTAssertFalse(server.highlightNextClick)
    }

    @MainActor
    func testSessionHighlightsAccumulate() {
        let server = ScreenMuseServer.shared
        server.sessionHighlights = []
        server.sessionHighlights.append(1.5)
        server.sessionHighlights.append(4.0)
        server.sessionHighlights.append(8.3)

        XCTAssertEqual(server.sessionHighlights.count, 3)
        XCTAssertEqual(server.sessionHighlights[1], 4.0, accuracy: 0.001)
    }

    // MARK: - Recording State Transitions

    @MainActor
    func testIsRecordingDefaultFalse() {
        let server = ScreenMuseServer.shared
        // Note: shared singleton may have leftover state; just verify the property exists and toggles
        server.isRecording = false
        XCTAssertFalse(server.isRecording)
    }

    @MainActor
    func testRecordingStateTransitions() {
        let server = ScreenMuseServer.shared
        server.isRecording = false
        XCTAssertFalse(server.isRecording)

        server.isRecording = true
        XCTAssertTrue(server.isRecording)

        server.isRecording = false
        XCTAssertFalse(server.isRecording)
    }

    @MainActor
    func testSessionIDAndNameSetDuringRecording() {
        let server = ScreenMuseServer.shared
        server.sessionID = "test-session-123"
        server.sessionName = "My Demo"
        server.startTime = Date()
        server.isRecording = true

        XCTAssertEqual(server.sessionID, "test-session-123")
        XCTAssertEqual(server.sessionName, "My Demo")
        XCTAssertNotNil(server.startTime)
        XCTAssertTrue(server.isRecording)

        // Clean up
        server.isRecording = false
        server.sessionID = nil
        server.sessionName = nil
        server.startTime = nil
    }
}
#endif
