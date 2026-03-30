#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class ServerHelpersResolveTests: XCTestCase {

    // MARK: - "last" resolves to fallback

    func testLastReturnsFallbackURL() {
        let fallback = URL(fileURLWithPath: "/tmp/recording.mp4")
        let result = resolveSourceURL(from: ["source": "last"], fallback: fallback)
        XCTAssertEqual(result, fallback)
    }

    func testMissingSourceKeyReturnsFallbackURL() {
        let fallback = URL(fileURLWithPath: "/tmp/recording.mp4")
        let result = resolveSourceURL(from: [:], fallback: fallback)
        XCTAssertEqual(result, fallback)
    }

    // MARK: - "last" with nil fallback returns nil

    func testLastWithNilFallbackReturnsNil() {
        let result = resolveSourceURL(from: ["source": "last"], fallback: nil)
        XCTAssertNil(result)
    }

    func testMissingSourceKeyWithNilFallbackReturnsNil() {
        let result = resolveSourceURL(from: [:], fallback: nil)
        XCTAssertNil(result)
    }

    // MARK: - Explicit path returns file URL

    func testExplicitPathReturnsFileURL() {
        let result = resolveSourceURL(from: ["source": "/Users/me/video.mp4"], fallback: nil)
        XCTAssertEqual(result, URL(fileURLWithPath: "/Users/me/video.mp4"))
    }

    func testExplicitPathIgnoresFallback() {
        let fallback = URL(fileURLWithPath: "/tmp/recording.mp4")
        let result = resolveSourceURL(from: ["source": "/other/video.mov"], fallback: fallback)
        XCTAssertEqual(result, URL(fileURLWithPath: "/other/video.mov"))
    }
}
#endif
