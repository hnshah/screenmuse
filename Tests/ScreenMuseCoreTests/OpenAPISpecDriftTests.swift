#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// CI drift guard for the OpenAPI spec.
///
/// Problem: `OpenAPISpec.swift` is a static JSON string. New routes added to
/// the switch statement in `ScreenMuseServer.swift` won't automatically appear
/// in the spec — they silently drift. Claude Desktop, Cursor, Postman, and
/// agents use `GET /openapi` as the machine-readable interface, so drift breaks
/// external integrations without any compile-time warning.
///
/// This test suite:
///   1. Verifies the JSON string is valid and parses correctly.
///   2. Extracts the `paths` dictionary from the spec.
///   3. Checks that a known-good set of routes is present (the authoritative
///      route table extracted from `ScreenMuseServer.swift` at the time this
///      test was written — update `expectedPaths` when you add new routes).
///
/// When to update this file:
///   - Add to `expectedPaths` whenever you add a new endpoint.
///   - Parameterised paths like `/session/{id}` are listed without `{id}`.
///
/// See: https://github.com/hnshah/screenmuse/issues/47
final class OpenAPISpecDriftTests: XCTestCase {

    // MARK: - Known routes from ScreenMuseServer.swift route table

    /// Static routes from the switch statement (excluding wildcard prefixes).
    /// Format: (method, path) — method is the HTTP verb in lower-case as it
    /// appears in the OpenAPI path item object.
    private let expectedPaths: [String] = [
        // Recording lifecycle
        "/start",
        "/stop",
        "/pause",
        "/resume",
        "/record",
        // Annotations
        "/chapter",
        "/highlight",
        "/note",
        // Capture
        "/screenshot",
        "/frame",
        "/frames",
        "/thumbnail",
        "/ocr",
        // Export / transform
        "/export",
        "/trim",
        "/speedramp",
        "/concat",
        "/crop",
        // Scripting
        "/script",
        "/script/batch",
        "/validate",
        "/annotate",
        // System / query
        "/health",
        "/status",
        "/debug",
        "/logs",
        "/report",
        "/version",
        "/openapi",
        "/recordings",
        "/recording",       // DELETE /recording
        // Window management
        "/windows",
        "/window/focus",
        "/window/position",
        "/window/hide-others",
        "/start/pip",
        // System utilities
        "/system/clipboard",
        "/system/active-window",
        "/system/running-apps",
        // Streaming
        "/stream",
        "/stream/status",
        // Timeline & jobs
        "/timeline",
        "/jobs",
        "/sessions",
        // Upload
        "/upload/icloud",
        // Browser (Playwright) recording
        "/browser",
        "/browser/install",
        "/browser/status",
    ]

    // MARK: - Helpers

    private func parsedSpec() throws -> [String: Any] {
        guard let data = OpenAPISpec.json.data(using: .utf8) else {
            XCTFail("OpenAPISpec.json could not be encoded as UTF-8 data")
            throw SpecError.invalidEncoding
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("OpenAPISpec.json is not valid JSON — JSONSerialization failed")
            throw SpecError.invalidJSON
        }
        return obj
    }

    private enum SpecError: Error {
        case invalidEncoding
        case invalidJSON
        case missingPathsKey
    }

    // MARK: - Tests

    /// The spec must be valid JSON.
    func testSpecIsValidJSON() throws {
        _ = try parsedSpec()
    }

    /// Top-level OpenAPI required fields must be present.
    func testSpecHasRequiredTopLevelKeys() throws {
        let spec = try parsedSpec()
        XCTAssertNotNil(spec["openapi"], "Missing required 'openapi' key")
        XCTAssertNotNil(spec["info"],    "Missing required 'info' key")
        XCTAssertNotNil(spec["paths"],   "Missing required 'paths' key")
    }

    /// The `paths` value must be a non-empty dictionary.
    func testSpecPathsIsNonEmptyDictionary() throws {
        let spec = try parsedSpec()
        guard let paths = spec["paths"] as? [String: Any] else {
            XCTFail("'paths' key is missing or not a dictionary")
            return
        }
        XCTAssertGreaterThan(paths.count, 0, "'paths' dictionary is empty")
    }

    /// Every expected route from the server switch table must appear in
    /// the spec's `paths` dictionary.
    ///
    /// If this test fails: add the missing path to `OpenAPISpec.swift`.
    func testAllKnownRoutesAreDocumentedInSpec() throws {
        let spec = try parsedSpec()
        guard let paths = spec["paths"] as? [String: Any] else {
            XCTFail("'paths' key is missing or not a dictionary")
            return
        }

        var missing: [String] = []
        for path in expectedPaths {
            if paths[path] == nil {
                missing.append(path)
            }
        }

        XCTAssertTrue(
            missing.isEmpty,
            "The following routes exist in ScreenMuseServer.swift but are MISSING from OpenAPISpec.json — add them to maintain spec/code parity:\n  \(missing.joined(separator: "\n  "))"
        )
    }

    /// Parameterised routes (wildcard prefixes in the server) must have a
    /// representative path entry in the spec.
    ///
    /// Current wildcards:
    ///   GET  /job/{id}       → handled by `cleanPath.hasPrefix("/job/")`
    ///   GET  /session/{id}   → handled by `cleanPath.hasPrefix("/session/")`
    ///   DELETE /session/{id} → handled by `cleanPath.hasPrefix("/session/")`
    func testParameterisedRoutesAreDocumentedInSpec() throws {
        let spec = try parsedSpec()
        guard let paths = spec["paths"] as? [String: Any] else {
            XCTFail("'paths' key missing")
            return
        }

        // OpenAPI uses {param} notation for path parameters
        let paramPaths = ["/job/{id}", "/session/{id}"]
        var missing: [String] = []
        for path in paramPaths {
            if paths[path] == nil {
                missing.append(path)
            }
        }

        XCTAssertTrue(
            missing.isEmpty,
            "Parameterised routes missing from OpenAPISpec.json (add them with {id} OpenAPI notation):\n  \(missing.joined(separator: "\n  "))"
        )
    }

    /// The spec version string must be a non-empty string.
    func testSpecInfoVersionIsPresent() throws {
        let spec = try parsedSpec()
        guard let info = spec["info"] as? [String: Any],
              let version = info["version"] as? String,
              !version.isEmpty else {
            XCTFail("'info.version' is missing or empty")
            return
        }
        // Version should look like "1.x" or "2.x" — basic sanity check
        XCTAssertTrue(version.contains("."), "info.version '\(version)' doesn't look like a semver (missing '.')")
    }
}
#endif
