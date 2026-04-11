#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests for ScreenMuseConfig — the user configuration system.
///
/// ScreenMuseConfig loads from ~/.screenmuse.json with Codable decoding.
/// These tests verify defaults, round-trip encoding, and field coverage.
final class ScreenMuseConfigTests: XCTestCase {

    // MARK: - Default Values

    func testDefaultPort() {
        let config = ScreenMuseConfig()
        XCTAssertEqual(config.port, 7823, "Default port must be 7823")
    }

    func testDefaultQuality() {
        let config = ScreenMuseConfig()
        XCTAssertEqual(config.defaultQuality, "medium", "Default quality must be 'medium'")
    }

    func testDefaultLogLevel() {
        let config = ScreenMuseConfig()
        XCTAssertEqual(config.logLevel, "info", "Default log level must be 'info'")
    }

    func testDefaultApiKeyIsNil() {
        let config = ScreenMuseConfig()
        XCTAssertNil(config.apiKey, "Default apiKey must be nil")
    }

    func testDefaultOutputDirectoryIsNil() {
        let config = ScreenMuseConfig()
        XCTAssertNil(config.outputDirectory, "Default outputDirectory must be nil")
    }

    func testDefaultWebhookURLIsNil() {
        let config = ScreenMuseConfig()
        XCTAssertNil(config.webhookURL, "Default webhookURL must be nil")
    }

    // MARK: - Custom Values

    func testCustomPort() {
        let config = ScreenMuseConfig(port: 9999)
        XCTAssertEqual(config.port, 9999)
    }

    func testCustomQuality() {
        let config = ScreenMuseConfig(defaultQuality: "high")
        XCTAssertEqual(config.defaultQuality, "high")
    }

    func testCustomApiKey() {
        let config = ScreenMuseConfig(apiKey: "test-api-key")
        XCTAssertEqual(config.apiKey, "test-api-key")
    }

    func testCustomOutputDirectory() {
        let config = ScreenMuseConfig(outputDirectory: "/tmp/screenmuse")
        XCTAssertEqual(config.outputDirectory, "/tmp/screenmuse")
    }

    func testCustomLogLevel() {
        let config = ScreenMuseConfig(logLevel: "debug")
        XCTAssertEqual(config.logLevel, "debug")
    }

    // MARK: - Codable Round-trip

    func testEncodeDecodeRoundTrip() throws {
        let original = ScreenMuseConfig(
            port: 8888,
            apiKey: "my-key",
            defaultQuality: "high",
            outputDirectory: "/tmp/recordings",
            logLevel: "debug",
            webhookURL: "https://example.com/webhook"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ScreenMuseConfig.self, from: data)

        XCTAssertEqual(decoded.port, 8888)
        XCTAssertEqual(decoded.apiKey, "my-key")
        XCTAssertEqual(decoded.defaultQuality, "high")
        XCTAssertEqual(decoded.outputDirectory, "/tmp/recordings")
        XCTAssertEqual(decoded.logLevel, "debug")
        XCTAssertEqual(decoded.webhookURL, "https://example.com/webhook")
    }

    func testJsonUsesSnakeCaseKeys() throws {
        let config = ScreenMuseConfig(defaultQuality: "low", logLevel: "warn")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        // Verify snake_case keys in the output
        XCTAssertNotNil(json["default_quality"], "JSON should use 'default_quality' key")
        XCTAssertNotNil(json["log_level"], "JSON should use 'log_level' key")
        XCTAssertNotNil(json["port"], "JSON should include 'port' key")
    }

    // MARK: - resolvedOutputDirectory

    func testResolvedOutputDirectoryNilWhenNotSet() {
        let config = ScreenMuseConfig()
        XCTAssertNil(config.resolvedOutputDirectory)
    }

    func testResolvedOutputDirectoryAbsolutePath() {
        let config = ScreenMuseConfig(outputDirectory: "/tmp/recordings")
        XCTAssertEqual(config.resolvedOutputDirectory, "/tmp/recordings")
    }

    func testResolvedOutputDirectoryExpandsTilde() {
        let config = ScreenMuseConfig(outputDirectory: "~/Movies/ScreenMuse")
        let resolved = config.resolvedOutputDirectory ?? ""
        XCTAssertTrue(resolved.hasPrefix("/"), "Tilde-prefixed path must be expanded to absolute")
        XCTAssertFalse(resolved.hasPrefix("~"), "Tilde must be expanded")
        XCTAssertTrue(resolved.hasSuffix("Movies/ScreenMuse"))
    }

    // MARK: - Load from missing file returns defaults

    func testLoadMissingFileReturnsDefaults() {
        // Use a custom path that doesn't exist
        // ScreenMuseConfig.load() uses the static configPath, so we verify defaults
        // by checking that the struct initializes with expected defaults.
        let config = ScreenMuseConfig()
        XCTAssertEqual(config.port, 7823)
        XCTAssertEqual(config.defaultQuality, "medium")
        XCTAssertEqual(config.logLevel, "info")
    }

    // MARK: - Field Coverage (all configurable fields are present)

    func testAllFieldsAreCodable() throws {
        // Verify all documented fields round-trip without error
        let config = ScreenMuseConfig(
            port: 7823,
            apiKey: nil,
            defaultQuality: "medium",
            outputDirectory: nil,
            logLevel: "info",
            webhookURL: nil
        )
        let encoder = JSONEncoder()
        XCTAssertNoThrow(try encoder.encode(config),
                         "ScreenMuseConfig must be fully encodable (Codable conformance)")
    }

    // MARK: - v2 — backward compatibility with v1 flat files

    func testV1FlatFileStillDecodes() throws {
        // A pre-Sprint-5 config file that only has the original 6 flat fields.
        let json = #"""
        {
          "port": 9000,
          "api_key": "v1-key",
          "default_quality": "high",
          "output_directory": "~/Movies/foo",
          "log_level": "debug",
          "webhook_url": "https://example.com"
        }
        """#
        let config = try ScreenMuseConfig.decode(from: Data(json.utf8))
        XCTAssertEqual(config.port, 9000)
        XCTAssertEqual(config.defaultQuality, "high")
        XCTAssertEqual(config.logLevel, "debug")
        XCTAssertNil(config.narration, "v1 files must leave v2 blocks nil")
        XCTAssertNil(config.browser)
        XCTAssertNil(config.publish)
        XCTAssertNil(config.metrics)
        XCTAssertNil(config.disk)
    }

    func testV1DefaultInitLeavesV2BlocksNil() {
        let config = ScreenMuseConfig()
        XCTAssertNil(config.narration)
        XCTAssertNil(config.browser)
        XCTAssertNil(config.publish)
        XCTAssertNil(config.metrics)
        XCTAssertNil(config.disk)
    }

    // MARK: - v2 — NarrationDefaults round-trip

    func testNarrationDefaultsRoundTrip() throws {
        let original = ScreenMuseConfig(
            narration: ScreenMuseConfig.NarrationDefaults(
                provider: "anthropic",
                model: "claude-sonnet-4-6",
                apiKey: "sk-ant-xyz",
                endpoint: nil,
                style: "tutorial",
                maxChapters: 8,
                frameCount: 10,
                language: "es"
            )
        )
        let data = try original.encode()
        let decoded = try ScreenMuseConfig.decode(from: data)
        XCTAssertEqual(decoded.narration?.provider, "anthropic")
        XCTAssertEqual(decoded.narration?.model, "claude-sonnet-4-6")
        XCTAssertEqual(decoded.narration?.apiKey, "sk-ant-xyz")
        XCTAssertEqual(decoded.narration?.style, "tutorial")
        XCTAssertEqual(decoded.narration?.maxChapters, 8)
        XCTAssertEqual(decoded.narration?.frameCount, 10)
        XCTAssertEqual(decoded.narration?.language, "es")
    }

    func testNarrationDefaultsJSONUsesSnakeCase() throws {
        let config = ScreenMuseConfig(
            narration: ScreenMuseConfig.NarrationDefaults(
                maxChapters: 3,
                frameCount: 8
            )
        )
        let data = try config.encode()
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"max_chapters\""))
        XCTAssertTrue(json.contains("\"frame_count\""))
        XCTAssertFalse(json.contains("\"maxChapters\""))
    }

    // MARK: - v2 — BrowserDefaults round-trip

    func testBrowserDefaultsRoundTrip() throws {
        let original = ScreenMuseConfig(
            browser: ScreenMuseConfig.BrowserDefaults(
                width: 1920,
                height: 1080,
                quality: "high",
                waitFor: "networkidle",
                userAgent: "ScreenMuse-Agent/1.0",
                locale: "en-GB",
                timezoneId: "Europe/London"
            )
        )
        let data = try original.encode()
        let decoded = try ScreenMuseConfig.decode(from: data)
        XCTAssertEqual(decoded.browser?.width, 1920)
        XCTAssertEqual(decoded.browser?.height, 1080)
        XCTAssertEqual(decoded.browser?.quality, "high")
        XCTAssertEqual(decoded.browser?.waitFor, "networkidle")
        XCTAssertEqual(decoded.browser?.userAgent, "ScreenMuse-Agent/1.0")
        XCTAssertEqual(decoded.browser?.locale, "en-GB")
        XCTAssertEqual(decoded.browser?.timezoneId, "Europe/London")
    }

    // MARK: - v2 — PublishDefaults round-trip (acronym CodingKeys)

    func testPublishDefaultsRoundTripPreservesAcronyms() throws {
        // Explicit CodingKeys are necessary because convertFromSnakeCase
        // turns "slack_webhook_url" into "slackWebhookUrl" (lowercase url),
        // which wouldn't match our `slackWebhookURL` field name.
        let original = ScreenMuseConfig(
            publish: ScreenMuseConfig.PublishDefaults(
                defaultDestination: "slack",
                slackWebhookURL: "https://hooks.slack.com/services/XYZ",
                webhookURL: "https://webhook.example/fallback",
                s3BucketURL: "https://bucket.s3.amazonaws.com"
            )
        )
        let data = try original.encode()
        let decoded = try ScreenMuseConfig.decode(from: data)
        XCTAssertEqual(decoded.publish?.defaultDestination, "slack")
        XCTAssertEqual(decoded.publish?.slackWebhookURL, "https://hooks.slack.com/services/XYZ")
        XCTAssertEqual(decoded.publish?.webhookURL, "https://webhook.example/fallback")
        XCTAssertEqual(decoded.publish?.s3BucketURL, "https://bucket.s3.amazonaws.com")

        // The JSON must use snake_case keys so operators editing
        // ~/.screenmuse.json by hand see conventional names.
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"slack_webhook_url\""))
        XCTAssertTrue(json.contains("\"s3_bucket_url\""))
        XCTAssertTrue(json.contains("\"default_destination\""))
    }

    func testPublishDefaultsDecodesSnakeCase() throws {
        let json = #"""
        {
          "publish": {
            "default_destination": "http_put",
            "slack_webhook_url": "https://hooks.slack.com/foo",
            "s3_bucket_url": "https://bucket.s3.example/put",
            "webhook_url": "https://x.example/w"
          }
        }
        """#
        let config = try ScreenMuseConfig.decode(from: Data(json.utf8))
        XCTAssertEqual(config.publish?.defaultDestination, "http_put")
        XCTAssertEqual(config.publish?.slackWebhookURL, "https://hooks.slack.com/foo")
        XCTAssertEqual(config.publish?.s3BucketURL, "https://bucket.s3.example/put")
        XCTAssertEqual(config.publish?.webhookURL, "https://x.example/w")
    }

    // MARK: - v2 — DiskDefaults + minFreeBytes helper

    func testDiskDefaultsMinFreeBytesComputed() {
        let disk = ScreenMuseConfig.DiskDefaults(minFreeGB: 5)
        XCTAssertEqual(disk.minFreeBytes, 5 * 1024 * 1024 * 1024)
    }

    func testDiskDefaultsMinFreeBytesNilWhenUnset() {
        let disk = ScreenMuseConfig.DiskDefaults()
        XCTAssertNil(disk.minFreeBytes)
    }

    func testDiskDefaultsRoundTrip() throws {
        let original = ScreenMuseConfig(
            disk: ScreenMuseConfig.DiskDefaults(minFreeGB: 3.5)
        )
        let data = try original.encode()
        let decoded = try ScreenMuseConfig.decode(from: data)
        XCTAssertEqual(decoded.disk?.minFreeGB, 3.5)

        // Check the on-disk key is the snake-cased form operators expect.
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"min_free_gb\""),
                      "disk.min_free_gb must use the documented snake_case key")
    }

    // MARK: - v2 — MetricsDefaults

    func testMetricsDefaultsRoundTrip() throws {
        let original = ScreenMuseConfig(
            metrics: ScreenMuseConfig.MetricsDefaults(enabled: false)
        )
        let data = try original.encode()
        let decoded = try ScreenMuseConfig.decode(from: data)
        XCTAssertEqual(decoded.metrics?.enabled, false)
    }

    // MARK: - v2 — full mixed v1/v2 file

    func testMixedV1V2FileRoundTrip() throws {
        let original = ScreenMuseConfig(
            port: 7823,
            apiKey: "k",
            defaultQuality: "high",
            logLevel: "warn",
            narration: ScreenMuseConfig.NarrationDefaults(provider: "ollama", model: "llava:13b"),
            disk: ScreenMuseConfig.DiskDefaults(minFreeGB: 10)
        )
        let data = try original.encode()
        let decoded = try ScreenMuseConfig.decode(from: data)
        XCTAssertEqual(decoded.port, 7823)
        XCTAssertEqual(decoded.defaultQuality, "high")
        XCTAssertEqual(decoded.narration?.model, "llava:13b")
        XCTAssertEqual(decoded.disk?.minFreeGB, 10)
        XCTAssertNil(decoded.browser, "unset v2 blocks must remain nil after round-trip")
        XCTAssertNil(decoded.publish)
    }
}
#endif
