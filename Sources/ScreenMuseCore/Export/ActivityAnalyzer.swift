import AVFoundation
import Foundation

/// Analyzes a recording's event timeline to find active vs idle segments.
///
/// Two modes:
///   1. Agent event data (preferred) — cursor + keyboard events captured during recording
///   2. Audio energy fallback — when no event data is available (external videos)
///
/// The output is a flat array of Segments covering 0...duration with no gaps.
public final class ActivityAnalyzer {

    // MARK: - Types

    public struct Segment: Sendable {
        /// Start time in seconds from recording start
        public let start: Double
        /// End time in seconds from recording start
        public let end: Double
        /// True if this section had no user activity for >= idleThreshold
        public let isIdle: Bool

        public var duration: Double { end - start }

        public init(start: Double, end: Double, isIdle: Bool) {
            self.start = start
            self.end = end
            self.isIdle = isIdle
        }
    }

    // MARK: - From Agent Event Data

    /// Produce segments from captured cursor + keyboard events.
    ///
    /// Algorithm:
    ///   1. Collect all event timestamps, sort ascending
    ///   2. Walk the timeline; any gap > idleThreshold is an idle segment
    ///   3. Fill remaining spans as active
    ///   4. Merge consecutive segments of the same type
    ///
    /// - Parameters:
    ///   - cursorEvents: From CursorTracker.events, already have Date timestamps
    ///   - keystrokeTimestamps: From KeyboardMonitor events (Date timestamps)
    ///   - recordingStart: The Date when recording began (used to normalize to seconds)
    ///   - duration: Total recording duration in seconds
    ///   - idleThreshold: Gaps longer than this (seconds) are classified as idle
    public func analyze(
        cursorEvents: [CursorEvent],
        keystrokeTimestamps: [Date],
        recordingStart: Date,
        duration: Double,
        idleThreshold: Double
    ) -> [Segment] {
        smLog.info("ActivityAnalyzer: analyzing \(cursorEvents.count) cursor events + \(keystrokeTimestamps.count) keystrokes over \(String(format:"%.1f",duration))s", category: .recording)

        // Collect all event times in seconds-from-start, sorted
        var eventTimes: [Double] = []
        for e in cursorEvents {
            let t = e.timestamp.timeIntervalSince(recordingStart)
            if t >= 0 && t <= duration { eventTimes.append(t) }
        }
        for t in keystrokeTimestamps {
            let s = t.timeIntervalSince(recordingStart)
            if s >= 0 && s <= duration { eventTimes.append(s) }
        }
        eventTimes.sort()

        if eventTimes.isEmpty {
            smLog.warning("ActivityAnalyzer: no event data — marking entire recording as active", category: .recording)
            return [Segment(start: 0, end: duration, isIdle: false)]
        }

        // Build raw segments by walking gaps between events
        var rawSegments: [Segment] = []
        var cursor: Double = 0

        for t in eventTimes {
            guard t > cursor else { continue }  // skip duplicate/same-time events
            let gap = t - cursor
            // The span [cursor, t] is a gap between consecutive events.
            // If the gap exceeds idleThreshold, classify it as idle.
            // Otherwise classify as active (user was typing/moving between events).
            rawSegments.append(Segment(start: cursor, end: t, isIdle: gap > idleThreshold))
            cursor = t
        }

        // Tail: from last event to end of recording
        if cursor < duration {
            let tail = duration - cursor
            rawSegments.append(Segment(start: cursor, end: duration, isIdle: tail > idleThreshold))
        }

        // Merge consecutive same-type segments
        let merged = mergeSegments(rawSegments)

        let idleCount = merged.filter { $0.isIdle }.count
        let idleSeconds = merged.filter { $0.isIdle }.reduce(0) { $0 + $1.duration }
        smLog.info("ActivityAnalyzer: \(merged.count) segments — \(idleCount) idle (\(String(format:"%.1f",idleSeconds))s), \(merged.count - idleCount) active", category: .recording)

        return merged
    }

    // MARK: - From Audio Energy (Fallback)

    /// Analyze audio amplitude to detect idle (silent) sections.
    /// Used when no cursor/keyboard event data is available.
    ///
    /// - Parameters:
    ///   - asset: The video asset to analyze
    ///   - idleThreshold: Minimum silence duration in seconds to classify as idle
    ///   - silenceLevel: dBFS threshold for silence (default -40 dB)
    public func analyzeFromAudio(
        asset: AVAsset,
        duration: Double,
        idleThreshold: Double,
        silenceLevel: Float = -40.0
    ) async throws -> [Segment] {
        smLog.info("ActivityAnalyzer: audio energy fallback analysis over \(String(format:"%.1f",duration))s", category: .recording)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            smLog.warning("ActivityAnalyzer: no audio track — marking all active", category: .recording)
            return [Segment(start: 0, end: duration, isIdle: false)]
        }

        // Use AVAssetReader to read PCM samples and measure amplitude per chunk
        guard let reader = try? AVAssetReader(asset: asset) else {
            return [Segment(start: 0, end: duration, isIdle: false)]
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsSigned: true
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            smLog.warning("ActivityAnalyzer: AVAssetReader startReading failed", category: .recording)
            return [Segment(start: 0, end: duration, isIdle: false)]
        }

        // Chunk size: 0.1s worth of samples (44100Hz → 4410 samples per chunk)
        let sampleRate: Double = 44100
        let chunkSize = Int(sampleRate * 0.1)  // 100ms chunks
        var chunkEnergies: [(time: Double, energy: Float)] = []
        var sampleIndex = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = length / 2  // 16-bit = 2 bytes per sample

            var data = [Int16](repeating: 0, count: sampleCount)
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)

            // Compute RMS energy per chunk
            var i = 0
            while i < sampleCount {
                let end = min(i + chunkSize, sampleCount)
                let chunk = data[i..<end]
                let rms = sqrt(chunk.map { Float($0) * Float($0) }.reduce(0, +) / Float(chunk.count))
                let dbfs = rms > 0 ? 20 * log10(rms / 32768.0) : -96.0
                let time = Double(sampleIndex + i) / sampleRate
                chunkEnergies.append((time: time, energy: dbfs))
                i += chunkSize
            }
            sampleIndex += sampleCount
        }

        if chunkEnergies.isEmpty {
            return [Segment(start: 0, end: duration, isIdle: false)]
        }

        // Convert energy series to segments
        var rawSegments: [Segment] = []
        var segStart = 0.0
        var segIdle = chunkEnergies[0].energy < silenceLevel

        for chunk in chunkEnergies.dropFirst() {
            let chunkIsIdle = chunk.energy < silenceLevel
            if chunkIsIdle != segIdle {
                rawSegments.append(Segment(start: segStart, end: chunk.time, isIdle: segIdle))
                segStart = chunk.time
                segIdle = chunkIsIdle
            }
        }
        rawSegments.append(Segment(start: segStart, end: duration, isIdle: segIdle))

        // Filter: only treat as idle if silence duration >= threshold
        let filtered = rawSegments.map { seg in
            Segment(start: seg.start, end: seg.end, isIdle: seg.isIdle && seg.duration >= idleThreshold)
        }

        let merged = mergeSegments(filtered)
        let idleSeconds = merged.filter { $0.isIdle }.reduce(0) { $0 + $1.duration }
        smLog.info("ActivityAnalyzer (audio): \(merged.count) segments, idle=\(String(format:"%.1f",idleSeconds))s", category: .recording)
        return merged
    }

    // MARK: - Private

    private func mergeSegments(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        for seg in segments {
            if let last = result.last, last.isIdle == seg.isIdle {
                result[result.count - 1] = Segment(start: last.start, end: seg.end, isIdle: last.isIdle)
            } else {
                result.append(seg)
            }
        }
        return result
    }
}
