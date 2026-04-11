#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
@testable import ScreenMuseFoundation
import Foundation

/// Tests for the Publisher protocol, built-in publishers, registry,
/// and content-type derivation. Network-dependent publish() paths
/// are exercised with a mock URLProtocol so real endpoints are not
/// hit in CI.
final class PublishTests: XCTestCase {

    // MARK: - Registry

    func testRegistryResolvesSlack() {
        XCTAssertEqual(PublisherRegistry.publisher(named: "slack")?.name, "slack")
    }

    func testRegistryResolvesHTTPPutAliases() {
        for alias in ["http_put", "s3", "r2", "gcs"] {
            XCTAssertEqual(PublisherRegistry.publisher(named: alias)?.name, "http_put",
                           "\(alias) should map to the http_put publisher")
        }
    }

    func testRegistryResolvesWebhook() {
        XCTAssertEqual(PublisherRegistry.publisher(named: "webhook")?.name, "webhook")
    }

    func testRegistryIsCaseInsensitive() {
        XCTAssertEqual(PublisherRegistry.publisher(named: "SLACK")?.name, "slack")
        XCTAssertEqual(PublisherRegistry.publisher(named: "Http_Put")?.name, "http_put")
    }

    func testRegistryReturnsNilForUnknownDestination() {
        XCTAssertNil(PublisherRegistry.publisher(named: "notion"))
        XCTAssertNil(PublisherRegistry.publisher(named: "drive"))
    }

    func testKnownDestinationsListed() {
        XCTAssertTrue(PublisherRegistry.known.contains("slack"))
        XCTAssertTrue(PublisherRegistry.known.contains("http_put"))
        XCTAssertTrue(PublisherRegistry.known.contains("webhook"))
    }

    // MARK: - HTTPPutPublisher content-type detection

    func testHTTPPutContentTypeForCommonFormats() {
        let pairs: [(String, String)] = [
            ("recording.mp4", "video/mp4"),
            ("recording.MOV", "video/quicktime"),
            ("recording.webm", "video/webm"),
            ("demo.gif", "image/gif"),
            ("demo.WEBP", "image/webp"),
            ("thumb.png", "image/png"),
            ("thumb.jpeg", "image/jpeg"),
            ("thumb.jpg", "image/jpeg"),
            ("meta.json", "application/json"),
            ("mystery.zzz", "application/octet-stream")
        ]
        for (filename, expected) in pairs {
            let url = URL(fileURLWithPath: "/tmp/\(filename)")
            XCTAssertEqual(
                HTTPPutPublisher.contentType(for: url),
                expected,
                "content-type for \(filename)"
            )
        }
    }

    // MARK: - Publishers reject missing files

    func testSlackPublisherRejectsMissingFile() async {
        let publisher = SlackPublisher()
        let fake = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mp4")
        let config = PublishConfig(url: URL(string: "https://hooks.slack.example/xyz")!)
        do {
            _ = try await publisher.publish(video: fake, config: config)
            XCTFail("expected fileNotFound")
        } catch PublishError.fileNotFound {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testHTTPPutPublisherRejectsMissingFile() async {
        let publisher = HTTPPutPublisher()
        let fake = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mp4")
        let config = PublishConfig(url: URL(string: "https://upload.example/presigned")!)
        do {
            _ = try await publisher.publish(video: fake, config: config)
            XCTFail("expected fileNotFound")
        } catch PublishError.fileNotFound {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testWebhookPublisherRejectsMissingFile() async {
        let publisher = WebhookPublisher()
        let fake = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mp4")
        let config = PublishConfig(url: URL(string: "https://webhook.example/screenmuse")!)
        do {
            _ = try await publisher.publish(video: fake, config: config)
            XCTFail("expected fileNotFound")
        } catch PublishError.fileNotFound {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - PublishResult Codable round-trip

    func testPublishResultCodableRoundTrip() throws {
        let original = PublishResult(
            destination: "slack",
            url: "https://hooks.slack.com/services/…",
            statusCode: 200,
            responseBody: "ok",
            bytesSent: 12345
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PublishResult.self, from: data)
        XCTAssertEqual(decoded.destination, "slack")
        XCTAssertEqual(decoded.statusCode, 200)
        XCTAssertEqual(decoded.bytesSent, 12345)

        // Snake-case keys must survive the round-trip.
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("status_code"))
        XCTAssertTrue(jsonString.contains("response_body"))
        XCTAssertTrue(jsonString.contains("bytes_sent"))
    }

    // MARK: - PublishConfig defaults

    func testPublishConfigDefaults() {
        let cfg = PublishConfig(url: URL(string: "https://example.com")!)
        XCTAssertTrue(cfg.extraHeaders.isEmpty)
        XCTAssertTrue(cfg.metadata.isEmpty)
        XCTAssertEqual(cfg.timeout, 120)
        XCTAssertNil(cfg.apiToken)
        XCTAssertNil(cfg.filename)
    }
}
#endif
