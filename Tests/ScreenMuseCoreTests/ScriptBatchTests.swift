#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation

/// Integration tests for /script and /script/batch endpoints (issue #21).
///
/// Starts a real NWListener on a dedicated test port (7826), sends actual HTTP
/// requests via URLSession, and validates response shapes, status codes, and
/// error handling — including the double-append bug fix for sanitization errors.
///
/// NOTES:
///   • Actions that require Screen Recording permission (start, stop) are NOT
///     exercised here because the permission is unavailable in CI. Instead,
///     tests focus on input validation, error paths, and response structure.
///   • Port 7826 avoids clashing with production (7823) or HTTPIntegrationTests (7825).
final class ScriptBatchTests: XCTestCase {

    static let testPort: UInt16 = 7826

    /// True when running in GitHub Actions or any CI environment.
    /// Use with `try XCTSkipIf(Self.isCI, "Screen Recording not available in CI")`
    /// for tests that require Screen Recording permission.
    private static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    // MARK: - setUp / tearDown

    override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run {
            // Start first (loadOrGenerateAPIKey runs inside start()), then disable auth.
            // Setting apiKey = nil before start() is ineffective because start() always
            // calls loadOrGenerateAPIKey() which re-reads ~/.screenmuse/api_key from disk.
            try ScreenMuseServer.shared.start(port: ScriptBatchTests.testPort)
            ScreenMuseServer.shared.apiKey = nil  // disable auth AFTER start() overwrites it
        }
        try await Task.sleep(nanoseconds: 400_000_000) // 400ms for NWListener
    }

    override func tearDown() async throws {
        await MainActor.run {
            ScreenMuseServer.shared.stop()
        }
        try await Task.sleep(nanoseconds: 200_000_000) // wait for port release
        try await super.tearDown()
    }

    // MARK: - HTTP Helper

    private func req(
        _ method: String,
        _ path: String,
        json: Any
    ) async throws -> (Int, [String: Any]) {
        let url = URL(string: "http://127.0.0.1:\(ScriptBatchTests.testPort)\(path)")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (statusCode, body)
    }

    // MARK: - /script tests

    func testScriptEmptyCommandsReturns400() async throws {
        let (status, json) = try await req("POST", "/script", json: ["commands": []])
        XCTAssertEqual(status, 400, "Empty commands array must return 400")
        XCTAssertNotNil(json["error"], "Error response must include 'error' field")
    }

    func testScriptMissingCommandsReturns400() async throws {
        let (status, json) = try await req("POST", "/script", json: ["foo": "bar"])
        XCTAssertEqual(status, 400, "Missing commands key must return 400")
        XCTAssertNotNil(json["error"])
    }

    func testScriptHighlightReturnsOK() async throws {
        // "highlight" doesn't require recording permission
        let (status, json) = try await req("POST", "/script", json: [
            "commands": [["action": "highlight"]]
        ])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["steps_run"] as? Int, 1)
        let steps = json["steps"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.count, 1, "Must have exactly 1 step")
        XCTAssertEqual(steps[0]["ok"] as? Bool, true)
        XCTAssertEqual(steps[0]["action"] as? String, "highlight")
    }

    func testScriptMultipleHighlightsAndSleep() async throws {
        let (status, json) = try await req("POST", "/script", json: [
            "commands": [
                ["action": "highlight"],
                ["sleep": 0.01],
                ["action": "highlight"]
            ]
        ])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["steps_run"] as? Int, 3)
        let steps = json["steps"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.count, 3)
        // All steps should be ok
        for step in steps {
            XCTAssertEqual(step["ok"] as? Bool, true)
        }
    }

    func testScriptUnknownActionReturnsError() async throws {
        let (status, json) = try await req("POST", "/script", json: [
            "commands": [["action": "execute_shell"]]
        ])
        // Unknown action doesn't throw, so script completes with 200 but step has ok=false
        XCTAssertEqual(status, 200)
        let steps = json["steps"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0]["ok"] as? Bool, false)
        XCTAssertNotNil(steps[0]["error"])
        let errorStr = steps[0]["error"] as? String ?? ""
        XCTAssertTrue(errorStr.contains("Unknown action"), "Error must mention unknown action")
        XCTAssertTrue(errorStr.contains("does not execute arbitrary scripts"),
                      "Error must include security note")
    }

    func testScriptSanitizationErrorDoesNotDuplicateStep() async throws {
        // A name > 500 chars should trigger sanitization failure.
        // Before the fix, this would appear TWICE in the steps array.
        let longName = String(repeating: "A", count: 501)
        let (status, json) = try await req("POST", "/script", json: [
            "commands": [["action": "chapter", "name": longName]]
        ])
        // Script completes (no throw), so 200
        XCTAssertEqual(status, 200)
        let steps = json["steps"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.count, 1,
                       "Sanitization error must produce exactly 1 step entry, not 2 (double-append bug)")
        XCTAssertEqual(steps[0]["ok"] as? Bool, false)
        let errorStr = steps[0]["error"] as? String ?? ""
        XCTAssertTrue(errorStr.contains("maximum length"),
                      "Error should mention max length constraint")
    }

    func testScriptStartSanitizationErrorDoesNotDuplicate() async throws {
        let longName = String(repeating: "X", count: 501)
        let (status, json) = try await req("POST", "/script", json: [
            "commands": [["action": "start", "name": longName]]
        ])
        XCTAssertEqual(status, 200)
        let steps = json["steps"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.count, 1,
                       "Start action sanitization error must produce exactly 1 step (double-append fix)")
        XCTAssertEqual(steps[0]["ok"] as? Bool, false)
    }

    func testScriptNoteSanitizationErrorDoesNotDuplicate() async throws {
        let longText = String(repeating: "Z", count: 501)
        let (status, json) = try await req("POST", "/script", json: [
            "commands": [["action": "note", "text": longText]]
        ])
        XCTAssertEqual(status, 200)
        let steps = json["steps"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.count, 1,
                       "Note action sanitization error must produce exactly 1 step (double-append fix)")
        XCTAssertEqual(steps[0]["ok"] as? Bool, false)
    }

    func testScriptResponseIncludesErrorKeyAsNull() async throws {
        // On success, "error" should be null/nil
        let (status, json) = try await req("POST", "/script", json: [
            "commands": [["action": "highlight"]]
        ])
        XCTAssertEqual(status, 200)
        // The key "error" must exist in the response (even if null)
        XCTAssertTrue(json.keys.contains("error"), "Response must include 'error' key even on success")
    }

    // MARK: - /script/batch tests

    func testBatchEmptyScriptsReturns400() async throws {
        let (status, json) = try await req("POST", "/script/batch", json: ["scripts": []])
        XCTAssertEqual(status, 400, "Empty scripts array must return 400")
        XCTAssertNotNil(json["error"])
    }

    func testBatchMissingScriptsKeyReturns400() async throws {
        let (status, json) = try await req("POST", "/script/batch", json: ["foo": "bar"])
        XCTAssertEqual(status, 400, "Missing scripts key must return 400")
        XCTAssertNotNil(json["error"])
    }

    func testBatchHappyPathTwoScripts() async throws {
        let (status, json) = try await req("POST", "/script/batch", json: [
            "scripts": [
                ["name": "setup", "commands": [["action": "highlight"]]],
                ["name": "actions", "commands": [["action": "highlight"], ["sleep": 0.01]]]
            ]
        ])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["scripts_run"] as? Int, 2)
        let scripts = json["scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(scripts[0]["name"] as? String, "setup")
        XCTAssertEqual(scripts[0]["ok"] as? Bool, true)
        XCTAssertEqual(scripts[0]["steps_run"] as? Int, 1)
        XCTAssertEqual(scripts[1]["name"] as? String, "actions")
        XCTAssertEqual(scripts[1]["ok"] as? Bool, true)
        XCTAssertEqual(scripts[1]["steps_run"] as? Int, 2)
    }

    func testBatchMissingCommandsInScriptReturnsError() async throws {
        let (status, json) = try await req("POST", "/script/batch", json: [
            "scripts": [
                ["name": "broken"]  // no "commands" key
            ]
        ])
        XCTAssertEqual(status, 500, "Batch with missing commands should return 500")
        XCTAssertEqual(json["ok"] as? Bool, false)
        let scripts = json["scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts[0]["ok"] as? Bool, false)
        let errorStr = scripts[0]["error"] as? String ?? ""
        XCTAssertTrue(errorStr.contains("missing or empty"), "Error should mention missing commands")
    }

    func testBatchEmptyCommandsInScriptReturnsError() async throws {
        let (status, json) = try await req("POST", "/script/batch", json: [
            "scripts": [
                ["name": "empty-cmds", "commands": []]
            ]
        ])
        XCTAssertEqual(status, 500)
        XCTAssertEqual(json["ok"] as? Bool, false)
        let scripts = json["scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(scripts[0]["ok"] as? Bool, false)
    }

    func testBatchContinueOnErrorFalseStopsOnFirstFailure() async throws {
        // Default continue_on_error is false.
        // First script has missing commands → fails. Second script should NOT run.
        let (status, json) = try await req("POST", "/script/batch", json: [
            "scripts": [
                ["name": "broken"],  // no commands → fails
                ["name": "should-not-run", "commands": [["action": "highlight"]]]
            ]
        ])
        XCTAssertEqual(status, 500)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["scripts_run"] as? Int, 1,
                       "With continue_on_error=false, must stop after first failure")
        let scripts = json["scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(scripts.count, 1, "Only the failed script should appear in results")
    }

    func testBatchContinueOnErrorTrueContinuesPastFailures() async throws {
        let (status, json) = try await req("POST", "/script/batch", json: [
            "continue_on_error": true,
            "scripts": [
                ["name": "broken"],  // no commands → fails
                ["name": "should-run", "commands": [["action": "highlight"]]]
            ]
        ])
        XCTAssertEqual(status, 500, "Batch with any failure returns 500")
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["scripts_run"] as? Int, 2,
                       "With continue_on_error=true, must run all scripts")
        let scripts = json["scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(scripts[0]["ok"] as? Bool, false, "First script must fail")
        XCTAssertEqual(scripts[1]["ok"] as? Bool, true, "Second script must succeed")
    }

    func testBatchSanitizationErrorDoesNotDuplicateStep() async throws {
        let longName = String(repeating: "B", count: 501)
        let (status, json) = try await req("POST", "/script/batch", json: [
            "scripts": [
                ["name": "sanitize-test", "commands": [["action": "chapter", "name": longName]]]
            ]
        ])
        // The script completes (chapter fails but no throw), so the script itself is ok=true
        // but the step has ok=false
        XCTAssertEqual(status, 200)
        let scripts = json["scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(scripts.count, 1)
        let steps = scripts[0]["steps"] as? [[String: Any]] ?? []
        XCTAssertEqual(steps.count, 1,
                       "Batch: sanitization error must produce exactly 1 step, not 2 (double-append fix)")
        XCTAssertEqual(steps[0]["ok"] as? Bool, false)
    }

    func testBatchScriptNameDefaultsWhenOmitted() async throws {
        let (status, json) = try await req("POST", "/script/batch", json: [
            "scripts": [
                ["commands": [["action": "highlight"]]]  // no "name" key
            ]
        ])
        XCTAssertEqual(status, 200)
        let scripts = json["scripts"] as? [[String: Any]] ?? []
        XCTAssertEqual(scripts.count, 1)
        let name = scripts[0]["name"] as? String ?? ""
        XCTAssertEqual(name, "script_1", "Omitted name should default to 'script_<index>'")
    }

    func testBatchResponseShape() async throws {
        let (status, json) = try await req("POST", "/script/batch", json: [
            "scripts": [
                ["name": "s1", "commands": [["action": "highlight"]]]
            ]
        ])
        XCTAssertEqual(status, 200)
        // Verify top-level keys
        XCTAssertNotNil(json["ok"], "Response must include 'ok'")
        XCTAssertNotNil(json["scripts_run"], "Response must include 'scripts_run'")
        XCTAssertNotNil(json["scripts"], "Response must include 'scripts'")
        // Verify per-script keys
        let scripts = json["scripts"] as? [[String: Any]] ?? []
        let script = scripts[0]
        XCTAssertNotNil(script["name"], "Script result must include 'name'")
        XCTAssertNotNil(script["ok"], "Script result must include 'ok'")
        XCTAssertNotNil(script["steps_run"], "Script result must include 'steps_run'")
        XCTAssertNotNil(script["steps"], "Script result must include 'steps'")
    }
}
#endif
