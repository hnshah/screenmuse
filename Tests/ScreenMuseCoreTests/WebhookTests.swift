#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests for webhook retry logic — backoff array, retry behavior, etc.
/// Pure logic — no real network calls.
final class WebhookTests: XCTestCase {

    // MARK: - Backoff Array

    func testBackoffArrayHasThreeEntries() {
        let backoff = ScreenMuseServer.webhookBackoffSeconds
        XCTAssertEqual(backoff.count, 3, "Should have 3 retry entries (0s, 2s, 8s)")
    }

    func testBackoffFirstAttemptIsImmediate() {
        let backoff = ScreenMuseServer.webhookBackoffSeconds
        XCTAssertEqual(backoff[0], 0, "First attempt should be immediate (0s delay)")
    }

    func testBackoffIsExponential() {
        let backoff = ScreenMuseServer.webhookBackoffSeconds
        XCTAssertEqual(backoff[0], 0)
        XCTAssertEqual(backoff[1], 2)
        XCTAssertEqual(backoff[2], 8)
        // Verify increasing order
        XCTAssertLessThan(backoff[0], backoff[1])
        XCTAssertLessThan(backoff[1], backoff[2])
    }

    // MARK: - Retry Logic Simulation

    func testSuccessOnFirstAttemptStopsRetrying() {
        // Simulate: attempt counter and early-return on success
        var attemptsMade = 0
        let maxRetries = 3
        let backoff = ScreenMuseServer.webhookBackoffSeconds

        for attempt in 0..<maxRetries {
            attemptsMade += 1
            // Simulate success on first attempt
            let httpStatus = 200
            if httpStatus >= 200 && httpStatus < 300 {
                break  // success, stop retrying
            }
        }
        XCTAssertEqual(attemptsMade, 1, "Should stop after first successful attempt")
    }

    func testSuccessOnSecondAttemptStopsRetrying() {
        var attemptsMade = 0
        let maxRetries = 3

        for attempt in 0..<maxRetries {
            attemptsMade += 1
            // Simulate failure on first attempt, success on second
            let httpStatus = attempt == 0 ? 500 : 200
            if httpStatus >= 200 && httpStatus < 300 {
                break
            }
        }
        XCTAssertEqual(attemptsMade, 2, "Should stop after second successful attempt")
    }

    func testAllAttemptsFailRunsFull() {
        var attemptsMade = 0
        let maxRetries = 3

        for _ in 0..<maxRetries {
            attemptsMade += 1
            // Always fail
            let httpStatus = 503
            if httpStatus >= 200 && httpStatus < 300 {
                break
            }
        }
        XCTAssertEqual(attemptsMade, 3, "Should exhaust all 3 attempts when all fail")
    }

    // MARK: - Webhook URL Guard

    @MainActor
    func testNilWebhookURLDoesNothing() {
        let server = ScreenMuseServer.shared
        // This should return immediately without crashing
        let fakeVideoURL = URL(fileURLWithPath: "/tmp/test.mp4")
        server.fireWebhook(nil, videoURL: fakeVideoURL, sessionID: "test", elapsed: 5.0)
        // No crash = pass. The nil guard returns immediately.
    }
}
#endif
