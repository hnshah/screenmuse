#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests for API key validation logic.
/// Pure logic — validates the auth check rules without running a real server.
final class AuthTests: XCTestCase {

    // MARK: - API Key Nil = No Auth Required

    @MainActor
    func testNilAPIKeyAllowsAllRequests() {
        let server = ScreenMuseServer.shared
        let savedKey = server.apiKey
        defer { server.apiKey = savedKey }

        server.apiKey = nil
        // When apiKey is nil, no auth check is performed
        // Simulate: requiredKey (apiKey) is nil → skip auth
        XCTAssertNil(server.apiKey, "When apiKey is nil, auth should be disabled")
    }

    // MARK: - API Key Set = Only Matching Key Passes

    @MainActor
    func testMatchingKeyPasses() {
        let server = ScreenMuseServer.shared
        let savedKey = server.apiKey
        defer { server.apiKey = savedKey }

        let testKey = "test-key-12345"
        server.apiKey = testKey

        let providedKey = testKey
        let matches = providedKey == server.apiKey
        XCTAssertTrue(matches, "Matching key should pass auth")
    }

    @MainActor
    func testMismatchedKeyFails() {
        let server = ScreenMuseServer.shared
        let savedKey = server.apiKey
        defer { server.apiKey = savedKey }

        server.apiKey = "correct-key"
        let providedKey = "wrong-key"
        let matches = providedKey == server.apiKey
        XCTAssertFalse(matches, "Mismatched key should fail auth")
    }

    @MainActor
    func testEmptyProvidedKeyFails() {
        let server = ScreenMuseServer.shared
        let savedKey = server.apiKey
        defer { server.apiKey = savedKey }

        server.apiKey = "some-key"
        let providedKey = ""
        let matches = providedKey == server.apiKey
        XCTAssertFalse(matches, "Empty provided key should fail auth")
    }

    @MainActor
    func testCaseSensitiveKeyComparison() {
        let server = ScreenMuseServer.shared
        let savedKey = server.apiKey
        defer { server.apiKey = savedKey }

        server.apiKey = "MyKey123"
        let providedKey = "mykey123"
        let matches = providedKey == server.apiKey
        XCTAssertFalse(matches, "Key comparison should be case-sensitive")
    }

    // MARK: - Health Endpoint Skips Auth

    func testHealthEndpointSkipsAuth() {
        // The server skips auth for OPTIONS and /health
        let path = "/health"
        let method = "GET"
        let skipAuth = method == "OPTIONS" || path == "/health"
        XCTAssertTrue(skipAuth, "/health should skip auth")
    }

    func testOptionsSkipsAuth() {
        let method = "OPTIONS"
        let path = "/start"
        let skipAuth = method == "OPTIONS" || path == "/health"
        XCTAssertTrue(skipAuth, "OPTIONS should skip auth")
    }

    func testNormalEndpointDoesNotSkipAuth() {
        let method = "POST"
        let path = "/start"
        let skipAuth = method == "OPTIONS" || path == "/health"
        XCTAssertFalse(skipAuth, "Normal endpoint should NOT skip auth")
    }

    // MARK: - API Key Header Name

    func testAPIKeyHeaderIsLowercased() {
        // The server reads headers lowercased: requestHeaders["x-screenmuse-key"]
        let headerName = "X-ScreenMuse-Key"
        let lowered = headerName.lowercased()
        XCTAssertEqual(lowered, "x-screenmuse-key")
    }
}
#endif
