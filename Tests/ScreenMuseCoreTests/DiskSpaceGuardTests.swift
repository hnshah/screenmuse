#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
@testable import ScreenMuseFoundation
import Foundation

/// Tests for the pure-logic DiskSpaceGuard decision machine and
/// error body shape. Filesystem-dependent helpers (freeBytes) are
/// smoke-tested but not asserted on exact bytes.
final class DiskSpaceGuardTests: XCTestCase {

    // MARK: - Evaluate

    func testEvaluateReturnsOKForAbundantSpace() {
        let guardInstance = DiskSpaceGuard(minFreeBytes: 1024)
        XCTAssertEqual(guardInstance.evaluate(freeBytes: 10_000), .ok)
    }

    func testEvaluateReturnsOKExactlyAtThreshold() {
        let guardInstance = DiskSpaceGuard(minFreeBytes: 1024)
        XCTAssertEqual(guardInstance.evaluate(freeBytes: 1024), .ok,
                       "threshold is a floor — equal to minFreeBytes must still pass")
    }

    func testEvaluateReturnsInsufficientBelowThreshold() {
        let guardInstance = DiskSpaceGuard(minFreeBytes: 1024)
        let decision = guardInstance.evaluate(freeBytes: 512)
        switch decision {
        case .insufficient(let free, let required):
            XCTAssertEqual(free, 512)
            XCTAssertEqual(required, 1024)
        default:
            XCTFail("expected .insufficient decision")
        }
    }

    func testEvaluateReturnsUnknownWhenFreeIsNil() {
        let guardInstance = DiskSpaceGuard(minFreeBytes: 1024)
        XCTAssertEqual(guardInstance.evaluate(freeBytes: nil), .unknown)
    }

    func testDefaultMinFreeBytesIsTwoGigabytes() {
        XCTAssertEqual(DiskSpaceGuard.defaultMinFreeBytes, 2 * 1024 * 1024 * 1024)
    }

    // MARK: - Error body shape

    func testCheckOrErrorBodyReturnsNilForAbundantSpace() {
        // Use /tmp — always exists and (in a healthy dev env) has > 0 bytes.
        let guardInstance = DiskSpaceGuard(minFreeBytes: 1) // 1 byte is always available
        let result = guardInstance.checkOrErrorBody(
            forDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        XCTAssertNil(result, "1 byte threshold must always allow /tmp operations")
    }

    func testCheckOrErrorBodyReturnsStructuredErrorWhenLow() {
        // Set the threshold high enough that /tmp can't possibly satisfy it.
        let absurdlyHighThreshold: Int64 = Int64.max / 2
        let guardInstance = DiskSpaceGuard(minFreeBytes: absurdlyHighThreshold)
        let result = guardInstance.checkOrErrorBody(
            forDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        guard let body = result else {
            XCTFail("expected error body when threshold is absurdly high")
            return
        }
        XCTAssertEqual(body["code"] as? String, "DISK_SPACE_LOW")
        XCTAssertNotNil(body["free_bytes"])
        XCTAssertNotNil(body["required_bytes"])
        XCTAssertNotNil(body["suggestion"])
        XCTAssertNotNil(body["directory"])
    }

    func testFreeBytesReturnsSomethingReasonableForTmp() {
        // Any healthy machine running the test should have > 100 MB free in /tmp.
        // This is a smoke test for the actual filesystem call, not a bytes assertion.
        let free = DiskSpaceGuard.freeBytes(atDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertNotNil(free, "freeBytes must return a value for /tmp")
        XCTAssertGreaterThan(free ?? 0, 100 * 1024 * 1024)
    }

    // MARK: - formatBytes

    func testFormatBytesGigabytes() {
        XCTAssertEqual(DiskSpaceGuard.formatBytes(5 * 1024 * 1024 * 1024), "5.00 GB")
    }

    func testFormatBytesMegabytes() {
        XCTAssertEqual(DiskSpaceGuard.formatBytes(500 * 1024 * 1024), "500.0 MB")
    }

    func testFormatBytesKilobytes() {
        XCTAssertEqual(DiskSpaceGuard.formatBytes(10 * 1024), "10 KB")
    }

    func testFormatBytesBytes() {
        XCTAssertEqual(DiskSpaceGuard.formatBytes(42), "42 B")
    }
}
#endif
