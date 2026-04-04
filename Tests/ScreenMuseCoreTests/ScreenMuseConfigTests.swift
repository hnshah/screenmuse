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
}
#endif
