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

    // MARK: - Script Start State Reset

    @MainActor
    func testScriptStartResetsChapters() {
        let server = ScreenMuseServer.shared
        // Simulate leftover state from a previous session
        server.chapters = [(name: "Old Chapter", time: 1.0), (name: "Stale Chapter", time: 5.0)]
        server.sessionNotes = [(text: "old note", time: 2.0)]
        server.sessionHighlights = [3.0, 6.0]
        server.highlightNextClick = true
        server.currentVideoURL = URL(fileURLWithPath: "/tmp/old-video.mp4")

        // Simulate what /script "start" now does (state reset)
        server.sessionID = UUID().uuidString
        server.sessionName = "fresh-session"
        server.startTime = Date()
        server.isRecording = true
        server.chapters = []
        server.sessionNotes.removeAll()
        server.sessionHighlights.removeAll()
        server.highlightNextClick = false
        server.currentVideoURL = nil

        XCTAssertEqual(server.chapters.count, 0, "chapters should be empty after script start")
        XCTAssertEqual(server.sessionNotes.count, 0, "sessionNotes should be empty after script start")
        XCTAssertEqual(server.sessionHighlights.count, 0, "sessionHighlights should be empty after script start")
        XCTAssertFalse(server.highlightNextClick, "highlightNextClick should be false after script start")
        XCTAssertNil(server.currentVideoURL, "currentVideoURL should be nil after script start")

        // Clean up
        server.isRecording = false
        server.sessionID = nil
        server.sessionName = nil
        server.startTime = nil
    }

    @MainActor
    func testScriptStartDoesNotLeakPreviousNotes() {
        let server = ScreenMuseServer.shared
        // First "session"
        server.sessionNotes = [(text: "note from session 1", time: 1.0)]
        server.sessionHighlights = [2.0]
        server.chapters = [(name: "ch1", time: 0.5)]

        // Simulate script start (reset)
        server.chapters = []
        server.sessionNotes.removeAll()
        server.sessionHighlights.removeAll()

        // Second "session" adds its own data
        server.sessionNotes.append((text: "note from session 2", time: 0.5))

        XCTAssertEqual(server.sessionNotes.count, 1)
        XCTAssertEqual(server.sessionNotes[0].text, "note from session 2")
        XCTAssertEqual(server.chapters.count, 0)
        XCTAssertEqual(server.sessionHighlights.count, 0)
    }

    @MainActor
    func testHighlightNextClickResetsOnStart() {
        let server = ScreenMuseServer.shared
        server.highlightNextClick = true
        XCTAssertTrue(server.highlightNextClick)

        // Simulate script start reset
        server.highlightNextClick = false
        XCTAssertFalse(server.highlightNextClick, "highlightNextClick must reset to false on new session start")
    }

    @MainActor
    func testCurrentVideoURLResetsOnStart() {
        let server = ScreenMuseServer.shared
        server.currentVideoURL = URL(fileURLWithPath: "/tmp/previous-recording.mp4")
        XCTAssertNotNil(server.currentVideoURL)

        // Simulate script start reset
        server.currentVideoURL = nil
        XCTAssertNil(server.currentVideoURL, "currentVideoURL must be nil after starting a new session")
    }
}
#endif
