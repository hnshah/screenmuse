#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore

/// Tests for API response structure, error formatting, and status code mapping.
/// Pure logic — exercises structuredError and response patterns.
final class ResponseFormatTests: XCTestCase {

    // MARK: - Error Response Structure

    func testErrorResponseHasErrorKey() {
        let error: [String: Any] = [
            "error": "Something went wrong",
            "code": "TEST_ERROR"
        ]
        XCTAssertNotNil(error["error"] as? String)
    }

    func testErrorResponseMayHaveCodeKey() {
        let error: [String: Any] = [
            "error": "Not found",
            "code": "NOT_FOUND"
        ]
        XCTAssertEqual(error["code"] as? String, "NOT_FOUND")
    }

    func testErrorResponseMayHaveSuggestionKey() {
        let error: [String: Any] = [
            "error": "Permission denied",
            "code": "PERMISSION_DENIED",
            "suggestion": "Grant Screen Recording permission"
        ]
        XCTAssertNotNil(error["suggestion"] as? String)
    }

    // MARK: - Status Code Mapping

    func testStatusCodeMapping() {
        let statusTexts: [Int: String] = [
            200: "OK",
            202: "Accepted",
            400: "Bad Request",
            404: "Not Found",
            409: "Conflict",
            413: "Payload Too Large",
            500: "Internal Server Error"
        ]

        XCTAssertEqual(statusTexts[200], "OK")
        XCTAssertEqual(statusTexts[400], "Bad Request")
        XCTAssertEqual(statusTexts[404], "Not Found")
        XCTAssertEqual(statusTexts[409], "Conflict")
        XCTAssertEqual(statusTexts[413], "Payload Too Large")
        XCTAssertEqual(statusTexts[500], "Internal Server Error")
    }

    func testStatus202ForAccepted() {
        let statusTexts: [Int: String] = [202: "Accepted"]
        XCTAssertEqual(statusTexts[202], "Accepted")
    }

    // MARK: - Structured Error Types

    @MainActor
    func testStructuredErrorPermissionDenied() {
        let server = ScreenMuseServer.shared
        let result = server.structuredError(RecordingError.permissionDenied("Screen Recording permission required"))
        XCTAssertEqual(result["code"] as? String, "PERMISSION_DENIED")
        XCTAssertNotNil(result["error"])
        XCTAssertNotNil(result["suggestion"])
    }

    @MainActor
    func testStructuredErrorNotRecording() {
        let server = ScreenMuseServer.shared
        let result = server.structuredError(RecordingError.notRecording)
        XCTAssertEqual(result["code"] as? String, "NOT_RECORDING")
        XCTAssertNotNil(result["error"])
    }

    @MainActor
    func testStructuredErrorWindowNotFound() {
        let server = ScreenMuseServer.shared
        let result = server.structuredError(RecordingError.windowNotFound("Safari"))
        XCTAssertEqual(result["code"] as? String, "WINDOW_NOT_FOUND")
        XCTAssertEqual(result["query"] as? String, "Safari")
        XCTAssertNotNil(result["suggestion"])
    }

    @MainActor
    func testStructuredErrorUnknown() {
        let server = ScreenMuseServer.shared
        let genericError = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something broke"])
        let result = server.structuredError(genericError)
        XCTAssertEqual(result["code"] as? String, "UNKNOWN_ERROR")
        XCTAssertEqual(result["error"] as? String, "Something broke")
    }

    // MARK: - Export Result Dictionary

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
            fileSize: 2_500_000
        )
        let dict = result.asDictionary()
        XCTAssertEqual(dict["path"] as? String, "/tmp/test.gif")
        XCTAssertEqual(dict["format"] as? String, "gif")
        XCTAssertEqual(dict["width"] as? Int, 800)
        XCTAssertEqual(dict["height"] as? Int, 450)
        XCTAssertEqual(dict["frames"] as? Int, 100)
        XCTAssertEqual(dict["fps"] as? Double, 10.0)
        XCTAssertEqual(dict["duration"] as? Double, 10.0)
        XCTAssertEqual(dict["size"] as? Int, 2_500_000)
    }

    func testTrimResultAsDictionary() {
        let url = URL(fileURLWithPath: "/tmp/trimmed.mp4")
        let result = VideoTrimmer.TrimResult(
            outputURL: url,
            originalDuration: 30.0,
            trimmedDuration: 10.0,
            start: 5.0,
            end: 15.0,
            fileSize: 5_000_000
        )
        let dict = result.asDictionary()
        XCTAssertEqual(dict["path"] as? String, "/tmp/trimmed.mp4")
        XCTAssertEqual(dict["start"] as? Double, 5.0)
        XCTAssertEqual(dict["end"] as? Double, 15.0)
    }

    // MARK: - Error Description Strings

    func testTrimErrorDescriptions() {
        let err1 = VideoTrimmer.TrimError.noVideoSource
        XCTAssertNotNil(err1.errorDescription)
        XCTAssertTrue(err1.errorDescription!.contains("video"))

        let err2 = VideoTrimmer.TrimError.invalidRange("start > end")
        XCTAssertNotNil(err2.errorDescription)
        XCTAssertTrue(err2.errorDescription!.contains("start > end"))

        let err3 = VideoTrimmer.TrimError.exportCancelled
        XCTAssertNotNil(err3.errorDescription)
    }

    func testSpeedRampErrorDescriptions() {
        let err1 = SpeedRamper.SpeedRampError.noVideoSource
        XCTAssertNotNil(err1.errorDescription)

        let err2 = SpeedRamper.SpeedRampError.assetLoadFailed("timeout")
        XCTAssertTrue(err2.errorDescription!.contains("timeout"))

        let err3 = SpeedRamper.SpeedRampError.exportFailed("disk full")
        XCTAssertTrue(err3.errorDescription!.contains("disk full"))
    }
}
#endif
