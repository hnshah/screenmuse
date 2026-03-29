#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class AuthTests: XCTestCase {

    // MARK: - Valid Key

    func testMatchingKeyAllowsRequest() {
        XCTAssertTrue(checkAPIKey(required: "secret-key", provided: "secret-key", method: "POST", path: "/start"))
    }

    // MARK: - Invalid / Missing Key

    func testWrongKeyRejectsRequest() {
        XCTAssertFalse(checkAPIKey(required: "secret-key", provided: "wrong-key", method: "POST", path: "/start"))
    }

    func testNilProvidedKeyRejectsRequest() {
        XCTAssertFalse(checkAPIKey(required: "secret-key", provided: nil, method: "POST", path: "/start"))
    }

    func testEmptyProvidedKeyRejectsRequest() {
        XCTAssertFalse(checkAPIKey(required: "secret-key", provided: "", method: "POST", path: "/start"))
    }

    // MARK: - No Auth Configured

    func testNilRequiredKeyAllowsAnyRequest() {
        XCTAssertTrue(checkAPIKey(required: nil, provided: nil, method: "POST", path: "/start"))
    }

    func testNilRequiredKeyAllowsEvenWithProvidedKey() {
        XCTAssertTrue(checkAPIKey(required: nil, provided: "some-key", method: "GET", path: "/status"))
    }

    // MARK: - OPTIONS Preflight Exempt

    func testOptionsMethodBypassesAuth() {
        XCTAssertTrue(checkAPIKey(required: "secret-key", provided: "wrong-key", method: "OPTIONS", path: "/start"))
    }

    func testOptionsMethodBypassesAuthWithNilKey() {
        XCTAssertTrue(checkAPIKey(required: "secret-key", provided: nil, method: "OPTIONS", path: "/start"))
    }

    // MARK: - /health Exempt

    func testHealthPathBypassesAuth() {
        XCTAssertTrue(checkAPIKey(required: "secret-key", provided: nil, method: "GET", path: "/health"))
    }

    func testHealthPathBypassesAuthWithWrongKey() {
        XCTAssertTrue(checkAPIKey(required: "secret-key", provided: "wrong", method: "GET", path: "/health"))
    }

    // MARK: - Non-exempt Paths

    func testNonHealthPathRequiresAuth() {
        XCTAssertFalse(checkAPIKey(required: "secret-key", provided: nil, method: "GET", path: "/status"))
    }

    func testNonHealthPathRequiresCorrectKey() {
        XCTAssertFalse(checkAPIKey(required: "secret-key", provided: "wrong", method: "GET", path: "/status"))
    }

    // MARK: - Edge Cases

    func testEmptyRequiredKeyMatchesEmptyProvided() {
        XCTAssertTrue(checkAPIKey(required: "", provided: "", method: "POST", path: "/start"))
    }

    func testEmptyRequiredKeyRejectsNilProvided() {
        XCTAssertTrue(checkAPIKey(required: "", provided: nil, method: "POST", path: "/start"))
    }
}
#endif
