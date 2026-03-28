#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests for the async JobQueue actor.
final class JobQueueTests: XCTestCase {

    // MARK: - Job Creation

    func testCreateReturnsUniqueIDs() async {
        let queue = JobQueue()
        let id1 = await queue.create(endpoint: "/export")
        let id2 = await queue.create(endpoint: "/export")
        XCTAssertNotEqual(id1, id2, "Each job should get a unique ID")
    }

    func testCreateSetsEndpoint() async {
        let queue = JobQueue()
        let id = await queue.create(endpoint: "/ocr")
        let job = await queue.get(id)
        XCTAssertEqual(job?.endpoint, "/ocr")
    }

    func testCreateSetsPendingStatus() async {
        let queue = JobQueue()
        let id = await queue.create(endpoint: "/export")
        let job = await queue.get(id)
        XCTAssertEqual(job?.status, .pending)
    }

    func testJobIDIs8Characters() async {
        let queue = JobQueue()
        let id = await queue.create(endpoint: "/export")
        XCTAssertEqual(id.count, 8, "Job ID should be 8 characters (UUID prefix)")
    }

    // MARK: - Status Transitions

    func testSetRunning() async {
        let queue = JobQueue()
        let id = await queue.create(endpoint: "/export")
        await queue.setRunning(id)
        let job = await queue.get(id)
        XCTAssertEqual(job?.status, .running)
    }

    func testComplete() async {
        let queue = JobQueue()
        let id = await queue.create(endpoint: "/export")
        await queue.setRunning(id)
        await queue.complete(id, result: ["path": "/tmp/test.gif", "size_mb": 1.5])
        let job = await queue.get(id)
        XCTAssertEqual(job?.status, .completed)
        XCTAssertNotNil(job?.completedAt)
        XCTAssertEqual(job?.result?["path"] as? String, "/tmp/test.gif")
    }

    func testFail() async {
        let queue = JobQueue()
        let id = await queue.create(endpoint: "/export")
        await queue.setRunning(id)
        await queue.fail(id, error: "No video source")
        let job = await queue.get(id)
        XCTAssertEqual(job?.status, .failed)
        XCTAssertEqual(job?.error, "No video source")
        XCTAssertNotNil(job?.completedAt)
    }

    // MARK: - List and Lookup

    func testListReturnsAllJobs() async {
        let queue = JobQueue()
        _ = await queue.create(endpoint: "/export")
        _ = await queue.create(endpoint: "/ocr")
        _ = await queue.create(endpoint: "/crop")
        let jobs = await queue.list()
        XCTAssertEqual(jobs.count, 3)
    }

    func testListSortedByCreatedAtDescending() async {
        let queue = JobQueue()
        let id1 = await queue.create(endpoint: "/export")
        let id2 = await queue.create(endpoint: "/ocr")
        let jobs = await queue.list()
        // Most recent first
        XCTAssertEqual(jobs.first?.id, id2)
        XCTAssertEqual(jobs.last?.id, id1)
    }

    func testGetNonExistentReturnsNil() async {
        let queue = JobQueue()
        let job = await queue.get("nonexistent")
        XCTAssertNil(job)
    }

    // MARK: - Cleanup

    func testCleanupRemovesOldCompletedJobs() async {
        let queue = JobQueue()
        let id = await queue.create(endpoint: "/export")
        await queue.complete(id, result: ["ok": true])
        // Cleanup with interval of 0 (remove everything)
        await queue.cleanup(olderThan: 0)
        let job = await queue.get(id)
        XCTAssertNil(job, "Completed job should be cleaned up")
    }

    func testCleanupKeepsRunningJobs() async {
        let queue = JobQueue()
        let id = await queue.create(endpoint: "/export")
        await queue.setRunning(id)
        await queue.cleanup(olderThan: 0)
        let job = await queue.get(id)
        XCTAssertNotNil(job, "Running job should NOT be cleaned up")
    }

    // MARK: - Job Dictionary Representation

    func testJobAsDictionary() async {
        let queue = JobQueue()
        let id = await queue.create(endpoint: "/export")
        await queue.setRunning(id)
        await queue.complete(id, result: ["path": "/tmp/out.gif"])
        let job = await queue.get(id)!
        let dict = job.asDictionary()

        XCTAssertEqual(dict["id"] as? String, id)
        XCTAssertEqual(dict["endpoint"] as? String, "/export")
        XCTAssertEqual(dict["status"] as? String, "completed")
        XCTAssertNotNil(dict["created_at"])
        XCTAssertNotNil(dict["completed_at"])
        XCTAssertNotNil(dict["elapsed_ms"])
        XCTAssertNotNil(dict["result"])
    }
}
#endif
