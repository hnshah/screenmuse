#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class GIFExporterTests: XCTestCase {

    // MARK: - Config Defaults

    func testConfigDefaults() {
        let config = GIFExporter.Config()
        XCTAssertEqual(config.fps, 10, "Default fps should be 10")
        XCTAssertEqual(config.scale, 800, "Default scale should be 800")
        XCTAssertEqual(config.quality, .medium, "Default quality should be medium")
        XCTAssertNil(config.timeRange, "Default timeRange should be nil (full video)")
        XCTAssertEqual(config.format, .gif, "Default format should be gif")
    }

    func testConfigIsCustomizable() {
        var config = GIFExporter.Config()
        config.fps = 30
        config.scale = 1280
        config.quality = .high
        config.timeRange = 5.0...15.0
        config.format = .webp

        XCTAssertEqual(config.fps, 30)
        XCTAssertEqual(config.scale, 1280)
        XCTAssertEqual(config.quality, .high)
        XCTAssertEqual(config.timeRange, 5.0...15.0)
        XCTAssertEqual(config.format, .webp)
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

    // MARK: - Quality Raw Values

    func testQualityRawValues() {
        XCTAssertEqual(GIFExporter.Config.Quality.low.rawValue, "low")
        XCTAssertEqual(GIFExporter.Config.Quality.medium.rawValue, "medium")
        XCTAssertEqual(GIFExporter.Config.Quality.high.rawValue, "high")
    }

    func testQualityFromRawValue() {
        XCTAssertEqual(GIFExporter.Config.Quality(rawValue: "low"), .low)
        XCTAssertEqual(GIFExporter.Config.Quality(rawValue: "medium"), .medium)
        XCTAssertEqual(GIFExporter.Config.Quality(rawValue: "high"), .high)
        XCTAssertNil(GIFExporter.Config.Quality(rawValue: "ultra"))
    }

    // MARK: - Format

    func testFormatRawValues() {
        XCTAssertEqual(GIFExporter.Config.Format.gif.rawValue, "gif")
        XCTAssertEqual(GIFExporter.Config.Format.webp.rawValue, "webp")
    }

    func testFormatFileExtension() {
        XCTAssertEqual(GIFExporter.Config.Format.gif.fileExtension, "gif")
        XCTAssertEqual(GIFExporter.Config.Format.webp.fileExtension, "webp")
    }

    func testFormatFromRawValue() {
        XCTAssertEqual(GIFExporter.Config.Format(rawValue: "gif"), .gif)
        XCTAssertEqual(GIFExporter.Config.Format(rawValue: "webp"), .webp)
        XCTAssertNil(GIFExporter.Config.Format(rawValue: "mp4"))
    }

    // MARK: - ExportResult

    func testExportResultAsDictionary() {
        let url = URL(fileURLWithPath: "/tmp/test.gif")
        let result = GIFExporter.ExportResult(
            outputURL: url,
            format: .gif,
            width: 800,
            height: 450,
            frameCount: 100,
            fps: 10,
            duration: 10.0,
            fileSize: 2_097_152  // 2 MB
        )

        let dict = result.asDictionary()

        XCTAssertEqual(dict["path"] as? String, "/tmp/test.gif")
        XCTAssertEqual(dict["format"] as? String, "gif")
        XCTAssertEqual(dict["width"] as? Int, 800)
        XCTAssertEqual(dict["height"] as? Int, 450)
        XCTAssertEqual(dict["frames"] as? Int, 100)
        XCTAssertEqual(dict["fps"] as? Double, 10)
        XCTAssertEqual(dict["duration"] as? Double, 10.0)
        XCTAssertEqual(dict["size"] as? Int, 2_097_152)
        XCTAssertEqual(dict["size_mb"] as? Double, 2.0)
    }

    func testExportResultSizeMB() {
        let result = GIFExporter.ExportResult(
            outputURL: URL(fileURLWithPath: "/tmp/test.gif"),
            format: .gif,
            width: 400,
            height: 300,
            frameCount: 50,
            fps: 10,
            duration: 5.0,
            fileSize: 1_048_576  // exactly 1 MB
        )
        XCTAssertEqual(result.sizeMB, 1.0, accuracy: 0.001)
    }

    func testExportResultSizeMBRounding() {
        let result = GIFExporter.ExportResult(
            outputURL: URL(fileURLWithPath: "/tmp/test.gif"),
            format: .gif,
            width: 400,
            height: 300,
            frameCount: 50,
            fps: 10,
            duration: 5.0,
            fileSize: 3_670_016  // 3.5 MB
        )
        // asDictionary rounds to 2 decimal places
        let dict = result.asDictionary()
        XCTAssertEqual(dict["size_mb"] as? Double, 3.5)
    }

    // MARK: - ExportError Descriptions

    func testErrorDescriptions() {
        XCTAssertNotNil(GIFExporter.ExportError.unsupportedFormat("avi").errorDescription)
        XCTAssertNotNil(GIFExporter.ExportError.noVideoSource.errorDescription)
        XCTAssertNotNil(GIFExporter.ExportError.assetLoadFailed("test").errorDescription)
        XCTAssertNotNil(GIFExporter.ExportError.noVideoTrack.errorDescription)
        XCTAssertNotNil(GIFExporter.ExportError.outputDirectoryFailed("/bad").errorDescription)
        XCTAssertNotNil(GIFExporter.ExportError.destinationCreateFailed(URL(fileURLWithPath: "/bad")).errorDescription)
        XCTAssertNotNil(GIFExporter.ExportError.exportFailed("test").errorDescription)
    }

    func testUnsupportedFormatPreservesMessage() {
        let error = GIFExporter.ExportError.unsupportedFormat("avi")
        XCTAssertTrue(error.errorDescription!.contains("avi"))
    }

    func testAssetLoadFailedPreservesMessage() {
        let error = GIFExporter.ExportError.assetLoadFailed("file not found")
        XCTAssertTrue(error.errorDescription!.contains("file not found"))
    }

    func testNoVideoSourceMentionsRecord() {
        let error = GIFExporter.ExportError.noVideoSource
        XCTAssertTrue(error.errorDescription!.contains("Record"))
    }

    // MARK: - Output URL Helper

    func testDefaultOutputURLForGIF() {
        let source = URL(fileURLWithPath: "/Movies/ScreenMuse/recording-2026.mp4")
        let exports = URL(fileURLWithPath: "/Movies/ScreenMuse/Exports")
        let result = GIFExporter.defaultOutputURL(for: source, format: .gif, exportsDir: exports)
        XCTAssertEqual(result.lastPathComponent, "recording-2026.gif")
        XCTAssertTrue(result.path.contains("Exports"))
    }

    func testDefaultOutputURLForWebP() {
        let source = URL(fileURLWithPath: "/Movies/ScreenMuse/demo.mp4")
        let exports = URL(fileURLWithPath: "/Movies/ScreenMuse/Exports")
        let result = GIFExporter.defaultOutputURL(for: source, format: .webp, exportsDir: exports)
        XCTAssertEqual(result.lastPathComponent, "demo.webp")
    }

    // MARK: - Config Sendable

    func testConfigIsSendable() {
        // Verify Config can cross concurrency boundaries (compile-time check)
        let config = GIFExporter.Config()
        let _: Sendable = config
        XCTAssertTrue(true, "Config conforms to Sendable")
    }
}
#endif
