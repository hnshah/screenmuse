import Foundation

/// Pure-logic formatter that turns a `NarrationResult` into SRT or WebVTT
/// subtitle text. Kept provider-agnostic so the `/narrate` handler and
/// any future subtitle-only endpoint can share one implementation.
///
/// End-time policy: `NarrationEntry` has only a start timestamp, so the
/// formatter derives each cue's end time from the next entry's start.
/// The last cue uses `defaultLastCueDuration` (4s by default) so it
/// doesn't flash off-screen.
///
/// Why not AVFoundation's built-in subtitle writers: those emit
/// timed-metadata embedded in an MP4, which is a much bigger surface
/// (mutable movie mixing, track insertion, muxer rewrites). Agents
/// overwhelmingly want sidecar `.srt`/`.vtt` files that can be posted
/// to GitHub comments, uploaded to YouTube, or rendered by `<video>`
/// tags, so we emit text and stay out of the mux layer.
public struct SubtitleFormatter: Sendable {

    /// The end-time used for the last cue when the next entry's start
    /// can't fill it in. 4 seconds is the default — matches the human
    /// minimum comfortable read time for a short sentence.
    public var defaultLastCueDuration: Double

    /// If set, clamp every cue's end time to this value (the video's
    /// actual duration). Prevents the last cue from running past
    /// the end of the video.
    public var videoDuration: Double?

    public init(
        defaultLastCueDuration: Double = 4.0,
        videoDuration: Double? = nil
    ) {
        self.defaultLastCueDuration = defaultLastCueDuration
        self.videoDuration = videoDuration
    }

    // MARK: - Public API

    /// Render `result.narration` as SRT.
    public func srt(from result: NarrationResult) -> String {
        let cues = derivedCues(from: result)
        var out = ""
        for (idx, cue) in cues.enumerated() {
            out += "\(idx + 1)\n"
            out += "\(Self.srtTimecode(cue.start)) --> \(Self.srtTimecode(cue.end))\n"
            out += Self.escapeCueText(cue.text) + "\n\n"
        }
        return out
    }

    /// Render `result.narration` as WebVTT.
    public func vtt(from result: NarrationResult) -> String {
        let cues = derivedCues(from: result)
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(Self.vttTimecode(cue.start)) --> \(Self.vttTimecode(cue.end))\n"
            out += Self.escapeCueText(cue.text) + "\n\n"
        }
        return out
    }

    // MARK: - Cue derivation

    /// A single timed caption with a start + end + text. Public so callers
    /// that want to post-process or merge cues can do so before rendering.
    public struct Cue: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
    }

    /// Walk the narration entries, computing each cue's end time from the
    /// next entry's start. Filters out empty-text entries. Sorts by start
    /// time defensively so upstream providers that emit frames
    /// out-of-order still produce a coherent sidecar.
    public func derivedCues(from result: NarrationResult) -> [Cue] {
        let entries = result.narration
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.time < $1.time }

        var cues: [Cue] = []
        cues.reserveCapacity(entries.count)
        for (i, entry) in entries.enumerated() {
            let start = max(0, entry.time)
            let rawEnd: Double
            if i + 1 < entries.count {
                rawEnd = max(start + 0.1, entries[i + 1].time)
            } else {
                rawEnd = start + defaultLastCueDuration
            }
            let clampedEnd = videoDuration.map { min(rawEnd, $0) } ?? rawEnd
            cues.append(Cue(
                start: start,
                end: max(start + 0.1, clampedEnd),
                text: entry.text
            ))
        }
        return cues
    }

    // MARK: - Timecode formatting

    /// `HH:MM:SS,mmm` — SRT comma-delimited milliseconds.
    public static func srtTimecode(_ seconds: Double) -> String {
        let (h, m, s, ms) = components(seconds)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// `HH:MM:SS.mmm` — VTT period-delimited milliseconds.
    public static func vttTimecode(_ seconds: Double) -> String {
        let (h, m, s, ms) = components(seconds)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// Split a floating-point second count into H/M/S/ms components.
    /// Negative inputs clamp to zero. Fractional milliseconds round
    /// to the nearest integer.
    static func components(_ seconds: Double) -> (Int, Int, Int, Int) {
        let clamped = max(0, seconds)
        let totalMs = Int((clamped * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return (h, m, s, ms)
    }

    /// Escape text so it doesn't break SRT/VTT parsers. Mostly: collapse
    /// internal newlines to spaces (cues can be multi-line but many
    /// players render the raw newlines as literal `\n`), strip control
    /// characters that would otherwise corrupt the file.
    static func escapeCueText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(
                of: "\u{0000}",
                with: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
