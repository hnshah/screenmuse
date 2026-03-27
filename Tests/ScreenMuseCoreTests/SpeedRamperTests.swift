#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class SpeedRamperTests: XCTestCase {

    // MARK: - Config Defaults

    func testConfigDefaults() {
        let config = SpeedRamper.Config()
        XCTAssertEqual(config.idleThresholdSec, 2.0, "Default idle threshold should be 2.0s")
        XCTAssertEqual(config.idleSpeed, 4.0, "Default idle speed should be 4.0x")
        XCTAssertEqual(config.activeSpeed, 1.0, "Default active speed should be 1.0x (no change)")
    }

    func testConfigIsCustomizable() {
        var config = SpeedRamper.Config()
        config.idleThresholdSec = 3.0
        config.idleSpeed = 8.0
        config.activeSpeed = 0.5
        XCTAssertEqual(config.idleThresholdSec, 3.0)
        XCTAssertEqual(config.idleSpeed, 8.0)
        XCTAssertEqual(config.activeSpeed, 0.5)
    }

    // MARK: - SpeedRampResult

    func testResultAsDictionary() {
        let url = URL(fileURLWithPath: "/tmp/test.ramped.mp4")
        let result = SpeedRamper.SpeedRampResult(
            outputURL: url,
            originalDuration: 60.0,
            outputDuration: 30.0,
            compressionRatio: 2.0,
            idleSections: 3,
            idleTotalSeconds: 20.0,
            activeSections: 4,
            activeTotalSeconds: 40.0,
            fileSize: 5_242_880 // 5 MB
        )

        let dict = result.asDictionary()

        XCTAssertEqual(dict["path"] as? String, "/tmp/test.ramped.mp4")
        XCTAssertEqual(dict["original_duration"] as? Double, 60.0)
        XCTAssertEqual(dict["output_duration"] as? Double, 30.0)
        XCTAssertEqual(dict["compression_ratio"] as? Double, 2.0)
        XCTAssertEqual(dict["idle_sections"] as? Int, 3)
        XCTAssertEqual(dict["active_sections"] as? Int, 4)
        XCTAssertEqual(dict["size"] as? Int, 5_242_880)
        XCTAssertEqual(dict["size_mb"] as? Double, 5.0)
    }

    func testResultSizeMBConversion() {
        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        let result = SpeedRamper.SpeedRampResult(
            outputURL: url,
            originalDuration: 10.0,
            outputDuration: 5.0,
            compressionRatio: 2.0,
            idleSections: 1,
            idleTotalSeconds: 5.0,
            activeSections: 1,
            activeTotalSeconds: 5.0,
            fileSize: 1_048_576 // exactly 1 MB
        )
        XCTAssertEqual(result.sizeMB, 1.0, accuracy: 0.001)
    }

    // MARK: - SpeedRampError

    func testErrorDescriptions() {
        XCTAssertNotNil(SpeedRamper.SpeedRampError.noVideoSource.errorDescription)
        XCTAssertNotNil(SpeedRamper.SpeedRampError.assetLoadFailed("test").errorDescription)
        XCTAssertNotNil(SpeedRamper.SpeedRampError.compositionFailed("test").errorDescription)
        XCTAssertNotNil(SpeedRamper.SpeedRampError.exportFailed("test").errorDescription)

        XCTAssertTrue(SpeedRamper.SpeedRampError.noVideoSource.errorDescription!.contains("Record"))
        XCTAssertTrue(SpeedRamper.SpeedRampError.assetLoadFailed("bad file").errorDescription!.contains("bad file"))
    }
}
#endif
