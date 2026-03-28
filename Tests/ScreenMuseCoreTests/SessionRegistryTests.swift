#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests SessionRegistry CRUD operations and session lifecycle.
final class SessionRegistryTests: XCTestCase {

    @MainActor
    func testCreateAndRetrieveSession() {
        let registry = SessionRegistry()
        let session = registry.create(id: "test-1", name: "My Session")

        XCTAssertEqual(session.id, "test-1")
        XCTAssertEqual(session.name, "My Session")
        XCTAssertTrue(session.isRecording)
        XCTAssertNotNil(session.startTime)

        let retrieved = registry.get("test-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, "test-1")
    }

    @MainActor
    func testGetNonexistentSessionReturnsNil() {
        let registry = SessionRegistry()
        XCTAssertNil(registry.get("does-not-exist"))
    }

    @MainActor
    func testUpdateSession() {
        let registry = SessionRegistry()
        registry.create(id: "s1", name: "Session 1")

        registry.update("s1") { session in
            session.isRecording = false
            session.videoURL = URL(fileURLWithPath: "/tmp/video.mp4")
            session.chapters = [(name: "Intro", time: 0.0), (name: "Demo", time: 5.0)]
        }

        let updated = registry.get("s1")!
        XCTAssertFalse(updated.isRecording)
        XCTAssertEqual(updated.videoURL?.path, "/tmp/video.mp4")
        XCTAssertEqual(updated.chapters.count, 2)
        XCTAssertEqual(updated.chapters[0].name, "Intro")
    }

    @MainActor
    func testRemoveSession() {
        let registry = SessionRegistry()
        registry.create(id: "s1", name: "Session 1")
        XCTAssertEqual(registry.count, 1)

        let removed = registry.remove("s1")
        XCTAssertNotNil(removed)
        XCTAssertEqual(removed?.id, "s1")
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(registry.get("s1"))
    }

    @MainActor
    func testRemoveNonexistentSessionReturnsNil() {
        let registry = SessionRegistry()
        XCTAssertNil(registry.remove("nope"))
    }

    @MainActor
    func testListSessions() {
        let registry = SessionRegistry()
        registry.create(id: "s1", name: "First")
        registry.create(id: "s2", name: "Second")
        registry.create(id: "s3", name: "Third")

        let all = registry.list()
        XCTAssertEqual(all.count, 3)
    }

    @MainActor
    func testListRecordingOnly() {
        let registry = SessionRegistry()
        registry.create(id: "s1", name: "Active")
        registry.create(id: "s2", name: "Done")
        registry.update("s2") { $0.isRecording = false }

        let recording = registry.list(recordingOnly: true)
        XCTAssertEqual(recording.count, 1)
        XCTAssertEqual(recording[0].id, "s1")
    }

    @MainActor
    func testActiveCount() {
        let registry = SessionRegistry()
        registry.create(id: "s1", name: "Active 1")
        registry.create(id: "s2", name: "Active 2")
        registry.create(id: "s3", name: "Done")
        registry.update("s3") { $0.isRecording = false }

        XCTAssertEqual(registry.activeCount, 2)
        XCTAssertEqual(registry.count, 3)
    }

    @MainActor
    func testPruneCompleted() {
        let registry = SessionRegistry()
        registry.create(id: "s1", name: "Active")
        registry.create(id: "s2", name: "Done 1")
        registry.create(id: "s3", name: "Done 2")
        registry.update("s2") { $0.isRecording = false }
        registry.update("s3") { $0.isRecording = false }

        registry.pruneCompleted()

        XCTAssertEqual(registry.count, 1)
        XCTAssertNotNil(registry.get("s1"))
        XCTAssertNil(registry.get("s2"))
        XCTAssertNil(registry.get("s3"))
    }

    @MainActor
    func testSessionAsDictionary() {
        let registry = SessionRegistry()
        registry.create(id: "dict-test", name: "Dict Session")
        registry.update("dict-test") { session in
            session.chapters = [(name: "Ch1", time: 1.0)]
            session.notes = [(text: "Note1", time: 2.0)]
            session.highlights = [3.0]
        }

        let session = registry.get("dict-test")!
        let dict = session.asDictionary()

        XCTAssertEqual(dict["session_id"] as? String, "dict-test")
        XCTAssertEqual(dict["name"] as? String, "Dict Session")
        XCTAssertEqual(dict["is_recording"] as? Bool, true)
        XCTAssertEqual(dict["chapter_count"] as? Int, 1)
        XCTAssertEqual(dict["note_count"] as? Int, 1)
    }

    @MainActor
    func testDefaultSessionID() {
        let registry = SessionRegistry()
        XCTAssertNil(registry.defaultSessionID)

        registry.create(id: "s1", name: "First")
        registry.defaultSessionID = "s1"
        XCTAssertEqual(registry.defaultSessionID, "s1")
    }
}
#endif
