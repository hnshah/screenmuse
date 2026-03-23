import AVFoundation
import ScreenCaptureKit

// RecordingManager bridges two concurrency domains:
//   1. @MainActor for Published state (isRecording, duration)
//   2. SCStreamOutput callbacks on a background queue
// Properties accessed from the stream callback are marked nonisolated(unsafe)
// and protected by the fact that startRecording/stopRecording fully configure
// them before the stream begins emitting, and clear them only after stopCapture returns.
public final class RecordingManager: NSObject, ObservableObject, @unchecked Sendable {
    @Published public var isRecording = false
    @Published public var duration: TimeInterval = 0

    private var stream: SCStream?
    private var timer: Timer?

    // Accessed from SCStreamOutput callback (background queue) -- nonisolated(unsafe)
    nonisolated(unsafe) private var assetWriter: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
    nonisolated(unsafe) private var sessionStarted = false

    public override init() {
        super.init()
    }

    @MainActor
    public func startRecording(config: RecordingConfig) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        let width: Int
        let height: Int

        switch config.captureSource {
        case .fullScreen:
            guard let display = content.displays.first else {
                throw RecordingError.noDisplayFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            width = display.width * 2
            height = display.height * 2

        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            width = Int(window.frame.width) * 2
            height = Int(window.frame.height) * 2

        case .region(let rect):
            guard let display = content.displays.first else {
                throw RecordingError.noDisplayFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            width = Int(rect.width) * 2
            height = Int(rect.height) * 2
        }

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.capturesAudio = config.includeSystemAudio

        if case .region(let rect) = config.captureSource {
            streamConfig.sourceRect = rect
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "ScreenMuse_\(ISO8601DateFormatter().string(from: Date())).mp4"
        let url = tempDir.appendingPathComponent(fileName)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        writer.add(vInput)

        if config.includeSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            writer.add(aInput)
            audioInput = aInput
        }

        // Set these before calling startCapture so the stream callback sees them
        videoInput = vInput
        assetWriter = writer
        sessionStarted = false
        writer.startWriting()

        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        if config.includeSystemAudio {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }

        try await scStream.startCapture()
        stream = scStream
        isRecording = true
        duration = 0

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.duration += 1
            }
        }
    }

    @MainActor
    public func stopRecording() async throws -> URL {
        timer?.invalidate()
        timer = nil

        guard let stream else {
            throw RecordingError.notRecording
        }

        try await stream.stopCapture()
        self.stream = nil

        guard let writer = assetWriter else {
            throw RecordingError.writerNotConfigured
        }

        // Capture URL before clearing state
        let outputURL = writer.outputURL

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        isRecording = false
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false

        return outputURL
    }
}

extension RecordingManager: SCStreamOutput {
    public nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard let writer = assetWriter, writer.status == .writing else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }

        switch type {
        case .screen:
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        @unknown default:
            break
        }
    }
}

public enum RecordingError: Error, LocalizedError {
    case noDisplayFound
    case notRecording
    case writerNotConfigured

    public var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for recording"
        case .notRecording:
            return "No active recording to stop"
        case .writerNotConfigured:
            return "Asset writer was not properly configured"
        }
    }
}
