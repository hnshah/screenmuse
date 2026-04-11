import AVFoundation
import AppKit
import Foundation

/// High-level narration orchestrator — extracts frames from a video,
/// hands them to a `NarrationProvider`, and returns the structured result.
///
/// This type is provider-agnostic. The HTTP handler picks which provider
/// to use based on the request `provider` field and passes it to `run()`.
public struct Narrator: Sendable {

    public let provider: NarrationProvider

    public init(provider: NarrationProvider) {
        self.provider = provider
    }

    /// Full narration pipeline for a video file.
    ///
    /// Extracts `frameCount` frames evenly distributed across the video
    /// (skipping the first and last 1% to avoid cold-start / fade-out
    /// frames), JPEG-encodes them, and calls the provider.
    public func run(
        video: URL,
        frameCount: Int,
        config: NarrationConfig
    ) async throws -> NarrationResult {
        let frames = try await extractFrames(video: video, count: frameCount)
        guard !frames.isEmpty else { throw NarrationError.noFramesExtracted }
        return try await provider.narrate(frames: frames, config: config)
    }

    // MARK: - Frame extraction

    /// Extract `count` frames evenly distributed across the video duration,
    /// ignoring the first and last 1% to skip fade-in/fade-out.
    ///
    /// Returns them encoded as JPEG bytes so providers can forward them
    /// directly as base64 without another round-trip through UIImage.
    public func extractFrames(video: URL, count: Int) async throws -> [NarrationFrame] {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(duration)
        guard durationSec > 0, count > 0 else { return [] }

        let startSec = durationSec * 0.01
        let endSec   = durationSec * 0.99
        let span     = max(0.001, endSec - startSec)
        let step     = span / Double(max(1, count - 1))

        var timestamps: [Double] = []
        if count == 1 {
            timestamps = [durationSec / 2.0]
        } else {
            for i in 0..<count {
                timestamps.append(startSec + Double(i) * step)
            }
        }

        return try await Self.encodeFrames(asset: asset, timestamps: timestamps)
    }

    /// JPEG-encode each requested frame. Runs the AVAssetImageGenerator
    /// loop off the MainActor so the HTTP listener stays responsive.
    static func encodeFrames(
        asset: AVAsset,
        timestamps: [Double]
    ) async throws -> [NarrationFrame] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.25, preferredTimescale: 600)

        var frames: [NarrationFrame] = []
        for ts in timestamps {
            let cmTime = CMTime(seconds: ts, preferredTimescale: 600)
            do {
                let (cgImage, _) = try await generator.image(at: cmTime)
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let jpegData = rep.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: 0.75]
                ) else { continue }
                frames.append(NarrationFrame(
                    time: ts,
                    imageData: jpegData,
                    width: cgImage.width,
                    height: cgImage.height
                ))
            } catch {
                // Skip unreadable frames; we'd rather return a partial
                // result than throw out the whole narration pipeline
                // because one timestamp landed on a bad keyframe.
                continue
            }
        }
        return frames
    }

    // MARK: - Provider factory

    /// Resolve a provider by wire name. Returns `nil` for unknown names so
    /// the caller can surface a structured 400.
    public static func provider(named name: String) -> NarrationProvider? {
        switch name.lowercased() {
        case "ollama", "local", "":
            return OllamaNarrationProvider()
        case "anthropic", "claude":
            return ClaudeNarrationProvider()
        default:
            return nil
        }
    }

    /// Known provider names in preference order.
    public static let knownProviders = ["ollama", "anthropic"]
}
