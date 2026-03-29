#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class RecordConvenienceTests: XCTestCase {

    // MARK: - Valid Durations

    func testValidDuration30Seconds() {
        XCTAssertNil(validateRecordDuration(30))
    }

    func testValidDuration1Second() {
        XCTAssertNil(validateRecordDuration(1))
    }

    func testValidDurationMaximum3600() {
        XCTAssertNil(validateRecordDuration(3600))
    }

    func testValidDurationFractional() {
        XCTAssertNil(validateRecordDuration(0.5))
    }

    // MARK: - Invalid Durations

    func testZeroDurationReturnsError() {
        let error = validateRecordDuration(0)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("duration_seconds"))
    }

    func testNegativeDurationReturnsError() {
        let error = validateRecordDuration(-1)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("duration_seconds"))
    }

    func testDurationExceeds3600ReturnsError() {
        let error = validateRecordDuration(3601)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("3600"))
    }

    func testNilDurationReturnsError() {
        let error = validateRecordDuration(nil)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("duration_seconds"))
    }

    // MARK: - Edge Cases

    func testVerySmallPositiveDuration() {
        // 0.001 seconds — technically valid (> 0 and <= 3600)
        XCTAssertNil(validateRecordDuration(0.001))
    }

    func testExactlyMaxDuration() {
        XCTAssertNil(validateRecordDuration(3600.0))
    }

    func testJustOverMaxDuration() {
        let error = validateRecordDuration(3600.001)
        XCTAssertNotNil(error)
    }
}
#endif
