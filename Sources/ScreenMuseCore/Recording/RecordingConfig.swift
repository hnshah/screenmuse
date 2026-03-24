import Foundation
import ScreenCaptureKit

// SCWindow is an ObjC class without guaranteed Sendable conformance in Swift 6,
// so we use @unchecked Sendable here. RecordingConfig is only created on the
// main actor and passed into async functions — safe in practice.
public enum CaptureSource: @unchecked Sendable {
    case fullScreen
    case window(SCWindow)
    case region(CGRect)
}

public struct RecordingConfig: @unchecked Sendable {

    /// Output video quality / bitrate preset
    public enum Quality: String, CaseIterable {
        case low    = "low"     //  1 Mbps  — ~8 MB/min  — great for agent logging
        case medium = "medium"  //  3 Mbps  — ~23 MB/min — default, shareable
        case high   = "high"    //  8 Mbps  — ~60 MB/min — presentations
        case max    = "max"     // 14 Mbps  — ~105 MB/min — archival

        public var bitrate: Int {
            switch self {
            case .low:    return 1_000_000
            case .medium: return 3_000_000
            case .high:   return 8_000_000
            case .max:    return 14_000_000
            }
        }
    }

    /// Audio source for the recording.
    public enum AudioSource: @unchecked Sendable, Equatable {
        /// Record all system audio (default)
        case system
        /// Record audio from a specific application only (app name or bundle ID)
        case appOnly(String)
        /// No audio
        case none
    }

    public let captureSource: CaptureSource
    public let includeSystemAudio: Bool
    public let includeMicrophone: Bool
    public let fps: Int
    public let quality: Quality
    /// Fine-grained audio source control. Overrides `includeSystemAudio` when set.
    public let audioSource: AudioSource

    public init(
        captureSource: CaptureSource,
        includeSystemAudio: Bool = true,
        includeMicrophone: Bool = false,
        fps: Int = 30,
        quality: Quality = .medium,
        audioSource: AudioSource = .system
    ) {
        self.captureSource = captureSource
        self.includeSystemAudio = includeSystemAudio
        self.includeMicrophone = includeMicrophone
        self.fps = fps
        self.quality = quality
        self.audioSource = audioSource
    }
}
