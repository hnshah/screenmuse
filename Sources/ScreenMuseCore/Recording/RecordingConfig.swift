import Foundation
import ScreenCaptureKit

public enum CaptureSource: Sendable {
    case fullScreen
    case window(SCWindow)
    case region(CGRect)
}

public struct RecordingConfig: Sendable {
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
