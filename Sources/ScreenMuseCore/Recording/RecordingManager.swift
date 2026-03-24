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
    private var streamConfig: SCStreamConfiguration?
    private var streamFilter: SCContentFilter?
    private var timer: Timer?
    public private(set) var isPaused = false
    private var pauseStartTime: CMTime = .zero
    private var totalPausedDuration: CMTime = .zero

    // Accessed from SCStreamOutput callback (background queue) -- nonisolated(unsafe)
    nonisolated(unsafe) private var assetWriter: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
    nonisolated(unsafe) private var sessionStarted = false
    nonisolated(unsafe) private var frameCount = 0
    nonisolated(unsafe) private var isPausedCallback = false  // read from callback queue

    public override init() {
        super.init()
    }

    @MainActor
    public func startRecording(config: RecordingConfig) async throws {
        print("🎬 RecordingManager.startRecording() called")

        // Explicitly check Screen Recording permission before attempting to start
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            print("❌ Screen Recording permission denied: \(error.localizedDescription)")
            throw RecordingError.permissionDenied(error.localizedDescription)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let filter: SCContentFilter
        let width: Int
        let height: Int

        switch config.captureSource {
        case .fullScreen:
            guard let display = content.displays.first else {
                throw RecordingError.noDisplayFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            width = display.width
            height = display.height
            print("📺 Capturing display: \(width)x\(height)")

        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            width = Int(window.frame.width)
            height = Int(window.frame.height)

        case .region(let rect):
            guard let display = content.displays.first else {
                throw RecordingError.noDisplayFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            width = Int(rect.width)
            height = Int(rect.height)
        }

        let streamConfig = SCStreamConfiguration()
        self.streamConfig = streamConfig
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.capturesAudio = config.includeSystemAudio
        streamConfig.queueDepth = 5  // Apple recommended: 5 frames in queue for smooth capture

        if case .region(let rect) = config.captureSource {
            streamConfig.sourceRect = rect
        }

        // Save to ~/Movies/ScreenMuse/ — create directory if needed
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse", isDirectory: true)
        try FileManager.default.createDirectory(at: screenMuseDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let fileName = "ScreenMuse_\(formatter.string(from: Date())).mp4"
            .replacingOccurrences(of: ":", with: "-")
        let url = screenMuseDir.appendingPathComponent(fileName)
        print("📁 Recording to: \(url.path)")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.quality.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: config.fps
            ]
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

        // Set up pixel buffer adaptor — more reliable than direct sampleBuffer append for SCStream
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        // Set these before calling startCapture so the stream callback sees them
        videoInput = vInput
        videoAdaptor = adaptor
        assetWriter = writer
        sessionStarted = false
        frameCount = 0
        writer.startWriting()
        print("✍️ AVAssetWriter started, status: \(writer.status.rawValue)")

        // Use self as delegate to catch stream errors
        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        if config.includeSystemAudio {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }

        try await scStream.startCapture()
        print("✅ SCStream.startCapture() succeeded")
        stream = scStream
        self.streamFilter = filter
        isPaused = false
        isPausedCallback = false
        totalPausedDuration = .zero
        isRecording = true
        duration = 0

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.duration += 1
                if Int(self.duration) % 3 == 0 {
                    print("🎥 Recording \(Int(self.duration))s, frames captured: \(self.frameCount)")
                }
            }
        }
    }

    @MainActor
    public func stopRecording() async throws -> URL {
        print("🛑 stopRecording() called, total frames: \(frameCount)")
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

        if frameCount == 0 {
            print("⚠️ WARNING: No frames captured — Screen Recording permission may not be fully granted")
            print("⚠️ Check System Settings → Privacy & Security → Screen Recording")
            // Don't call finishWriting on a writer with no session — it will fail with
            // "The operation could not be completed". Abort cleanly instead.
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            assetWriter = nil
            videoInput = nil
            videoAdaptor = nil
            audioInput = nil
            sessionStarted = false
            isRecording = false
            throw RecordingError.noFramesCaptured
        }

        // Capture URL before clearing state
        let outputURL = writer.outputURL

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            let errMsg = writer.error?.localizedDescription ?? "unknown"
            print("❌ AVAssetWriter failed: \(errMsg)")
            throw RecordingError.writerFailed(errMsg)
        }

        isRecording = false
        assetWriter = nil
        videoInput = nil
        videoAdaptor = nil
        audioInput = nil
        sessionStarted = false

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        print("✅ Recording saved to: \(outputURL.path) (\(fileSize) bytes, \(frameCount) frames)")
        return outputURL
    }
}

    // MARK: - Pause / Resume

    @MainActor
    public func pauseRecording() async throws {
        guard isRecording, !isPaused else {
            throw RecordingError.invalidState(isPaused ? "Already paused" : "Not recording")
        }
        guard let stream else { throw RecordingError.notRecording }
        try await stream.stopCapture()
        isPaused = true
        isPausedCallback = true
        timer?.invalidate()
        print("⏸️ Recording paused at \(duration)s")
    }

    @MainActor
    public func resumeRecording() async throws {
        guard isRecording, isPaused else {
            throw RecordingError.invalidState(isPaused ? "Not recording" : "Not paused")
        }
        guard let filter = streamFilter, let streamConf = streamConfig else {
            throw RecordingError.writerNotConfigured
        }
        // Restart stream with same filter/config
        let newStream = SCStream(filter: filter, configuration: streamConf, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await newStream.startCapture()
        stream = newStream
        isPaused = false
        isPausedCallback = false
        print("▶️ Recording resumed")

        // Restart duration timer
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.duration += 1
            }
        }
    }
}

// MARK: - SCStreamOutput

extension RecordingManager: SCStreamOutput {
    public nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // Apple required: check validity first
        guard sampleBuffer.isValid else { return }

        guard let writer = assetWriter else {
            if frameCount == 0 { print("❌ Frame arrived but assetWriter is nil!") }
            return
        }
        guard writer.status == .writing else {
            if frameCount == 0 { print("❌ Frame arrived but writer status=\(writer.status.rawValue), error=\(writer.error?.localizedDescription ?? "none")") }
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
            print("▶️ Writer session started at \(timestamp.seconds)s")
        }

        switch type {
        case .screen:
            // Apple required: check frame status before using pixel data
            // Frames with .idle/.started status have no actual pixel content
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first,
                  let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else {
                return
            }

            // Use pixel buffer adaptor — the production-verified pattern for SCStream
            if let adaptor = videoAdaptor,
               let videoInput = videoInput,
               videoInput.isReadyForMoreMediaData,
               let pixelBuffer = sampleBuffer.imageBuffer {
                let success = adaptor.append(pixelBuffer, withPresentationTime: timestamp)
                frameCount += 1
                if frameCount == 1 { print("📹 First complete video frame captured! adaptor.append success=\(success)") }
                if !success && frameCount < 5 {
                    print("⚠️ Failed to append frame \(frameCount), writer error: \(assetWriter?.error?.localizedDescription ?? "none")")
                }
            } else if frameCount == 0 {
                let hasAdaptor = videoAdaptor != nil
                let hasInput = videoInput != nil
                let hasPixelBuffer = sampleBuffer.imageBuffer != nil
                let isReady = videoInput?.isReadyForMoreMediaData ?? false
                print("❌ Frame dropped: adaptor=\(hasAdaptor) input=\(hasInput) pixelBuf=\(hasPixelBuffer) ready=\(isReady)")
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

// MARK: - SCStreamDelegate

extension RecordingManager: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ SCStream stopped with error: \(error.localizedDescription)")
        Task { @MainActor in
            self.isRecording = false
        }
    }
}

// MARK: - Errors

public enum RecordingError: Error, LocalizedError {
    case noDisplayFound
    case notRecording
    case writerNotConfigured
    case writerFailed(String)
    case permissionDenied(String)
    case noFramesCaptured
    case windowNotFound(String)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for recording"
        case .notRecording:
            return "No active recording to stop"
        case .writerNotConfigured:
            return "Asset writer was not properly configured"
        case .writerFailed(let msg):
            return "Recording failed: \(msg)"
        case .permissionDenied(let msg):
            return "Screen Recording permission denied — grant it in System Settings → Privacy & Security → Screen Recording. (\(msg))"
        case .noFramesCaptured:
            return "No frames were captured — Screen Recording permission may not be granted, or the stream delivered no content. Grant permission in System Settings → Privacy & Security → Screen Recording, then relaunch."
        case .windowNotFound(let query):
            return "Window not found: '\(query)'. Use GET /windows to list available windows."
        case .invalidState(let msg):
            return "Invalid state: \(msg)"
        }
    }
}
