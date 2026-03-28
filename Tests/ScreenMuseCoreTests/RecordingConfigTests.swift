#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class RecordingConfigTests: XCTestCase {

    // MARK: - Quality Bitrate Mapping

    func testQualityBitrateLow() {
        XCTAssertEqual(RecordingConfig.Quality.low.bitrate, 1_000_000)
    }

    func testQualityBitrateMedium() {
        XCTAssertEqual(RecordingConfig.Quality.medium.bitrate, 3_000_000)
    }

    func testQualityBitrateHigh() {
        XCTAssertEqual(RecordingConfig.Quality.high.bitrate, 8_000_000)
    }

    func testQualityBitrateMax() {
        XCTAssertEqual(RecordingConfig.Quality.max.bitrate, 14_000_000)
    }

    func testQualityBitratesAreMonotonicallyIncreasing() {
        let qualities = RecordingConfig.Quality.allCases
        for i in 1..<qualities.count {
            XCTAssertGreaterThan(qualities[i].bitrate, qualities[i - 1].bitrate,
                                 "\(qualities[i].rawValue) should have higher bitrate than \(qualities[i - 1].rawValue)")
        }
    }

    // MARK: - Quality Raw Values (string round-trip)

    func testQualityRawValueRoundTrip() {
        for q in RecordingConfig.Quality.allCases {
            let recovered = RecordingConfig.Quality(rawValue: q.rawValue)
            XCTAssertEqual(recovered, q)
        }
    }

    func testQualityInvalidRawValueReturnsNil() {
        XCTAssertNil(RecordingConfig.Quality(rawValue: "ultra"))
        XCTAssertNil(RecordingConfig.Quality(rawValue: ""))
        XCTAssertNil(RecordingConfig.Quality(rawValue: "HIGH"))
    }

    // MARK: - Config Defaults

    func testConfigDefaults() {
        let config = RecordingConfig(captureSource: .fullScreen)
        XCTAssertTrue(config.includeSystemAudio)
        XCTAssertFalse(config.includeMicrophone)
        XCTAssertEqual(config.fps, 30)
        XCTAssertEqual(config.quality, .medium)
    }

    // MARK: - AudioSource Equality

    func testAudioSourceSystemEquality() {
        XCTAssertEqual(RecordingConfig.AudioSource.system, RecordingConfig.AudioSource.system)
    }

    func testAudioSourceNoneEquality() {
        XCTAssertEqual(RecordingConfig.AudioSource.none, RecordingConfig.AudioSource.none)
    }

    func testAudioSourceAppOnlyEquality() {
        XCTAssertEqual(
            RecordingConfig.AudioSource.appOnly("com.apple.Safari"),
            RecordingConfig.AudioSource.appOnly("com.apple.Safari")
        )
    }

    func testAudioSourceDifferentTypesNotEqual() {
        XCTAssertNotEqual(RecordingConfig.AudioSource.system, RecordingConfig.AudioSource.none)
    }
}
#endif
