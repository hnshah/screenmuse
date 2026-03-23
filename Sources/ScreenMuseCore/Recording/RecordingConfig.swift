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
    public let captureSource: CaptureSource
    public let includeSystemAudio: Bool
    public let includeMicrophone: Bool
    public let fps: Int

    public init(
        captureSource: CaptureSource,
        includeSystemAudio: Bool = true,
        includeMicrophone: Bool = false,
        fps: Int = 30
    ) {
        self.captureSource = captureSource
        self.includeSystemAudio = includeSystemAudio
        self.includeMicrophone = includeMicrophone
        self.fps = fps
    }
}
