import AVFoundation
import Foundation

/// Compresses idle sections of a recording using AVMutableComposition.scaleTimeRange.
///
/// The result is a shorter video where:
///   - Active sections (typing, mouse movement) play at normal speed
///   - Idle sections (pauses, waiting) play at idleSpeed (default 4x)
///   - A brief ramp_duration eases in/out of speed changes
///
/// This runs without re-encoding the video track — the composition time-maps
/// the existing samples. Only the export step re-encodes.
public final class SpeedRamper {

    // MARK: - Types

    public struct Config: Sendable {
        /// Idle sections longer than this (seconds) get sped up. Default 2.0s.
        public var idleThresholdSec: Double = 2.0
        /// Speed multiplier for idle sections. Default 4.0x.
        public var idleSpeed: Double = 4.0
        /// Speed multiplier for active sections. Default 1.0x (no change).
        public var activeSpeed: Double = 1.0
        /// Seconds to ramp in/out at speed boundaries. Default 0.3s.
        public var rampDuration: Double = 0.3

        public init() {}
    }

    public struct SpeedRampResult: Sendable {
        public let outputURL: URL
        public let originalDuration: Double
        public let outputDuration: Double
        public let compressionRatio: Double
        public let idleSections: Int
        public let idleTotalSeconds: Double
        public let activeSections: Int
        public let activeTotalSeconds: Double
        public let fileSize: Int

        public var sizeMB: Double { Double(fileSize) / 1_048_576 }

        public func asDictionary() -> [String: Any] {
            [
                "path": outputURL.path,
                "original_duration": (originalDuration * 10).rounded() / 10,
                "output_duration": (outputDuration * 10).rounded() / 10,
                "compression_ratio": (compressionRatio * 100).rounded() / 100,
                "idle_sections": idleSections,
                "idle_total_seconds": (idleTotalSeconds * 10).rounded() / 10,
                "active_sections": activeSections,
                "active_total_seconds": (activeTotalSeconds * 10).rounded() / 10,
                "size": fileSize,
                "size_mb": (sizeMB * 100).rounded() / 100
            ]
        }
    }

    public enum SpeedRampError: Error, LocalizedError {
        case noVideoSource
        case assetLoadFailed(String)
        case compositionFailed(String)
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideoSource:
                return "No video available. Record something first, or pass 'source' with a file path."
            case .assetLoadFailed(let msg):
                return "Failed to load source video: \(msg)"
            case .compositionFailed(let msg):
                return "Composition failed: \(msg)"
            case .exportFailed(let msg):
                return "Export failed: \(msg)"
            }
        }
    }

    // MARK: - Ramp

    public func ramp(
        sourceURL: URL,
        outputURL: URL,
        segments: [ActivityAnalyzer.Segment],
        config: Config
    ) async throws -> SpeedRampResult {
        smLog.info("SpeedRamper: ramp source=\(sourceURL.lastPathComponent) idleSpeed=\(config.idleSpeed)x activeSpeed=\(config.activeSpeed)x segments=\(segments.count)", category: .recording)

        let asset = AVURLAsset(url: sourceURL)

        // Load asset tracks
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        let assetDuration: CMTime

        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            assetDuration = try await asset.load(.duration)
        } catch {
            throw SpeedRampError.assetLoadFailed(error.localizedDescription)
        }

        guard let videoTrack = videoTracks.first else {
            throw SpeedRampError.compositionFailed("Source video has no video track")
        }

        let totalSeconds = CMTimeGetSeconds(assetDuration)

        // Build AVMutableComposition with video (+ optional audio) track
        let composition = AVMutableComposition()

        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SpeedRampError.compositionFailed("Could not add video track to composition")
        }

        let compAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        // Insert the full source video
        let fullRange = CMTimeRange(start: .zero, duration: assetDuration)
        do {
            try compVideoTrack.insertTimeRange(fullRange, of: videoTrack, at: .zero)
            if let audioTrack = audioTracks.first, let compAudio = compAudioTrack {
                try compAudio.insertTimeRange(fullRange, of: audioTrack, at: .zero)
            }
        } catch {
            throw SpeedRampError.compositionFailed("insertTimeRange failed: \(error.localizedDescription)")
        }

        // Apply speed scaling — process segments in REVERSE order so earlier scaleTimeRange
        // calls don't shift the composition positions for later ones
        let sortedSegments = segments.sorted { $0.start > $1.start }

        for segment in sortedSegments {
            let speed = segment.isIdle ? config.idleSpeed : config.activeSpeed
            guard speed != 1.0 else { continue }  // skip if no change

            // Add brief ramp zones at boundaries for smooth transition
            // Main zone: clip ramp_duration from each edge
            let ramp = min(config.rampDuration, segment.duration / 4)
            let mainStart = segment.start + ramp
            let mainEnd = segment.end - ramp

            // Scale main idle section
            if mainEnd > mainStart {
                let mainSourceStart = CMTime(seconds: mainStart, preferredTimescale: 600)
                let mainSourceEnd = CMTime(seconds: mainEnd, preferredTimescale: 600)
                let mainSourceRange = CMTimeRange(start: mainSourceStart, end: mainSourceEnd)
                let mainDuration = CMTime(
                    seconds: (mainEnd - mainStart) / speed,
                    preferredTimescale: 600
                )
                composition.scaleTimeRange(mainSourceRange, toDuration: mainDuration)
            }

            // Ramp in (leading edge): gradually accelerate from 1x to idleSpeed
            if ramp > 0 && segment.start >= 0 {
                let rampSteps = 5
                let stepDuration = ramp / Double(rampSteps)
                // Process leading ramp in reverse so positions stay stable
                for i in stride(from: rampSteps - 1, through: 0, by: -1) {
                    let t = segment.start + Double(i) * stepDuration
                    let stepSpeed = 1.0 + (speed - 1.0) * (Double(i) / Double(rampSteps))
                    guard stepSpeed > 1.0 else { continue }
                    let rangeStart = CMTime(seconds: t, preferredTimescale: 600)
                    let rangeEnd = CMTime(seconds: t + stepDuration, preferredTimescale: 600)
                    let range = CMTimeRange(start: rangeStart, end: rangeEnd)
                    let scaledDuration = CMTime(seconds: stepDuration / stepSpeed, preferredTimescale: 600)
                    composition.scaleTimeRange(range, toDuration: scaledDuration)
                }
            }

            // Ramp out (trailing edge): gradually decelerate from idleSpeed to 1x
            if ramp > 0 && mainEnd < totalSeconds {
                let rampSteps = 5
                let stepDuration = ramp / Double(rampSteps)
                for i in stride(from: rampSteps - 1, through: 0, by: -1) {
                    let t = mainEnd + Double(i) * stepDuration
                    let stepSpeed = speed - (speed - 1.0) * (Double(i) / Double(rampSteps))
                    guard stepSpeed > 1.0 else { continue }
                    let rangeStart = CMTime(seconds: t, preferredTimescale: 600)
                    let rangeEnd = CMTime(seconds: t + stepDuration, preferredTimescale: 600)
                    let range = CMTimeRange(start: rangeStart, end: rangeEnd)
                    let scaledDuration = CMTime(seconds: stepDuration / stepSpeed, preferredTimescale: 600)
                    composition.scaleTimeRange(range, toDuration: scaledDuration)
                }
            }
        }

        // Compute output duration from composition
        let outputDurationSeconds = CMTimeGetSeconds(composition.duration)
        smLog.info("SpeedRamper: composition built — original=\(String(format:"%.1f",totalSeconds))s output=\(String(format:"%.1f",outputDurationSeconds))s ratio=\(String(format:"%.2f",totalSeconds/outputDurationSeconds))x", category: .recording)

        // Export
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw SpeedRampError.exportFailed("Could not create AVAssetExportSession")
        }

        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        // No timeRange set — export full composition

        await session.export()

        switch session.status {
        case .completed:
            break
        case .failed:
            let msg = session.error?.localizedDescription ?? "unknown"
            smLog.error("SpeedRamper: export failed — \(msg)", category: .recording)
            throw SpeedRampError.exportFailed(msg)
        default:
            throw SpeedRampError.exportFailed("Unexpected export status: \(session.status.rawValue)")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let idleSegments = segments.filter { $0.isIdle }
        let activeSegments = segments.filter { !$0.isIdle }
        let idleTotal = idleSegments.reduce(0) { $0 + $1.duration }
        let activeTotal = activeSegments.reduce(0) { $0 + $1.duration }
        let compressionRatio = totalSeconds > 0 ? totalSeconds / max(outputDurationSeconds, 0.1) : 1.0

        let result = SpeedRampResult(
            outputURL: outputURL,
            originalDuration: totalSeconds,
            outputDuration: outputDurationSeconds,
            compressionRatio: compressionRatio,
            idleSections: idleSegments.count,
            idleTotalSeconds: idleTotal,
            activeSections: activeSegments.count,
            activeTotalSeconds: activeTotal,
            fileSize: fileSize
        )

        smLog.info("SpeedRamper: ✅ done — \(String(format:"%.1f",totalSeconds))s → \(String(format:"%.1f",outputDurationSeconds))s (\(String(format:"%.1f",compressionRatio))x smaller) \(String(format:"%.2f",result.sizeMB))MB", category: .recording)
        smLog.usage("SPEEDRAMP", details: [
            "file": outputURL.lastPathComponent,
            "original": "\(String(format:"%.1f",totalSeconds))s",
            "output": "\(String(format:"%.1f",outputDurationSeconds))s",
            "ratio": "\(String(format:"%.1f",compressionRatio))x",
            "idle_sections": "\(idleSegments.count)"
        ])

        return result
    }

    // MARK: - Output URL Helper

    public static func defaultOutputURL(for sourceURL: URL, exportsDir: URL) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return exportsDir.appendingPathComponent("\(stem).ramped.mp4")
    }
}
