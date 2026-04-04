import XCTest
@testable import ScreenMuseCore

/// Unit tests for the /recordings pagination logic.
///
/// Since Server+System.swift reads from disk, we test the pagination math
/// directly by replicating the logic with mock data.
final class RecordingsPaginationTests: XCTestCase {

    // MARK: - Helpers

    /// Simulate the /recordings pagination logic from Server+System.swift.
    private func paginate(
        recordings: [[String: Any]],
        limit: Int?,
        offset: Int,
        sort: String = "desc"
    ) -> (sliced: [[String: Any]], total: Int, hasMore: Bool, count: Int) {
        var recs = recordings
        let sortAscending = sort == "asc"
        let resolvedLimit = max(1, limit ?? max(recs.count, 1))
        let resolvedOffset = max(0, offset)

        if sortAscending {
            recs.sort { ($0["filename"] as? String ?? "") < ($1["filename"] as? String ?? "") }
        } else {
            recs.sort { ($0["filename"] as? String ?? "") > ($1["filename"] as? String ?? "") }
        }

        let total = recs.count
        let sliced = Array(recs.dropFirst(resolvedOffset).prefix(resolvedLimit))
        let hasMore = resolvedOffset + sliced.count < total
        return (sliced, total, hasMore, sliced.count)
    }

    private func makeRecordings(count: Int) -> [[String: Any]] {
        (1...max(1, count)).map { i in
            ["filename": String(format: "recording_%03d.mp4", i), "size": i * 1_000_000]
        }
    }

    // MARK: - Basic pagination

    func testDefaultNoLimit_returnsAll() {
        let recs = makeRecordings(count: 10)
        let result = paginate(recordings: recs, limit: nil, offset: 0)
        XCTAssertEqual(result.total, 10)
        XCTAssertEqual(result.count, 10)
        XCTAssertFalse(result.hasMore)
    }

    func testLimit5_from10() {
        let recs = makeRecordings(count: 10)
        let result = paginate(recordings: recs, limit: 5, offset: 0)
        XCTAssertEqual(result.total, 10)
        XCTAssertEqual(result.count, 5)
        XCTAssertTrue(result.hasMore)
    }

    func testOffset5_limit5_from10() {
        let recs = makeRecordings(count: 10)
        let result = paginate(recordings: recs, limit: 5, offset: 5)
        XCTAssertEqual(result.total, 10)
        XCTAssertEqual(result.count, 5)
        XCTAssertFalse(result.hasMore)
    }

    func testOffset9_limit5_from10_returnsOne() {
        let recs = makeRecordings(count: 10)
        let result = paginate(recordings: recs, limit: 5, offset: 9)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result.hasMore)
    }

    func testOffsetBeyondTotal_returnsEmpty() {
        let recs = makeRecordings(count: 5)
        let result = paginate(recordings: recs, limit: 5, offset: 10)
        XCTAssertEqual(result.count, 0)
        XCTAssertFalse(result.hasMore)
    }

    func testLimitZero_clampsTo1() {
        let recs = makeRecordings(count: 10)
        let result = paginate(recordings: recs, limit: 0, offset: 0)
        // limit 0 → clamped to 1
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.hasMore)
    }

    func testNegativeOffset_clampsTo0() {
        let recs = makeRecordings(count: 5)
        let result = paginate(recordings: recs, limit: 2, offset: -5)
        XCTAssertEqual(result.count, 2)
        // sliced from index 0
        XCTAssertEqual(result.sliced[0]["filename"] as? String, "recording_005.mp4") // desc default
    }

    // MARK: - Sort order

    func testSortDesc_newestFirst() {
        let recs = makeRecordings(count: 5)
        let result = paginate(recordings: recs, limit: nil, offset: 0, sort: "desc")
        // Filenames are recording_001..005; desc = 005 first
        XCTAssertEqual(result.sliced.first?["filename"] as? String, "recording_005.mp4")
        XCTAssertEqual(result.sliced.last?["filename"] as? String, "recording_001.mp4")
    }

    func testSortAsc_oldestFirst() {
        let recs = makeRecordings(count: 5)
        let result = paginate(recordings: recs, limit: nil, offset: 0, sort: "asc")
        XCTAssertEqual(result.sliced.first?["filename"] as? String, "recording_001.mp4")
        XCTAssertEqual(result.sliced.last?["filename"] as? String, "recording_005.mp4")
    }

    // MARK: - Edge cases

    func testEmptyRecordings() {
        let result = paginate(recordings: [], limit: 10, offset: 0)
        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(result.count, 0)
        XCTAssertFalse(result.hasMore)
    }

    func testSingleRecording() {
        let recs = makeRecordings(count: 1)
        let result = paginate(recordings: recs, limit: 10, offset: 0)
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result.hasMore)
    }

    func testExactlyOnePage() {
        let recs = makeRecordings(count: 5)
        let result = paginate(recordings: recs, limit: 5, offset: 0)
        XCTAssertEqual(result.count, 5)
        XCTAssertFalse(result.hasMore)
    }

    func testLastPagePartial() {
        let recs = makeRecordings(count: 7)
        let result = paginate(recordings: recs, limit: 5, offset: 5)
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.hasMore)
    }

    func testLimitLargerThanTotal() {
        let recs = makeRecordings(count: 3)
        let result = paginate(recordings: recs, limit: 100, offset: 0)
        XCTAssertEqual(result.count, 3)
        XCTAssertFalse(result.hasMore)
    }

    // MARK: - hasMore boundary

    func testHasMoreBoundary_exactlyAtEnd() {
        let recs = makeRecordings(count: 10)
        // offset=5, limit=5, total=10 → 5+5=10 = total → hasMore=false
        let result = paginate(recordings: recs, limit: 5, offset: 5)
        XCTAssertFalse(result.hasMore)
    }

    func testHasMoreBoundary_oneShort() {
        let recs = makeRecordings(count: 11)
        // offset=5, limit=5, total=11 → 5+5=10 < 11 → hasMore=true
        let result = paginate(recordings: recs, limit: 5, offset: 5)
        XCTAssertTrue(result.hasMore)
    }

    // MARK: - Consistency: paginating through all pages returns all items

    func testPaginatingAllPages_coversAll() {
        let total = 23
        let pageSize = 5
        let recs = makeRecordings(count: total)

        var seen: [String] = []
        var offset = 0
        var iterations = 0
        repeat {
            let result = paginate(recordings: recs, limit: pageSize, offset: offset)
            let filenames = result.sliced.compactMap { $0["filename"] as? String }
            seen.append(contentsOf: filenames)
            offset += result.count
            iterations += 1
            if iterations > total { break } // safety
        } while seen.count < total

        XCTAssertEqual(seen.count, total)
        XCTAssertEqual(Set(seen).count, total) // no duplicates
    }
}
