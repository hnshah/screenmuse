#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation
import Network

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

    /// True when running in GitHub Actions or any CI environment.
    /// Use with `try XCTSkipIf(Self.isCI, "Screen Recording not available in CI")`
    /// for tests that require Screen Recording permission.
    private static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

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
        let (status, json, _) = try await reqFull(method, path, body: body, headers: headers)
        return (status, json)
    }

    /// Send an HTTP request and return (statusCode, parsed JSON body, HTTPURLResponse).
    private func reqFull(
        _ method: String,
        _ path: String,
        body: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Int, [String: Any], HTTPURLResponse?) {
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
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (statusCode, json, httpResponse)
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
        // URLSession always sets Content-Length to match the actual body size, so we
        // cannot send a fake oversized header through it without transferring real data.
        // Sending 4.5 MB in CI reliably times out. Solution: use NWConnection (raw TCP)
        // to send only the HTTP request headers with Content-Length: 5000000 and no body.
        // The server rejects at header-parse time and returns 413 immediately — zero
        // data transfer required.
        let port = HTTPIntegrationTests.testPort
        let rawRequest = "POST /chapter HTTP/1.1\r\n" +
            "Host: 127.0.0.1:\(port)\r\n" +
            "Content-Type: application/octet-stream\r\n" +
            "Content-Length: 5000000\r\n" +
            "\r\n"
        let requestData = rawRequest.data(using: .utf8)!

        let conn = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )

        struct TestError: Error { let message: String }

        let (statusCode, json): (Int, [String: Any]) = try await withCheckedThrowingContinuation { continuation in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: requestData, completion: .contentProcessed { sendErr in
                        if let sendErr = sendErr {
                            conn.cancel()
                            continuation.resume(throwing: sendErr)
                            return
                        }
                        conn.receive(minimumIncompleteLength: 12, maximumLength: 4096) { data, _, _, recvErr in
                            conn.cancel()
                            if let recvErr = recvErr {
                                continuation.resume(throwing: recvErr)
                                return
                            }
                            guard let data = data,
                                  let responseStr = String(data: data, encoding: .utf8) else {
                                continuation.resume(throwing: TestError(message: "No response data"))
                                return
                            }
                            // Parse status code from "HTTP/1.1 413 Payload Too Large"
                            let firstLine = responseStr.components(separatedBy: "\r\n").first ?? ""
                            let parts = firstLine.split(separator: " ", maxSplits: 2)
                            let code = parts.count >= 2 ? Int(String(parts[1])) ?? 0 : 0
                            // Parse JSON body (after blank header separator)
                            var parsedJSON: [String: Any] = [:]
                            if let sep = responseStr.range(of: "\r\n\r\n"),
                               let bodyData = String(responseStr[sep.upperBound...]).data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                                parsedJSON = obj
                            }
                            continuation.resume(returning: (code, parsedJSON))
                        }
                    })
                case .failed(let err):
                    conn.cancel()
                    continuation.resume(throwing: err)
                case .cancelled:
                    break
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }

        XCTAssertEqual(statusCode, 413, "Content-Length > 4MB must return 413 Payload Too Large")
        XCTAssertNotNil(json["error"], "413 response must include \'error\'")
        XCTAssertNotNil(json["max_bytes"], "413 response must include \'max_bytes\' so clients know the limit")
    }

    // MARK: - Health Response Shape (critical for ops monitoring)

    func testHealthResponseContainsAllRequiredFields() async throws {
        let (status, json) = try await req("GET", "/health")
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(json["ok"],
                        "/health must include 'ok'")
        XCTAssertEqual(json["status"] as? String, "ok",
                       "/health must include 'status: ok' for agent compatibility checks")
        XCTAssertNotNil(json["version"],
                        "/health must include 'version' so agents can detect compatibility")
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

    // MARK: - API Versioning (X-ScreenMuse-Version header)

    func testHealthResponseIncludesVersionHeader() async throws {
        let (status, _, httpResponse) = try await reqFull("GET", "/health")
        XCTAssertEqual(status, 200)
        let versionHeader = httpResponse?.value(forHTTPHeaderField: "X-ScreenMuse-Version")
        XCTAssertNotNil(versionHeader,
                        "All responses must include X-ScreenMuse-Version header")
        XCTAssertFalse(versionHeader?.isEmpty ?? true,
                       "X-ScreenMuse-Version must not be empty")
    }

    func testStatusResponseIncludesVersionHeader() async throws {
        let (status, _, httpResponse) = try await reqFull("GET", "/status")
        XCTAssertEqual(status, 200)
        let versionHeader = httpResponse?.value(forHTTPHeaderField: "X-ScreenMuse-Version")
        XCTAssertNotNil(versionHeader,
                        "GET /status must include X-ScreenMuse-Version header")
    }

    func testNotFoundResponseIncludesVersionHeader() async throws {
        let (status, _, httpResponse) = try await reqFull("GET", "/nonexistent-route")
        XCTAssertEqual(status, 404)
        let versionHeader = httpResponse?.value(forHTTPHeaderField: "X-ScreenMuse-Version")
        XCTAssertNotNil(versionHeader,
                        "Even error responses must include X-ScreenMuse-Version header")
    }

    func testVersionHeaderMatchesHealthBodyVersion() async throws {
        let (_, json, httpResponse) = try await reqFull("GET", "/health")
        let headerVersion = httpResponse?.value(forHTTPHeaderField: "X-ScreenMuse-Version")
        let bodyVersion = json["version"] as? String
        XCTAssertNotNil(headerVersion)
        XCTAssertNotNil(bodyVersion)
        XCTAssertEqual(headerVersion, bodyVersion,
                       "X-ScreenMuse-Version header must match the 'version' field in /health body")
    }

    func testExposeHeadersIncludesVersionHeader() async throws {
        let (_, _, httpResponse) = try await reqFull("GET", "/health")
        let exposeHeaders = httpResponse?.value(forHTTPHeaderField: "Access-Control-Expose-Headers") ?? ""
        XCTAssertTrue(exposeHeaders.contains("X-ScreenMuse-Version"),
                      "Access-Control-Expose-Headers must include X-ScreenMuse-Version so browsers can read it")
    }
}
#endif

