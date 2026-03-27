#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class VideoTrimmerTests: XCTestCase {

    // MARK: - Config Defaults

    func testConfigDefaults() {
        let config = VideoTrimmer.Config()
        XCTAssertEqual(config.start, 0, "Default start should be 0")
        XCTAssertNil(config.end, "Default end should be nil (full video)")
        XCTAssertFalse(config.reencode, "Default reencode should be false")
        XCTAssertNil(config.outputPath, "Default output path should be nil")
    }

    func testConfigIsCustomizable() {
        var config = VideoTrimmer.Config()
        config.start = 5.0
        config.end = 30.0
        config.reencode = true
        config.outputPath = "/tmp/trimmed.mp4"
        XCTAssertEqual(config.start, 5.0)
        XCTAssertEqual(config.end, 30.0)
        XCTAssertTrue(config.reencode)
        XCTAssertEqual(config.outputPath, "/tmp/trimmed.mp4")
    }

    // MARK: - TrimResult

    func testTrimResultAsDictionary() {
        let url = URL(fileURLWithPath: "/tmp/test.trimmed.mp4")
        let result = VideoTrimmer.TrimResult(
            outputURL: url,
            originalDuration: 60.0,
            trimmedDuration: 25.0,
            start: 5.0,
            end: 30.0,
            fileSize: 2_097_152 // 2 MB
        )

        let dict = result.asDictionary()

        XCTAssertEqual(dict["path"] as? String, "/tmp/test.trimmed.mp4")
        XCTAssertEqual(dict["original_duration"] as? Double, 60.0)
        XCTAssertEqual(dict["trimmed_duration"] as? Double, 25.0)
        XCTAssertEqual(dict["start"] as? Double, 5.0)
        XCTAssertEqual(dict["end"] as? Double, 30.0)
        XCTAssertEqual(dict["size"] as? Int, 2_097_152)
        XCTAssertEqual(dict["size_mb"] as? Double, 2.0)
    }

    func testTrimResultSizeMB() {
        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        let result = VideoTrimmer.TrimResult(
            outputURL: url,
            originalDuration: 10.0,
            trimmedDuration: 5.0,
            start: 0,
            end: 5.0,
            fileSize: 3_145_728 // 3 MB
        )
        XCTAssertEqual(result.sizeMB, 3.0, accuracy: 0.001)
    }

    // MARK: - TrimError

    func testTrimErrorDescriptions() {
        XCTAssertNotNil(VideoTrimmer.TrimError.noVideoSource.errorDescription)
        XCTAssertNotNil(VideoTrimmer.TrimError.invalidRange("test").errorDescription)
        XCTAssertNotNil(VideoTrimmer.TrimError.exportFailed("test").errorDescription)
        XCTAssertNotNil(VideoTrimmer.TrimError.exportCancelled.errorDescription)

        // invalidRange should preserve the message
        XCTAssertTrue(VideoTrimmer.TrimError.invalidRange("start > end").errorDescription!.contains("start > end"))
    }

    // MARK: - Output URL Helper

    func testDefaultOutputURL() {
        let source = URL(fileURLWithPath: "/Movies/ScreenMuse/recording-2026.mp4")
        let exports = URL(fileURLWithPath: "/Movies/ScreenMuse/Exports")
        let result = VideoTrimmer.defaultOutputURL(for: source, exportsDir: exports)
        XCTAssertEqual(result.lastPathComponent, "recording-2026.trimmed.mp4")
        XCTAssertTrue(result.path.contains("Exports"))
    }
}
#endif
