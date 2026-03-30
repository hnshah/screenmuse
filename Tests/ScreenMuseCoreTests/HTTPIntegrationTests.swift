#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation

/// HTTP Integration Tests for ScreenMuseServer (issue #5).
///
/// Starts a real NWListener on a dedicated test port (7825), sends actual HTTP
/// requests via URLSession, and validates response shapes and status codes.
///
/// Covers the four priority areas from issue #5:
///   1. Route dispatch  — registered routes respond; unknown routes return 404
///   2. Auth enforcement — no key → 401; valid key → passes; /health skips auth
///   3. Error consistency — all error bodies include a parseable JSON structure
///   4. Body parsing    — valid JSON, invalid JSON (graceful), oversized Content-Length → 413
///
/// NOTES:
///   • Tests that require Screen Recording permission (POST /start, POST /stop)
///     are excluded because the permission is unavailable in CI.
///   • The server singleton is reused across tests; apiKey is reset to nil in setUp.
///   • Port 7825 is used so tests never clash with a production instance on 7823.
final class HTTPIntegrationTests: XCTestCase {

    // Use a port separate from production (7823) and the existing config tests
    static let testPort: UInt16 = 7825

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        try await super.setUp()
        // Start the server first (which internally calls loadOrGenerateAPIKey()),
        // then override apiKey to nil so tests run without auth enforcement.
        // Setting apiKey before start() is insufficient because start() always
        // calls loadOrGenerateAPIKey() which re-reads ~/.screenmuse/api_key.
        try await MainActor.run {
            try ScreenMuseServer.shared.start(port: HTTPIntegrationTests.testPort)
            ScreenMuseServer.shared.apiKey = nil  // disable auth AFTER start() overwrites it
        }
        // Give NWListener time to transition .setup → .waiting → .ready (async)
        try await Task.sleep(nanoseconds: 400_000_000) // 400ms
    }

    override func tearDown() async throws {
        await MainActor.run {
            ScreenMuseServer.shared.stop()
        }
        // Wait for port to be fully released before the next test's setUp
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        try await super.tearDown()
    }

    // MARK: - HTTP Helper

    /// Send an HTTP request to the test server and return (statusCode, parsed JSON body).
    private func req(
        _ method: String,
        _ path: String,
        body: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Int, [String: Any]) {
        let url = URL(string: "http://127.0.0.1:\(HTTPIntegrationTests.testPort)\(path)")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let b = body {
            request.httpBody = b.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (statusCode, json)
    }

    // MARK: - 1. Route Dispatch

    func testHealthRouteReturns200() async throws {
        let (status, json) = try await req("GET", "/health")
        XCTAssertEqual(status, 200, "GET /health must return 200")
        XCTAssertEqual(json["ok"] as? Bool, true, "/health response must include 'ok: true'")
    }

    func testStatusRouteReturns200() async throws {
        let (status, json) = try await req("GET", "/status")
        XCTAssertEqual(status, 200, "GET /status must return 200")
        XCTAssertNotNil(json["recording"], "/status must include 'recording' field")
        XCTAssertNotNil(json["elapsed"], "/status must include 'elapsed' field")
    }

    func testVersionRouteReturns200() async throws {
        let (status, _) = try await req("GET", "/version")
        XCTAssertEqual(status, 200, "GET /version must return 200")
    }

    func testOpenAPIRouteReturns200WithSpec() async throws {
        let (status, json) = try await req("GET", "/openapi")
        XCTAssertEqual(status, 200, "GET /openapi must return 200")
        XCTAssertNotNil(json["openapi"], "OpenAPI spec must include 'openapi' version field")
        XCTAssertNotNil(json["paths"], "OpenAPI spec must include 'paths'")
    }

    func testDebugRouteReturns200() async throws {
        let (status, json) = try await req("GET", "/debug")
        XCTAssertEqual(status, 200, "GET /debug must return 200")
        XCTAssertNotNil(json["save_directory"], "/debug must include 'save_directory'")
        XCTAssertNotNil(json["server_recording"], "/debug must include 'server_recording'")
    }

    func testJobsRouteReturns200WithArray() async throws {
        let (status, json) = try await req("GET", "/jobs")
        XCTAssertEqual(status, 200, "GET /jobs must return 200")
        XCTAssertNotNil(json["jobs"], "GET /jobs must include 'jobs' array")
        XCTAssertNotNil(json["count"], "GET /jobs must include 'count'")
    }

    func testSessionsRouteReturns200() async throws {
        let (status, _) = try await req("GET", "/sessions")
        XCTAssertEqual(status, 200, "GET /sessions must return 200")
    }

    func testRecordingsRouteReturns200() async throws {
        let (status, _) = try await req("GET", "/recordings")
        XCTAssertEqual(status, 200, "GET /recordings must return 200")
    }

    func testLogsRouteReturns200() async throws {
        let (status, json) = try await req("GET", "/logs")
        XCTAssertEqual(status, 200, "GET /logs must return 200")
        XCTAssertNotNil(json["entries"], "GET /logs must include 'entries'")
    }

    // MARK: - Route Dispatch: 404 for unknown routes

    func testUnknownGETRouteReturns404() async throws {
        let (status, json) = try await req("GET", "/this-does-not-exist")
        XCTAssertEqual(status, 404, "Unknown GET route must return 404")
        XCTAssertNotNil(json["error"], "404 body must include 'error' field")
    }

    func testUnknownPOSTRouteReturns404() async throws {
        let (status, json) = try await req("POST", "/nonexistent-endpoint")
        XCTAssertEqual(status, 404, "Unknown POST route must return 404")
        XCTAssertNotNil(json["error"], "404 body must include 'error' field")
    }

    func testUnknownDELETERouteReturns404() async throws {
        let (status, _) = try await req("DELETE", "/not-a-real-resource")
        XCTAssertEqual(status, 404, "Unknown DELETE route must return 404")
    }

    // MARK: - 2. Auth Enforcement

    func testMissingKeyReturns401WhenAuthEnabled() async throws {
        await MainActor.run { ScreenMuseServer.shared.apiKey = "test-key-abc" }
        defer { Task { await MainActor.run { ScreenMuseServer.shared.apiKey = nil } } }

        let (status, json) = try await req("GET", "/status")
        XCTAssertEqual(status, 401, "Missing API key must return 401 when auth is enabled")
        XCTAssertEqual(json["code"] as? String, "INVALID_API_KEY",
                       "Auth failure must return code='INVALID_API_KEY'")
        XCTAssertNotNil(json["suggestion"], "Auth failure must include a 'suggestion' hint")
    }

    func testWrongKeyReturns401() async throws {
        await MainActor.run { ScreenMuseServer.shared.apiKey = "correct-key" }
        defer { Task { await MainActor.run { ScreenMuseServer.shared.apiKey = nil } } }

        let (status, _) = try await req("GET", "/status",
                                         headers: ["X-ScreenMuse-Key": "wrong-key"])
        XCTAssertEqual(status, 401, "Wrong API key must return 401")
    }

    func testCorrectKeyPassesAuth() async throws {
        let key = "integration-test-key-xyz"
        await MainActor.run { ScreenMuseServer.shared.apiKey = key }
        defer { Task { await MainActor.run { ScreenMuseServer.shared.apiKey = nil } } }

        let (status, _) = try await req("GET", "/status",
                                         headers: ["X-ScreenMuse-Key": key])
        XCTAssertEqual(status, 200, "Correct API key must return 200")
    }

    func testHealthEndpointSkipsAuthEnforcement() async throws {
        await MainActor.run { ScreenMuseServer.shared.apiKey = "required-key" }
        defer { Task { await MainActor.run { ScreenMuseServer.shared.apiKey = nil } } }

        // /health must respond even without key (liveness probes must never be blocked)
        let (status, json) = try await req("GET", "/health")
        XCTAssertEqual(status, 200,
                       "/health must return 200 even when auth is enabled (liveness probe)")
        XCTAssertEqual(json["ok"] as? Bool, true)
    }

    func testCORSPreflightSkipsAuth() async throws {
        await MainActor.run { ScreenMuseServer.shared.apiKey = "required-key" }
        defer { Task { await MainActor.run { ScreenMuseServer.shared.apiKey = nil } } }

        let (status, _) = try await req("OPTIONS", "/status")
        XCTAssertEqual(status, 204,
                       "OPTIONS (CORS preflight) must return 204 regardless of auth")
    }

    func testDisabledAuthAllowsAllRequests() async throws {
        // apiKey is nil (set in setUp) — all requests must pass without any header
        let (status, _) = try await req("GET", "/status")
        XCTAssertEqual(status, 200,
                       "When apiKey is nil, requests must succeed without X-ScreenMuse-Key")
    }

    // MARK: - 3. Error Response Consistency

    func testAuthErrorBodyIsConsistentJSON() async throws {
        await MainActor.run { ScreenMuseServer.shared.apiKey = "secret" }
        defer { Task { await MainActor.run { ScreenMuseServer.shared.apiKey = nil } } }

        let (_, json) = try await req("GET", "/status")
        // Both `error` and `code` must be present for consistent error handling
        XCTAssertNotNil(json["error"], "Auth error must include 'error' string")
        XCTAssertNotNil(json["code"], "Auth error must include 'code' string for programmatic handling")
    }

    func testNotFoundErrorHasErrorField() async throws {
        let (_, json) = try await req("GET", "/unknown-route-xyz-123")
        XCTAssertNotNil(json["error"], "404 response must include 'error' field")
    }

    func testJobNotFoundErrorHasCodeField() async throws {
        let (status, json) = try await req("GET", "/job/nonexistent-job-id-abc123")
        XCTAssertEqual(status, 404)
        XCTAssertEqual(json["code"] as? String, "JOB_NOT_FOUND",
                       "Job not found must return code='JOB_NOT_FOUND'")
        XCTAssertNotNil(json["error"], "Job not found must include 'error' field")
    }

    func testSessionNotFoundErrorHasCodeField() async throws {
        let (status, json) = try await req("GET", "/session/fake-session-id-does-not-exist")
        XCTAssertEqual(status, 404)
        XCTAssertEqual(json["code"] as? String, "SESSION_NOT_FOUND",
                       "Session not found must return code='SESSION_NOT_FOUND'")
    }

    func testErrorResponsesAreValidJSON() async throws {
        // Verify that 404 bodies are parseable JSON (not plain text)
        let url = URL(string: "http://127.0.0.1:\(HTTPIntegrationTests.testPort)/does-not-exist")!
        let (data, _) = try await URLSession.shared.data(from: url)
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: data),
            "Error responses must always be valid JSON (not plain text or empty)"
        )
    }

    // MARK: - 4. Body Parsing

    func testValidJSONBodyIsAccepted() async throws {
        // POST /note requires an active recording but the server must not
        // return a parse error for a well-formed JSON body
        let (status, _) = try await req("POST", "/note", body: #"{"text":"hello"}"#)
        // 400 (not recording) is fine — what we're testing is NOT 400 for JSON parse failure
        XCTAssertNotEqual(status, 500, "Valid JSON body must not cause a 500 server error")
        XCTAssertTrue(status == 400 || status == 200 || status == 409,
                      "Valid JSON should be parsed and routed; got unexpected status \(status)")
    }

    func testInvalidJSONBodyHandledGracefully() async throws {
        // The server silently treats malformed JSON as an empty body (body = {})
        // and continues routing. It must never crash (500) on bad input.
        let (status, json) = try await req("POST", "/note", body: "not-valid-json{{{{")
        XCTAssertLessThan(status, 500,
                          "Malformed JSON body must not cause a 500 server error")
        XCTAssertFalse(json.isEmpty,
                       "Server must always return a JSON body, even for malformed input")
    }

    func testEmptyBodyIsHandledGracefully() async throws {
        let (status, _) = try await req("POST", "/chapter", body: "")
        XCTAssertLessThan(status, 500, "Empty body must not cause a 500 error")
    }

    func testOversizedContentLengthReturns413() async throws {
        // Set Content-Length to 9 999 999 bytes (> maxBodySize 4 194 304).
        // The server inspects Content-Length before reading the full body.
        let url = URL(string: "http://127.0.0.1:\(HTTPIntegrationTests.testPort)/start")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("9999999", forHTTPHeaderField: "Content-Length")
        request.httpBody = #"{"name":"test"}"#.data(using: .utf8)! // small actual body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

        XCTAssertEqual(status, 413, "Content-Length > 4MB must return 413 Payload Too Large")
        XCTAssertNotNil(json["error"], "413 response must include 'error'")
        XCTAssertNotNil(json["max_bytes"],
                        "413 response must include 'max_bytes' so clients know the limit")
    }

    // MARK: - Health Response Shape (critical for ops monitoring)

    func testHealthResponseContainsAllRequiredFields() async throws {
        let (status, json) = try await req("GET", "/health")
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json["ok"],
                        "/health must include 'ok'")
        XCTAssertNotNil(json["listener"],
                        "/health must include 'listener' — used to diagnose port-bind failures")
        XCTAssertNotNil(json["port"],
                        "/health must include 'port'")
        XCTAssertNotNil(json["active_connections"],
                        "/health must include 'active_connections' — used to detect fd leaks")
        XCTAssertNotNil(json["permissions"],
                        "/health must include 'permissions'")
    }

    func testHealthListenerStateIsReady() async throws {
        // After 400ms in setUp, NWListener should have transitioned to .ready
        let (_, json) = try await req("GET", "/health")
        let listenerState = json["listener"] as? String ?? "unknown"
        XCTAssertEqual(listenerState, "ready",
                       "NWListener must be 'ready' after startup (got '\(listenerState)'). " +
                       "If flaky, increase setUp sleep duration.")
    }

    func testHealthPortMatchesConfiguredTestPort() async throws {
        let (_, json) = try await req("GET", "/health")
        let port = json["port"] as? Int ?? 0
        XCTAssertEqual(port, Int(HTTPIntegrationTests.testPort),
                       "/health 'port' must match the port passed to start(port:)")
    }

    func testHealthActiveConnectionsIsNonNegative() async throws {
        let (_, json) = try await req("GET", "/health")
        let connections = json["active_connections"] as? Int ?? -1
        XCTAssertGreaterThanOrEqual(connections, 0,
                                    "'active_connections' must be a non-negative integer")
    }
}
#endif
