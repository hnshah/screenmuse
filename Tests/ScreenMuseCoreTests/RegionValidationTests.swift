#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class RegionValidationTests: XCTestCase {

    // Standard 1920x1080 display at origin
    let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: - Valid Regions

    func testValidRegionWithinBounds() {
        let region = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertNil(validateRegion(region, against: displayBounds))
    }

    func testRegionExactlyMatchingDisplayBounds() {
        XCTAssertNil(validateRegion(displayBounds, against: displayBounds))
    }

    func testSmallRegionAtOrigin() {
        let region = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertNil(validateRegion(region, against: displayBounds))
    }

    func testRegionAtBottomRightCorner() {
        let region = CGRect(x: 1820, y: 980, width: 100, height: 100)
        XCTAssertNil(validateRegion(region, against: displayBounds))
    }

    // MARK: - Zero / Negative Dimensions

    func testZeroWidthReturnsError() {
        let region = CGRect(x: 100, y: 100, width: 0, height: 600)
        let error = validateRegion(region, against: displayBounds)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("width and height"))
    }

    func testZeroHeightReturnsError() {
        let region = CGRect(x: 100, y: 100, width: 800, height: 0)
        let error = validateRegion(region, against: displayBounds)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("width and height"))
    }

    func testNegativeWidthReturnsError() {
        let region = CGRect(x: 100, y: 100, width: -100, height: 600)
        let error = validateRegion(region, against: displayBounds)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("width and height"))
    }

    func testNegativeHeightReturnsError() {
        let region = CGRect(x: 100, y: 100, width: 800, height: -100)
        let error = validateRegion(region, against: displayBounds)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("width and height"))
    }

    // MARK: - Out of Bounds

    func testRegionExtendingPastRightEdge() {
        let region = CGRect(x: 1800, y: 100, width: 200, height: 100)
        let error = validateRegion(region, against: displayBounds)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("outside display bounds"))
    }

    func testRegionExtendingPastBottomEdge() {
        let region = CGRect(x: 100, y: 1000, width: 100, height: 200)
        let error = validateRegion(region, against: displayBounds)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("outside display bounds"))
    }

    func testRegionWithNegativeOrigin() {
        let region = CGRect(x: -10, y: 100, width: 800, height: 600)
        let error = validateRegion(region, against: displayBounds)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("outside display bounds"))
    }

    func testRegionLargerThanDisplay() {
        let region = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let error = validateRegion(region, against: displayBounds)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("outside display bounds"))
    }

    // MARK: - Multi-monitor (non-zero origin display bounds)

    func testValidRegionOnSecondMonitor() {
        // Second monitor at x=1920
        let dualBounds = CGRect(x: 0, y: 0, width: 3840, height: 1080)
        let region = CGRect(x: 2000, y: 100, width: 800, height: 600)
        XCTAssertNil(validateRegion(region, against: dualBounds))
    }

    func testRegionOnNegativeOriginDisplay() {
        // Display with negative origin (e.g., monitor stacked above)
        let bounds = CGRect(x: -1920, y: -1080, width: 3840, height: 2160)
        let region = CGRect(x: -100, y: -100, width: 200, height: 200)
        XCTAssertNil(validateRegion(region, against: bounds))
    }
}
#endif
