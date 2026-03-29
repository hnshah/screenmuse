#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

final class ContentLengthParserTests: XCTestCase {

    // MARK: - Standard Parsing

    func testParsesContentLengthFromFullRequest() {
        let raw = "POST /start HTTP/1.1\r\nHost: localhost:7823\r\nContent-Type: application/json\r\nContent-Length: 1234\r\n\r\n{\"name\": \"test\"}"
        XCTAssertEqual(parseContentLength(from: raw), 1234)
    }

    func testParsesContentLengthZero() {
        let raw = "GET /health HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        XCTAssertEqual(parseContentLength(from: raw), 0)
    }

    func testParsesLargeContentLength() {
        let raw = "POST /upload HTTP/1.1\r\nContent-Length: 67108864\r\n\r\n"
        XCTAssertEqual(parseContentLength(from: raw), 67108864)  // 64 MB
    }

    // MARK: - Case Insensitivity

    func testParsesLowercaseContentLength() {
        let raw = "POST /start HTTP/1.1\r\ncontent-length: 500\r\n\r\n{}"
        XCTAssertEqual(parseContentLength(from: raw), 500)
    }

    func testParsesMixedCaseContentLength() {
        let raw = "POST /start HTTP/1.1\r\nContent-length: 42\r\n\r\n"
        XCTAssertEqual(parseContentLength(from: raw), 42)
    }

    // MARK: - Missing Header

    func testReturnsNilWhenNoContentLengthHeader() {
        let raw = "GET /status HTTP/1.1\r\nHost: localhost:7823\r\nAccept: application/json\r\n\r\n"
        XCTAssertNil(parseContentLength(from: raw))
    }

    func testReturnsNilForEmptyRequest() {
        XCTAssertNil(parseContentLength(from: ""))
    }

    func testReturnsNilForRequestLineOnly() {
        let raw = "GET /health HTTP/1.1\r\n\r\n"
        XCTAssertNil(parseContentLength(from: raw))
    }

    // MARK: - Malformed Values

    func testReturnsNilForNonNumericValue() {
        let raw = "POST /start HTTP/1.1\r\nContent-Length: abc\r\n\r\n"
        XCTAssertNil(parseContentLength(from: raw))
    }

    func testReturnsNilForFloatingPointValue() {
        let raw = "POST /start HTTP/1.1\r\nContent-Length: 123.45\r\n\r\n"
        XCTAssertNil(parseContentLength(from: raw))
    }

    func testReturnsNilForNegativeValue() {
        let raw = "POST /start HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
        XCTAssertNil(parseContentLength(from: raw))
    }

    // MARK: - Whitespace Handling

    func testParsesWithExtraWhitespace() {
        let raw = "POST /start HTTP/1.1\r\nContent-Length:   999   \r\n\r\n"
        XCTAssertEqual(parseContentLength(from: raw), 999)
    }
}
#endif
