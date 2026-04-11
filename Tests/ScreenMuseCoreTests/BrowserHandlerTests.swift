#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation
import Network

/// Tests for POST /browser, /browser/install, /browser/status.
///
/// These tests exercise validation logic, the runner installer's
/// filesystem + PATH lookup, and the BrowserRecorder line-protocol
/// parser. They do NOT spawn Node or Chromium — that lives behind an
/// env-var-gated integration test so CI machines without Node still pass.
final class BrowserHandlerTests: XCTestCase {

    // MARK: - validateBrowserRequest

    @MainActor
    func testValidateRejectsMissingURL() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "duration_seconds": 5
        ])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["code"] as? String, "MISSING_URL")
    }

    @MainActor
    func testValidateRejectsInvalidURLScheme() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "javascript:alert(1)",
            "duration_seconds": 5
        ])
        XCTAssertEqual(result?["code"] as? String, "INVALID_URL")
    }

    @MainActor
    func testValidateAcceptsHTTP() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "http://localhost:3000",
            "duration_seconds": 5
        ])
        XCTAssertNil(result)
    }

    @MainActor
    func testValidateAcceptsHTTPS() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5
        ])
        XCTAssertNil(result)
    }

    @MainActor
    func testValidateAcceptsFileURL() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "file:///tmp/test.html",
            "duration_seconds": 5
        ])
        XCTAssertNil(result)
    }

    @MainActor
    func testValidateRejectsMissingDuration() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com"
        ])
        XCTAssertEqual(result?["code"] as? String, "INVALID_DURATION")
    }

    @MainActor
    func testValidateRejectsNegativeDuration() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": -1
        ])
        XCTAssertEqual(result?["code"] as? String, "INVALID_DURATION")
    }

    @MainActor
    func testValidateRejectsDurationTooLarge() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 9999
        ])
        XCTAssertEqual(result?["code"] as? String, "INVALID_DURATION")
    }

    @MainActor
    func testValidateAcceptsMaxDuration() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 600
        ])
        XCTAssertNil(result)
    }

    @MainActor
    func testValidateRejectsHeadless() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "headless": true
        ])
        XCTAssertEqual(result?["code"] as? String, "HEADLESS_NOT_SUPPORTED")
    }

    @MainActor
    func testValidateAcceptsHeadlessFalse() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "headless": false
        ])
        XCTAssertNil(result)
    }

    @MainActor
    func testValidateRejectsWidthOutOfRange() {
        let tooSmall = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "width": 100
        ])
        XCTAssertEqual(tooSmall?["code"] as? String, "INVALID_WIDTH")

        let tooBig = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "width": 5000
        ])
        XCTAssertEqual(tooBig?["code"] as? String, "INVALID_WIDTH")
    }

    @MainActor
    func testValidateRejectsHeightOutOfRange() {
        let tooSmall = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "height": 100
        ])
        XCTAssertEqual(tooSmall?["code"] as? String, "INVALID_HEIGHT")
    }

    // MARK: - makeBrowserConfig

    @MainActor
    func testMakeBrowserConfigDefaults() {
        let cfg = ScreenMuseServer.shared.makeBrowserConfig(body: [
            "url": "https://example.com",
            "duration_seconds": 7
        ])
        XCTAssertEqual(cfg.url, "https://example.com")
        XCTAssertEqual(cfg.durationMs, 7000)
        XCTAssertEqual(cfg.width, 1280)
        XCTAssertEqual(cfg.height, 720)
        XCTAssertNil(cfg.script)
    }

    @MainActor
    func testMakeBrowserConfigScriptPassthrough() {
        let cfg = ScreenMuseServer.shared.makeBrowserConfig(body: [
            "url": "https://example.com",
            "duration_seconds": 3,
            "script": "await page.click('#btn')",
            "width": 1920,
            "height": 1080
        ])
        XCTAssertEqual(cfg.script, "await page.click('#btn')")
        XCTAssertEqual(cfg.width, 1920)
        XCTAssertEqual(cfg.height, 1080)
        XCTAssertEqual(cfg.durationMs, 3000)
    }

    @MainActor
    func testMakeBrowserConfigDurationFallback() {
        // Support the `duration` alias alongside `duration_seconds`.
        let cfg = ScreenMuseServer.shared.makeBrowserConfig(body: [
            "url": "https://example.com",
            "duration": 10
        ])
        XCTAssertEqual(cfg.durationMs, 10_000)
    }

    // MARK: - v2 validation (cookies, storage_state, wait_for, extra_args)

    @MainActor
    func testValidateRejectsUnknownWaitFor() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "wait_for": "eventually"
        ])
        XCTAssertEqual(result?["code"] as? String, "INVALID_WAIT_FOR")
    }

    @MainActor
    func testValidateAcceptsAllValidWaitFor() {
        for condition in ["load", "domcontentloaded", "networkidle", "commit"] {
            let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
                "url": "https://example.com",
                "duration_seconds": 5,
                "wait_for": condition
            ])
            XCTAssertNil(result, "wait_for=\(condition) should validate")
        }
    }

    @MainActor
    func testValidateRejectsMissingStorageStatePath() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "storage_state_path": "/tmp/does-not-exist-\(UUID().uuidString).json"
        ])
        XCTAssertEqual(result?["code"] as? String, "STORAGE_STATE_NOT_FOUND")
    }

    @MainActor
    func testValidateAcceptsExistingStorageState() throws {
        let tempFile = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("sm-test-storage-\(UUID().uuidString).json")
        try #"{"cookies":[],"origins":[]}"#.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "storage_state_path": tempFile.path
        ])
        XCTAssertNil(result)
    }

    @MainActor
    func testValidateRejectsCookiesNotArray() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "cookies": "not-an-array"
        ])
        XCTAssertEqual(result?["code"] as? String, "INVALID_COOKIES")
    }

    @MainActor
    func testValidateRejectsCookieWithoutName() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "cookies": [["value": "v"]]
        ])
        XCTAssertEqual(result?["code"] as? String, "INVALID_COOKIE")
    }

    @MainActor
    func testValidateRejectsCookieWithoutValue() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "cookies": [["name": "session"]]
        ])
        XCTAssertEqual(result?["code"] as? String, "INVALID_COOKIE")
    }

    @MainActor
    func testValidateAcceptsWellFormedCookies() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "cookies": [
                ["name": "session", "value": "abc", "domain": ".example.com"],
                ["name": "csrf", "value": "xyz"]
            ]
        ])
        XCTAssertNil(result)
    }

    @MainActor
    func testValidateRejectsExtraArgsNotStringArray() {
        let result = ScreenMuseServer.shared.validateBrowserRequest(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "extra_args": "single-string"
        ])
        XCTAssertEqual(result?["code"] as? String, "INVALID_EXTRA_ARGS")
    }

    // MARK: - parseWaitFor

    func testParseWaitForDefaultsToLoad() {
        XCTAssertEqual(ScreenMuseServer.parseWaitFor(nil), .load)
        XCTAssertEqual(ScreenMuseServer.parseWaitFor(""), .load)
        XCTAssertEqual(ScreenMuseServer.parseWaitFor("load"), .load)
        XCTAssertEqual(ScreenMuseServer.parseWaitFor("not-a-real-condition"), .load)
    }

    func testParseWaitForMapsAllKnownValues() {
        XCTAssertEqual(ScreenMuseServer.parseWaitFor("domcontentloaded"), .domcontentloaded)
        XCTAssertEqual(ScreenMuseServer.parseWaitFor("NetworkIdle"), .networkidle,
                       "wait_for parsing must be case-insensitive")
        XCTAssertEqual(ScreenMuseServer.parseWaitFor("commit"), .commit)
    }

    // MARK: - parseCookie

    func testParseCookieRejectsEmptyName() {
        XCTAssertNil(ScreenMuseServer.parseCookie(["name": "", "value": "x"]))
    }

    func testParseCookieRejectsMissingValue() {
        XCTAssertNil(ScreenMuseServer.parseCookie(["name": "session"]))
    }

    func testParseCookieAcceptsNumericValue() {
        let cookie = ScreenMuseServer.parseCookie(["name": "count", "value": 42])
        XCTAssertEqual(cookie?.value, "42",
                       "numeric cookie values must be stringified for Playwright compatibility")
    }

    func testParseCookiePassesThroughOptionalFields() {
        let cookie = ScreenMuseServer.parseCookie([
            "name": "session",
            "value": "abc",
            "domain": ".example.com",
            "path": "/",
            "httpOnly": true,
            "secure": true,
            "sameSite": "Lax"
        ])
        XCTAssertEqual(cookie?.domain, ".example.com")
        XCTAssertEqual(cookie?.path, "/")
        XCTAssertEqual(cookie?.httpOnly, true)
        XCTAssertEqual(cookie?.secure, true)
        XCTAssertEqual(cookie?.sameSite, "Lax")
    }

    // MARK: - makeBrowserConfig v2 fields

    @MainActor
    func testMakeBrowserConfigPassesThroughV2Fields() {
        let cfg = ScreenMuseServer.shared.makeBrowserConfig(body: [
            "url": "https://example.com",
            "duration_seconds": 5,
            "user_agent": "ScreenMuse/1.1",
            "locale": "en-US",
            "timezone_id": "America/Los_Angeles",
            "wait_for": "networkidle",
            "extra_args": ["--disable-web-security"],
            "cookies": [["name": "s", "value": "x"]]
        ])
        XCTAssertEqual(cfg.userAgent, "ScreenMuse/1.1")
        XCTAssertEqual(cfg.localeHint, "en-US")
        XCTAssertEqual(cfg.timezoneHint, "America/Los_Angeles")
        XCTAssertEqual(cfg.waitFor, .networkidle)
        XCTAssertEqual(cfg.extraArgs, ["--disable-web-security"])
        XCTAssertEqual(cfg.cookies.count, 1)
        XCTAssertEqual(cfg.cookies.first?.name, "s")
    }

    // MARK: - BrowserRecorder.Config JSON encoding

    func testConfigAsJSONIncludesRequiredFields() throws {
        let cfg = BrowserRecorder.Config(
            url: "https://example.com",
            script: "await page.waitForTimeout(100);",
            durationMs: 3000,
            width: 1024,
            height: 768
        )
        let json = try cfg.asJSON()
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["url"] as? String, "https://example.com")
        XCTAssertEqual(obj["duration_ms"] as? Int, 3000)
        XCTAssertEqual(obj["width"] as? Int, 1024)
        XCTAssertEqual(obj["height"] as? Int, 768)
        XCTAssertEqual(obj["script"] as? String, "await page.waitForTimeout(100);")
    }

    func testConfigAsJSONOmitsNilScript() throws {
        let cfg = BrowserRecorder.Config(url: "https://x", durationMs: 1000)
        let json = try cfg.asJSON()
        XCTAssertFalse(json.contains("\"script\""),
                       "script key must be omitted when nil to keep the runner JSON minimal")
    }

    func testConfigAsJSONEmitsWaitForEvenWhenDefault() throws {
        // wait_for is always emitted so the runner can tell it came from
        // a v2 caller (explicit load) vs a v1 caller (absent).
        let cfg = BrowserRecorder.Config(url: "https://x", durationMs: 1000)
        let json = try cfg.asJSON()
        XCTAssertTrue(json.contains("\"wait_for\":\"load\""))
    }

    func testConfigAsJSONOmitsEmptyV2Fields() throws {
        let cfg = BrowserRecorder.Config(url: "https://x", durationMs: 1000)
        let json = try cfg.asJSON()
        XCTAssertFalse(json.contains("\"cookies\""))
        XCTAssertFalse(json.contains("\"storage_state_path\""))
        XCTAssertFalse(json.contains("\"user_agent\""))
        XCTAssertFalse(json.contains("\"extra_args\""))
        XCTAssertFalse(json.contains("\"locale\""))
        XCTAssertFalse(json.contains("\"timezone_id\""))
    }

    func testConfigAsJSONEmitsV2Fields() throws {
        let cfg = BrowserRecorder.Config(
            url: "https://x",
            durationMs: 1000,
            cookies: [BrowserRecorder.Config.Cookie(name: "s", value: "v", domain: ".x")],
            storageStatePath: "/tmp/auth.json",
            userAgent: "ua",
            waitFor: .networkidle,
            extraArgs: ["--foo"],
            localeHint: "en-US",
            timezoneHint: "UTC"
        )
        let json = try cfg.asJSON()
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["storage_state_path"] as? String, "/tmp/auth.json")
        XCTAssertEqual(obj["user_agent"] as? String, "ua")
        XCTAssertEqual(obj["wait_for"] as? String, "networkidle")
        XCTAssertEqual(obj["locale"] as? String, "en-US")
        XCTAssertEqual(obj["timezone_id"] as? String, "UTC")
        let cookies = obj["cookies"] as? [[String: Any]]
        XCTAssertEqual(cookies?.count, 1)
        XCTAssertEqual(cookies?.first?["name"] as? String, "s")
        let args = obj["extra_args"] as? [String]
        XCTAssertEqual(args, ["--foo"])
    }

    // MARK: - NodeRunnerInstaller

    func testInstallerDefaultsToHomeDirectory() {
        let installer = NodeRunnerInstaller()
        let expected = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".screenmuse/playwright-runner", isDirectory: true)
        XCTAssertEqual(installer.runnerDirectory.path, expected.path)
    }

    func testInstallerStatusOnEmptyDirectory() throws {
        // Point the installer at a throwaway temp dir to keep the test
        // hermetic (no interference with the user's real runner install).
        let tempDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("screenmuse-test-\(UUID().uuidString)", isDirectory: true)
        let installer = NodeRunnerInstaller(runnerDirectory: tempDir)
        let status = installer.status()
        XCTAssertFalse(status.runnerScriptExists)
        XCTAssertFalse(status.playwrightInstalled)
        XCTAssertFalse(status.isReady)
    }

    func testInstallerStatusDetectsExistingRunner() throws {
        let tempDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("screenmuse-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runnerFile = tempDir.appendingPathComponent(RunnerScript.filename)
        try RunnerScript.rendered().write(to: runnerFile, atomically: true, encoding: .utf8)

        let installer = NodeRunnerInstaller(runnerDirectory: tempDir)
        let status = installer.status()
        XCTAssertTrue(status.runnerScriptExists)
        XCTAssertEqual(status.runnerScriptVersion, RunnerScript.version)
    }

    func testInstallerExtractVersionFromHeader() {
        let src = "// header line (generated by NodeRunnerInstaller, version 42).\nconsole.log('hi');"
        XCTAssertEqual(NodeRunnerInstaller.extractVersion(from: src), "42")
    }

    func testInstallerExtractVersionReturnsNilForUnstampedSource() {
        let src = "// no version header anywhere in this source"
        XCTAssertNil(NodeRunnerInstaller.extractVersion(from: src))
    }

    func testInstallerFindOnPathFindsSh() {
        // `/bin/sh` exists on every macOS system, so this is a reliable probe.
        XCTAssertNotNil(NodeRunnerInstaller.findOnPath("sh"))
    }

    func testInstallerFindOnPathReturnsNilForNonsense() {
        XCTAssertNil(NodeRunnerInstaller.findOnPath("absolutely-not-a-real-binary-\(UUID().uuidString)"))
    }

    // MARK: - Runner script integrity

    func testRunnerScriptContainsVersionStamp() {
        let rendered = RunnerScript.rendered()
        XCTAssertTrue(rendered.contains("version \(RunnerScript.version)"),
                      "rendered runner must embed the current version stamp")
        XCTAssertFalse(rendered.contains("__SM_VERSION__"),
                       "version placeholder must be substituted at render time")
    }

    func testRunnerScriptEmitsSMReady() {
        // Sanity check that the protocol contract is preserved in the source.
        XCTAssertTrue(RunnerScript.source.contains("SM:"))
        XCTAssertTrue(RunnerScript.source.contains("READY"))
        XCTAssertTrue(RunnerScript.source.contains("DONE"))
    }

    func testRunnerPackageJSONPinsPlaywright() throws {
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(RunnerScript.packageJSON.utf8)) as? [String: Any]
        )
        let deps = obj["dependencies"] as? [String: String]
        XCTAssertNotNil(deps?["playwright"],
                        "package.json must pin a Playwright version so upstream changes can't break runs")
    }

    // MARK: - EventBox

    func testEventBoxResolveWakesAllWaiters() async throws {
        let box = EventBox<Int>()
        async let a = box.wait(timeout: 2)
        async let b = box.wait(timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        box.resolve(42)
        let (x, y) = try await (a, b)
        XCTAssertEqual(x, 42)
        XCTAssertEqual(y, 42)
    }

    func testEventBoxFailPropagatesError() async {
        struct TestError: Error {}
        let box = EventBox<String>()
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            box.fail(TestError())
        }
        do {
            _ = try await box.wait(timeout: 2)
            XCTFail("expected wait to throw")
        } catch is TestError {
            // expected
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testEventBoxTimeoutFiresWhenNoResolve() async {
        let box = EventBox<String>()
        do {
            _ = try await box.wait(timeout: 0.1)
            XCTFail("expected wait to time out")
        } catch EventBox<String>.TimeoutError.timedOut {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEventBoxResolveBeforeWaitStillReturns() async throws {
        let box = EventBox<Int>()
        box.resolve(7)
        let v = try await box.wait(timeout: 1)
        XCTAssertEqual(v, 7)
    }
}
#endif
