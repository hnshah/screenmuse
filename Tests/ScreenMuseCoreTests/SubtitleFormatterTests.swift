#if canImport(XCTest)
import XCTest
@testable import ScreenMuseCore
import Foundation

/// Tests for the pure-logic SRT / VTT formatter. Exercises every branch
/// of timecode formatting, cue derivation (end-time from next cue,
/// last-cue fallback duration, video-duration clamping), and text
/// escaping for CRLF / LF / null-byte inputs.
final class SubtitleFormatterTests: XCTestCase {

    // MARK: - Timecode formatting

    func testSrtTimecodeZero() {
        XCTAssertEqual(SubtitleFormatter.srtTimecode(0), "00:00:00,000")
    }

    func testSrtTimecodeOneSecond() {
        XCTAssertEqual(SubtitleFormatter.srtTimecode(1), "00:00:01,000")
    }

    func testSrtTimecodeMillisecondRounding() {
        XCTAssertEqual(SubtitleFormatter.srtTimecode(0.5), "00:00:00,500")
        XCTAssertEqual(SubtitleFormatter.srtTimecode(0.123), "00:00:00,123")
    }

    func testSrtTimecodeMinuteBoundary() {
        XCTAssertEqual(SubtitleFormatter.srtTimecode(59.999), "00:00:59,999")
        XCTAssertEqual(SubtitleFormatter.srtTimecode(60), "00:01:00,000")
    }

    func testSrtTimecodeHourBoundary() {
        XCTAssertEqual(SubtitleFormatter.srtTimecode(3599.999), "00:59:59,999")
        XCTAssertEqual(SubtitleFormatter.srtTimecode(3600), "01:00:00,000")
    }

    func testSrtTimecodeClampsNegative() {
        XCTAssertEqual(SubtitleFormatter.srtTimecode(-5), "00:00:00,000")
    }

    func testVttTimecodeUsesPeriod() {
        XCTAssertEqual(SubtitleFormatter.vttTimecode(1.234), "00:00:01.234")
    }

    func testVttTimecodeMultipleHours() {
        XCTAssertEqual(SubtitleFormatter.vttTimecode(7323.456), "02:02:03.456")
    }

    // MARK: - Cue derivation

    func testDerivedCuesChainsEndTimesFromNextEntry() {
        let result = NarrationResult(
            narration: [
                NarrationEntry(time: 0, text: "Intro"),
                NarrationEntry(time: 2.5, text: "Middle"),
                NarrationEntry(time: 5, text: "Outro")
            ],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let formatter = SubtitleFormatter()
        let cues = formatter.derivedCues(from: result)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].start, 0)
        XCTAssertEqual(cues[0].end, 2.5)
        XCTAssertEqual(cues[1].start, 2.5)
        XCTAssertEqual(cues[1].end, 5)
        XCTAssertEqual(cues[2].start, 5)
        XCTAssertEqual(cues[2].end, 9, "last cue falls back to start + defaultLastCueDuration (4s)")
    }

    func testDerivedCuesUsesCustomLastCueDuration() {
        let result = NarrationResult(
            narration: [NarrationEntry(time: 10, text: "solo")],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let formatter = SubtitleFormatter(defaultLastCueDuration: 2)
        let cues = formatter.derivedCues(from: result)
        XCTAssertEqual(cues.first?.end, 12)
    }

    func testDerivedCuesClampsToVideoDuration() {
        let result = NarrationResult(
            narration: [NarrationEntry(time: 8, text: "near the end")],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        // defaultLastCueDuration is 4s → raw end = 12s, but video is 10s
        let formatter = SubtitleFormatter(videoDuration: 10)
        let cues = formatter.derivedCues(from: result)
        XCTAssertEqual(cues.first?.end, 10)
    }

    func testDerivedCuesEnsuresMinimumDuration() {
        // Two entries with identical timestamps should still produce
        // cues that are at least 0.1s long (otherwise players treat
        // them as zero-duration and skip them).
        let result = NarrationResult(
            narration: [
                NarrationEntry(time: 1, text: "first"),
                NarrationEntry(time: 1, text: "second")
            ],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let cues = SubtitleFormatter().derivedCues(from: result)
        for cue in cues {
            XCTAssertGreaterThanOrEqual(cue.end - cue.start, 0.1)
        }
    }

    func testDerivedCuesFiltersEmptyText() {
        let result = NarrationResult(
            narration: [
                NarrationEntry(time: 0, text: "hello"),
                NarrationEntry(time: 1, text: ""),
                NarrationEntry(time: 2, text: "   "),
                NarrationEntry(time: 3, text: "world")
            ],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let cues = SubtitleFormatter().derivedCues(from: result)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "hello")
        XCTAssertEqual(cues[1].text, "world")
    }

    func testDerivedCuesSortsByStartTime() {
        let result = NarrationResult(
            narration: [
                NarrationEntry(time: 5, text: "third"),
                NarrationEntry(time: 1, text: "first"),
                NarrationEntry(time: 3, text: "second")
            ],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let cues = SubtitleFormatter().derivedCues(from: result)
        XCTAssertEqual(cues.map { $0.text }, ["first", "second", "third"])
    }

    // MARK: - SRT rendering

    func testSrtIncludesCueNumbers() {
        let result = NarrationResult(
            narration: [
                NarrationEntry(time: 0, text: "one"),
                NarrationEntry(time: 1, text: "two")
            ],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let srt = SubtitleFormatter().srt(from: result)
        // Cue numbers are 1-indexed
        XCTAssertTrue(srt.contains("1\n"))
        XCTAssertTrue(srt.contains("2\n"))
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:01,000"))
        XCTAssertTrue(srt.contains("one"))
        XCTAssertTrue(srt.contains("two"))
    }

    func testSrtEndsWithBlankLineAfterLastCue() {
        let result = NarrationResult(
            narration: [NarrationEntry(time: 0, text: "only")],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let srt = SubtitleFormatter().srt(from: result)
        XCTAssertTrue(srt.hasSuffix("\n\n"),
                      "SRT requires a trailing blank line after the last cue")
    }

    func testSrtEmptyNarrationProducesEmptyOutput() {
        let result = NarrationResult(
            narration: [],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        XCTAssertEqual(SubtitleFormatter().srt(from: result), "")
    }

    // MARK: - VTT rendering

    func testVttStartsWithWEBVTTHeader() {
        let result = NarrationResult(
            narration: [NarrationEntry(time: 0, text: "hello")],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let vtt = SubtitleFormatter().vtt(from: result)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"),
                      "VTT files must start with the WEBVTT signature followed by a blank line")
    }

    func testVttUsesPeriodInTimecode() {
        let result = NarrationResult(
            narration: [NarrationEntry(time: 0, text: "hi"), NarrationEntry(time: 1.5, text: "bye")],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let vtt = SubtitleFormatter().vtt(from: result)
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:01.500"))
        XCTAssertFalse(vtt.contains(","), "VTT must not use SRT-style commas in timecodes")
    }

    func testVttOmitsCueNumbers() {
        let result = NarrationResult(
            narration: [
                NarrationEntry(time: 0, text: "one"),
                NarrationEntry(time: 1, text: "two")
            ],
            suggestedChapters: [],
            provider: "mock",
            model: "mock-v1"
        )
        let vtt = SubtitleFormatter().vtt(from: result)
        // Neither "1\n00:" nor "2\n00:" should appear — VTT doesn't number cues.
        XCTAssertFalse(vtt.contains("\n1\n00:"))
        XCTAssertFalse(vtt.contains("\n2\n00:"))
    }

    // MARK: - Cue text escaping

    func testEscapeCueTextCollapsesNewlines() {
        XCTAssertEqual(
            SubtitleFormatter.escapeCueText("line one\nline two"),
            "line one line two"
        )
    }

    func testEscapeCueTextCollapsesCRLF() {
        XCTAssertEqual(
            SubtitleFormatter.escapeCueText("foo\r\nbar"),
            "foo bar"
        )
    }

    func testEscapeCueTextStripsNullBytes() {
        let input = "safe\u{0000}text"
        XCTAssertEqual(SubtitleFormatter.escapeCueText(input), "safetext")
    }

    func testEscapeCueTextTrimsWhitespace() {
        XCTAssertEqual(SubtitleFormatter.escapeCueText("  hello  "), "hello")
    }
}
#endif
