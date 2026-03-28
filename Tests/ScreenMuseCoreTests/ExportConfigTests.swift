#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests for GIF/WebP export configuration, format handling, and time range validation.
/// Pure logic — no AVFoundation I/O.
final class ExportConfigTests: XCTestCase {

    // MARK: - GIFExporter.Config Defaults

    func testConfigDefaultFPS() {
        let config = GIFExporter.Config()
        XCTAssertEqual(config.fps, 10, "Default fps should be 10")
    }

    func testConfigDefaultScale() {
        let config = GIFExporter.Config()
        XCTAssertEqual(config.scale, 800, "Default scale should be 800")
    }

    func testConfigDefaultQuality() {
        let config = GIFExporter.Config()
        XCTAssertEqual(config.quality, .medium, "Default quality should be .medium")
    }

    func testConfigDefaultFormat() {
        let config = GIFExporter.Config()
        XCTAssertEqual(config.format, .gif, "Default format should be .gif")
    }

    func testConfigDefaultTimeRangeNil() {
        let config = GIFExporter.Config()
        XCTAssertNil(config.timeRange, "Default timeRange should be nil (full video)")
    }

    // MARK: - Format Raw Value Round-Trip

    func testFormatGIFRoundTrip() {
        let format = GIFExporter.Config.Format(rawValue: "gif")
        XCTAssertEqual(format, .gif)
        XCTAssertEqual(format?.rawValue, "gif")
    }

    func testFormatWebPRoundTrip() {
        let format = GIFExporter.Config.Format(rawValue: "webp")
        XCTAssertEqual(format, .webp)
        XCTAssertEqual(format?.rawValue, "webp")
    }

    func testFormatInvalidReturnsNil() {
        XCTAssertNil(GIFExporter.Config.Format(rawValue: "mp4"))
        XCTAssertNil(GIFExporter.Config.Format(rawValue: ""))
        XCTAssertNil(GIFExporter.Config.Format(rawValue: "GIF"))
    }

    // MARK: - Quality Color Counts

    func testQualityLowColorCount() {
        XCTAssertEqual(GIFExporter.Config.Quality.low.colorCount, 128)
    }

    func testQualityMediumColorCount() {
        XCTAssertEqual(GIFExporter.Config.Quality.medium.colorCount, 256)
    }

    func testQualityHighColorCount() {
        XCTAssertEqual(GIFExporter.Config.Quality.high.colorCount, 256)
    }

    // MARK: - Quality Raw Value Round-Trip

    func testQualityRoundTrips() {
        for q in [GIFExporter.Config.Quality.low, .medium, .high] {
            XCTAssertEqual(GIFExporter.Config.Quality(rawValue: q.rawValue), q)
        }
    }

    func testQualityInvalidReturnsNil() {
        XCTAssertNil(GIFExporter.Config.Quality(rawValue: "ultra"))
        XCTAssertNil(GIFExporter.Config.Quality(rawValue: ""))
    }

    // MARK: - Format File Extension

    func testGIFFileExtension() {
        XCTAssertEqual(GIFExporter.Config.Format.gif.fileExtension, "gif")
    }

    func testWebPFileExtension() {
        XCTAssertEqual(GIFExporter.Config.Format.webp.fileExtension, "webp")
    }

    // MARK: - Config Mutation

    func testConfigMutation() {
        var config = GIFExporter.Config()
        config.fps = 30
        config.scale = 1200
        config.quality = .high
        config.format = .webp
        config.timeRange = 2.0...8.0

        XCTAssertEqual(config.fps, 30)
        XCTAssertEqual(config.scale, 1200)
        XCTAssertEqual(config.quality, .high)
        XCTAssertEqual(config.format, .webp)
        XCTAssertEqual(config.timeRange?.lowerBound, 2.0)
        XCTAssertEqual(config.timeRange?.upperBound, 8.0)
    }
}
#endif
