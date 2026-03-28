import XCTest
@testable import ScreenMuseCore
import Foundation

/// Tests for timeline management (chapters, highlights, notes)
/// Priority: MEDIUM - Important for structured recordings
final class TimelineManagementTests: XCTestCase {
    
    var manager: RecordingManager!
    var timeline: TimelineManager!
    
    override func setUp() async throws {
        try await super.setUp()
        manager = RecordingManager()
        timeline = TimelineManager()
        
        // Start a recording for timeline tests
        let config = RecordingConfig(name: "timeline-test")
        try await manager.startRecording(config: config)
    }
    
    override func tearDown() async throws {
        // Stop recording and cleanup
        if manager.isRecording {
            _ = try? await manager.stopRecording()
        }
        try await super.tearDown()
    }
    
    // MARK: - Chapter Tests
    
    func testAddChapter() async throws {
        // Given: Recording in progress
        XCTAssertTrue(manager.isRecording)
        
        // When: Adding a chapter
        let chapter = try await timeline.addChapter(name: "Introduction")
        
        // Then: Chapter should be created with timestamp
        XCTAssertEqual(chapter.name, "Introduction")
        XCTAssertGreaterThan(chapter.timestamp, 0)
        XCTAssertNotNil(chapter.id)
    }
    
    func testAddMultipleChapters() async throws {
        // When: Adding several chapters
        let chapter1 = try await timeline.addChapter(name: "Step 1")
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        
        let chapter2 = try await timeline.addChapter(name: "Step 2")
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let chapter3 = try await timeline.addChapter(name: "Step 3")
        
        // Then: All chapters should exist with increasing timestamps
        XCTAssertLessThan(chapter1.timestamp, chapter2.timestamp)
        XCTAssertLessThan(chapter2.timestamp, chapter3.timestamp)
        
        let allChapters = try await timeline.getChapters()
        XCTAssertEqual(allChapters.count, 3)
    }
    
    func testListChapters() async throws {
        // Given: Multiple chapters added
        try await timeline.addChapter(name: "Intro")
        try await timeline.addChapter(name: "Main")
        try await timeline.addChapter(name: "Outro")
        
        // When: Listing chapters
        let chapters = try await timeline.getChapters()
        
        // Then: Should return all chapters in order
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].name, "Intro")
        XCTAssertEqual(chapters[1].name, "Main")
        XCTAssertEqual(chapters[2].name, "Outro")
    }
    
    func testUpdateChapterName() async throws {
        // Given: A chapter exists
        let chapter = try await timeline.addChapter(name: "Original Name")
        XCTAssertEqual(chapter.name, "Original Name")
        
        // When: Updating the name
        try await timeline.updateChapter(id: chapter.id, name: "Updated Name")
        
        // Then: Name should be changed
        let updated = try await timeline.getChapter(id: chapter.id)
        XCTAssertEqual(updated.name, "Updated Name")
        XCTAssertEqual(updated.timestamp, chapter.timestamp) // Timestamp unchanged
    }
    
    func testDeleteChapter() async throws {
        // Given: A chapter exists
        let chapter = try await timeline.addChapter(name: "To Delete")
        let allBefore = try await timeline.getChapters()
        XCTAssertEqual(allBefore.count, 1)
        
        // When: Deleting the chapter
        try await timeline.deleteChapter(id: chapter.id)
        
        // Then: Chapter should be removed
        let allAfter = try await timeline.getChapters()
        XCTAssertEqual(allAfter.count, 0)
    }
    
    func testChapterWithoutRecording() async throws {
        // Given: No recording in progress
        _ = try await manager.stopRecording()
        XCTAssertFalse(manager.isRecording)
        
        // When: Attempting to add chapter
        do {
            _ = try await timeline.addChapter(name: "Should Fail")
            XCTFail("Should throw error when not recording")
        } catch TimelineError.notRecording {
            // Expected
        }
    }
    
    // MARK: - Highlight Tests
    
    func testAddHighlight() async throws {
        // When: Marking a highlight
        let highlight = try await timeline.addHighlight()
        
        // Then: Highlight should be created at current timestamp
        XCTAssertGreaterThan(highlight.timestamp, 0)
        XCTAssertNotNil(highlight.id)
    }
    
    func testAddHighlightWithNote() async throws {
        // When: Adding highlight with note
        let highlight = try await timeline.addHighlight(note: "Important moment")
        
        // Then: Note should be attached
        XCTAssertEqual(highlight.note, "Important moment")
        XCTAssertGreaterThan(highlight.timestamp, 0)
    }
    
    func testListHighlights() async throws {
        // Given: Multiple highlights
        try await timeline.addHighlight(note: "First")
        try await Task.sleep(nanoseconds: 200_000_000)
        try await timeline.addHighlight(note: "Second")
        try await Task.sleep(nanoseconds: 200_000_000)
        try await timeline.addHighlight(note: "Third")
        
        // When: Listing highlights
        let highlights = try await timeline.getHighlights()
        
        // Then: Should return all in chronological order
        XCTAssertEqual(highlights.count, 3)
        XCTAssertEqual(highlights[0].note, "First")
        XCTAssertEqual(highlights[1].note, "Second")
        XCTAssertEqual(highlights[2].note, "Third")
    }
    
    func testDeleteHighlight() async throws {
        // Given: A highlight exists
        let highlight = try await timeline.addHighlight(note: "Test")
        let allBefore = try await timeline.getHighlights()
        XCTAssertEqual(allBefore.count, 1)
        
        // When: Deleting highlight
        try await timeline.deleteHighlight(id: highlight.id)
        
        // Then: Should be removed
        let allAfter = try await timeline.getHighlights()
        XCTAssertEqual(allAfter.count, 0)
    }
    
    // MARK: - Note Tests
    
    func testAddNote() async throws {
        // When: Adding a note
        let note = try await timeline.addNote(text: "This is a test note")
        
        // Then: Note should be created
        XCTAssertEqual(note.text, "This is a test note")
        XCTAssertGreaterThan(note.timestamp, 0)
        XCTAssertNotNil(note.id)
    }
    
    func testAddNoteAtTimestamp() async throws {
        // When: Adding note at specific timestamp
        let note = try await timeline.addNote(
            text: "Retroactive note",
            timestamp: 5.0
        )
        
        // Then: Should use provided timestamp
        XCTAssertEqual(note.timestamp, 5.0)
        XCTAssertEqual(note.text, "Retroactive note")
    }
    
    func testListNotes() async throws {
        // Given: Multiple notes
        try await timeline.addNote(text: "Note 1")
        try await timeline.addNote(text: "Note 2")
        try await timeline.addNote(text: "Note 3")
        
        // When: Listing notes
        let notes = try await timeline.getNotes()
        
        // Then: Should return all notes
        XCTAssertEqual(notes.count, 3)
    }
    
    func testUpdateNote() async throws {
        // Given: A note exists
        let note = try await timeline.addNote(text: "Original text")
        
        // When: Updating the text
        try await timeline.updateNote(id: note.id, text: "Updated text")
        
        // Then: Text should be changed
        let updated = try await timeline.getNote(id: note.id)
        XCTAssertEqual(updated.text, "Updated text")
        XCTAssertEqual(updated.timestamp, note.timestamp)
    }
    
    func testDeleteNote() async throws {
        // Given: A note exists
        let note = try await timeline.addNote(text: "To delete")
        XCTAssertEqual(try await timeline.getNotes().count, 1)
        
        // When: Deleting note
        try await timeline.deleteNote(id: note.id)
        
        // Then: Should be removed
        XCTAssertEqual(try await timeline.getNotes().count, 0)
    }
    
    // MARK: - Timeline Export Tests
    
    func testExportTimelineJSON() async throws {
        // Given: Timeline with chapters, highlights, notes
        try await timeline.addChapter(name: "Introduction")
        try await timeline.addHighlight(note: "Key moment")
        try await timeline.addNote(text: "Important detail")
        
        // When: Exporting to JSON
        let json = try await timeline.exportJSON()
        
        // Then: Should contain all timeline data
        XCTAssertTrue(json.contains("chapters"))
        XCTAssertTrue(json.contains("highlights"))
        XCTAssertTrue(json.contains("notes"))
        XCTAssertTrue(json.contains("Introduction"))
        XCTAssertTrue(json.contains("Key moment"))
        XCTAssertTrue(json.contains("Important detail"))
    }
    
    func testImportTimelineJSON() async throws {
        // Given: Valid timeline JSON
        let json = """
        {
            "chapters": [
                {"id": "ch1", "name": "Imported Chapter", "timestamp": 5.0}
            ],
            "highlights": [
                {"id": "hl1", "timestamp": 10.0, "note": "Imported Highlight"}
            ],
            "notes": [
                {"id": "n1", "text": "Imported Note", "timestamp": 15.0}
            ]
        }
        """
        
        // When: Importing timeline
        try await timeline.importJSON(json)
        
        // Then: All items should be imported
        let chapters = try await timeline.getChapters()
        let highlights = try await timeline.getHighlights()
        let notes = try await timeline.getNotes()
        
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].name, "Imported Chapter")
        
        XCTAssertEqual(highlights.count, 1)
        XCTAssertEqual(highlights[0].note, "Imported Highlight")
        
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].text, "Imported Note")
    }
    
    // MARK: - Timeline Validation Tests
    
    func testTimelineConsistency() async throws {
        // Given: Timeline events at different times
        let chapter1 = try await timeline.addChapter(name: "Start")
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let highlight1 = try await timeline.addHighlight()
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let chapter2 = try await timeline.addChapter(name: "Middle")
        
        // Then: Timestamps should be in chronological order
        XCTAssertLessThan(chapter1.timestamp, highlight1.timestamp)
        XCTAssertLessThan(highlight1.timestamp, chapter2.timestamp)
    }
    
    func testGetTimelineEvents() async throws {
        // Given: Mixed timeline events
        try await timeline.addChapter(name: "Chapter 1")
        try await Task.sleep(nanoseconds: 200_000_000)
        try await timeline.addHighlight(note: "Highlight 1")
        try await Task.sleep(nanoseconds: 200_000_000)
        try await timeline.addNote(text: "Note 1")
        
        // When: Getting all events
        let events = try await timeline.getAllEvents()
        
        // Then: Should return all events sorted by timestamp
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events[0].timestamp <= events[1].timestamp)
        XCTAssertTrue(events[1].timestamp <= events[2].timestamp)
    }
    
    func testClearTimeline() async throws {
        // Given: Timeline with data
        try await timeline.addChapter(name: "Test")
        try await timeline.addHighlight()
        try await timeline.addNote(text: "Test")
        
        XCTAssertGreaterThan(try await timeline.getAllEvents().count, 0)
        
        // When: Clearing timeline
        try await timeline.clear()
        
        // Then: All events should be removed
        XCTAssertEqual(try await timeline.getChapters().count, 0)
        XCTAssertEqual(try await timeline.getHighlights().count, 0)
        XCTAssertEqual(try await timeline.getNotes().count, 0)
    }
    
    // MARK: - Performance Tests
    
    func testAddChapterPerformance() async throws {
        measure {
            let expectation = expectation(description: "Add chapter")
            
            Task {
                _ = try await timeline.addChapter(name: "Performance Test")
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 0.5)
        }
    }
    
    func testListTimelinePerformance() async throws {
        // Given: 50 timeline events
        for i in 1...50 {
            if i % 3 == 0 {
                try await timeline.addChapter(name: "Chapter \(i)")
            } else if i % 3 == 1 {
                try await timeline.addHighlight(note: "Highlight \(i)")
            } else {
                try await timeline.addNote(text: "Note \(i)")
            }
        }
        
        // When: Listing all events
        measure {
            let expectation = expectation(description: "List events")
            
            Task {
                _ = try await timeline.getAllEvents()
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 1.0)
        }
    }
}

// MARK: - Supporting Types

enum TimelineError: Error {
    case notRecording
    case chapterNotFound
    case highlightNotFound
    case noteNotFound
    case invalidJSON
}

struct Chapter {
    let id: String
    let name: String
    let timestamp: Double
}

struct Highlight {
    let id: String
    let timestamp: Double
    let note: String?
}

struct Note {
    let id: String
    let text: String
    let timestamp: Double
}

enum TimelineEvent {
    case chapter(Chapter)
    case highlight(Highlight)
    case note(Note)
    
    var timestamp: Double {
        switch self {
        case .chapter(let ch): return ch.timestamp
        case .highlight(let hl): return hl.timestamp
        case .note(let n): return n.timestamp
        }
    }
}
