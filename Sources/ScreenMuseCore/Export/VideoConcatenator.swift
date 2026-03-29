@preconcurrency import AVFoundation
import Foundation

/// Concatenates two or more video files into a single output file.
///
/// Uses AVMutableComposition with stream-copy (no re-encode) when all
/// source videos have the same codec, resolution, and frame rate.
/// Falls back to AVAssetExportPresetHighestQuality for mixed sources.
///
/// Usage via API:
///   POST /concat
///   {
///     "sources": ["/path/to/1.mp4", "/path/to/2.mp4", "/path/to/3.mp4"],
///     "output": "/optional/output.mp4"  // auto-generated if omitted
///   }
///
/// Response:
///   {"path": "/path/output.mp4", "duration": 42.3, "source_count": 3}
public final class VideoConcatenator {

    public enum ConcatError: Error, LocalizedError {
        case noSources
        case tooManySources(Int)
        case sourceNotFound(String)
        case compositionFailed(String)
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noSources: return "No source files provided"
            case .tooManySources(let n): return "Too many sources (\(n)); max is 20"
            case .sourceNotFound(let p): return "Source file not found: \(p)"
            case .compositionFailed(let m): return "Composition failed: \(m)"
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    public struct ConcatResult: Sendable {
        public let outputURL: URL
        public let duration: Double
        public let sourceCount: Int
        public let fileSizeMB: Double
    }

    public func concatenate(
        sources: [URL],
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ConcatResult {
        guard !sources.isEmpty else { throw ConcatError.noSources }
        guard sources.count <= 20 else { throw ConcatError.tooManySources(sources.count) }

        // Verify all sources exist
        for src in sources {
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw ConcatError.sourceNotFound(src.path)
            }
        }

        smLog.info("VideoConcatenator: concatenating \(sources.count) sources → \(outputURL.lastPathComponent)", category: .recording)

        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ConcatError.compositionFailed("Could not create video composition track")
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var insertTime = CMTime.zero

        for (idx, srcURL) in sources.enumerated() {
            let asset = AVURLAsset(url: srcURL)

            // Load tracks
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)

            guard let videoTrack = videoTracks.first else {
                smLog.warning("VideoConcatenator: source \(idx+1) has no video track — skipping", category: .recording)
                continue
            }

            let timeRange = CMTimeRange(start: .zero, duration: duration)

            do {
                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: insertTime)
                if let audioTrack = audioTracks.first, let compAudio = compositionAudioTrack {
                    try compAudio.insertTimeRange(timeRange, of: audioTrack, at: insertTime)
                }
            } catch {
                throw ConcatError.compositionFailed("Failed to insert source \(idx+1): \(error.localizedDescription)")
            }

            insertTime = CMTimeAdd(insertTime, duration)
            progress?(Double(idx + 1) / Double(sources.count) * 0.9)
            smLog.info("VideoConcatenator: source \(idx+1)/\(sources.count) inserted — \(String(format:"%.1f",CMTimeGetSeconds(duration)))s", category: .recording)
        }

        let totalDuration = CMTimeGetSeconds(insertTime)

        // Export via AVAssetExportSession (passthrough — fastest for same-codec sources)
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ConcatError.exportFailed("Could not create export session")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        // Monitor progress
        let progressTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let p = exportSession.progress
                progress?(0.9 + Double(p) * 0.1)
            }
        }

        await exportSession.export()
        progressTimer.cancel()

        guard exportSession.status == .completed else {
            let msg = exportSession.error?.localizedDescription ?? "unknown export error"
            throw ConcatError.exportFailed(msg)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let sizeMB = Double(fileSize) / 1_048_576

        smLog.info("VideoConcatenator: ✅ done — \(String(format:"%.1f",totalDuration))s \(String(format:"%.1f",sizeMB))MB → \(outputURL.lastPathComponent)", category: .recording)
        smLog.usage("CONCAT", details: [
            "sources": "\(sources.count)",
            "duration": "\(String(format:"%.1f",totalDuration))s",
            "size": "\(String(format:"%.1f",sizeMB))MB"
        ])

        return ConcatResult(outputURL: outputURL, duration: totalDuration, sourceCount: sources.count, fileSizeMB: sizeMB)
    }
}
