#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation

/// Tests for the SCContentSharingPicker availability + configuration
/// wrappers. We intentionally do NOT test picker presentation itself —
/// that requires a live UI session and a user clicking through a system
/// sheet. Availability probing and configuration validation are the
/// only things the HTTP surface exposes, and they are the pieces that
/// benefit most from unit coverage.
final class ContentSharingPickerTests: XCTestCase {

    // MARK: - Availability

    func testAvailabilityReturnsMacOSVersionString() {
        let a = ContentSharingPicker.availability()
        XCTAssertFalse(a.macosVersion.isEmpty, "availability must always report the OS version")
        XCTAssertTrue(a.macosVersion.contains("."),
                      "version string should look like major.minor.patch")
    }

    func testAvailabilityReasonPresentOnMacOS14() {
        // The host running this test is whatever the developer is on.
        // Assert the invariant: if supported is false, there must be
        // an explanation in `reason`.
        let a = ContentSharingPicker.availability()
        if !a.supported {
            XCTAssertNotNil(a.reason,
                            "an unsupported availability result must include a reason")
        } else {
            XCTAssertNil(a.reason,
                         "a supported availability result should not carry a reason")
        }
    }

    func testIsRuntimeSupportedMatchesAvailability() {
        XCTAssertEqual(
            ContentSharingPicker.isRuntimeSupported,
            ContentSharingPicker.availability().supported
        )
    }

    func testAvailabilityResponseIsDictionary() {
        let dict = ContentSharingPicker.availabilityResponse()
        XCTAssertNotNil(dict["supported"])
        XCTAssertNotNil(dict["macos_version"])
        let supported = dict["supported"] as? Bool
        XCTAssertNotNil(supported)
        if supported == false {
            XCTAssertNotNil(dict["reason"],
                            "/system/picker/availability must include 'reason' when supported is false")
        }
    }

    // MARK: - Configuration validation

    func testConfigurationDefaultsAreAllTrue() {
        let cfg = ContentSharingPicker.Configuration()
        XCTAssertTrue(cfg.allowScreens)
        XCTAssertTrue(cfg.allowWindows)
        XCTAssertTrue(cfg.allowApplications)
        XCTAssertNil(cfg.validationError())
    }

    func testConfigurationRejectsAllFalse() {
        let cfg = ContentSharingPicker.Configuration(
            allowScreens: false,
            allowWindows: false,
            allowApplications: false
        )
        let err = cfg.validationError()
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("at least one") == true)
    }

    func testConfigurationPartiallyEnabledIsValid() {
        let cfg = ContentSharingPicker.Configuration(
            allowScreens: false,
            allowWindows: true,
            allowApplications: false
        )
        XCTAssertNil(cfg.validationError())
    }

    // MARK: - Codable round-trip

    func testAvailabilityCodableSnakeCase() throws {
        let original = ContentSharingPicker.Availability(
            supported: false,
            reason: "requires macOS 15",
            macosVersion: "14.5.0"
        )
        let data = try JSONEncoder().encode(original)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains("macos_version"),
                      "CodingKeys must produce snake_case for macosVersion")
    }

    func testConfigurationCodableRoundTrip() throws {
        let original = ContentSharingPicker.Configuration(
            allowScreens: true,
            allowWindows: false,
            allowApplications: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            ContentSharingPicker.Configuration.self,
            from: data
        )
        XCTAssertTrue(decoded.allowScreens)
        XCTAssertFalse(decoded.allowWindows)
        XCTAssertTrue(decoded.allowApplications)
    }

    // MARK: - Error LocalizedError strings

    func testPickerErrorMessages() {
        XCTAssertNotNil(ContentSharingPicker.PickerError.unavailable("test").errorDescription)
        XCTAssertNotNil(ContentSharingPicker.PickerError.cancelled.errorDescription)
        XCTAssertNotNil(ContentSharingPicker.PickerError.noSelection.errorDescription)
        XCTAssertNotNil(ContentSharingPicker.PickerError.alreadyPresented.errorDescription)
        XCTAssertNotNil(ContentSharingPicker.PickerError.invalidConfiguration("x").errorDescription)
    }
}
#endif
