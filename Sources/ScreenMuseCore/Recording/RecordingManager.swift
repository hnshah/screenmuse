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

    // Frame stats for periodic logging (nonisolated(unsafe) — only written from callback, read on main)
    nonisolated(unsafe) private var droppedFrameCount = 0
    nonisolated(unsafe) private var audioSampleCount = 0

    public override init() {
        super.init()
        smLog.debug("RecordingManager initialised", category: .recording)
    }

    @MainActor
    public func startRecording(config: RecordingConfig) async throws {
        smLog.info("startRecording() called — source=\(config.captureSource) quality=\(config.quality.rawValue) fps=\(config.fps) audio=\(config.includeSystemAudio)", category: .recording)

        // Explicitly check Screen Recording permission before attempting to start
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            smLog.debug("Screen Recording permission confirmed", category: .permissions)
        } catch {
            smLog.error("Screen Recording permission denied: \(error.localizedDescription)", category: .permissions)
            throw RecordingError.permissionDenied(error.localizedDescription)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        smLog.debug("SCShareableContent loaded — displays=\(content.displays.count) windows=\(content.windows.count) apps=\(content.applications.count)", category: .recording)

        let filter: SCContentFilter
        let width: Int
        let height: Int

        switch config.captureSource {
        case .fullScreen:
            guard let display = content.displays.first else {
                smLog.error("No display found — cannot start recording", category: .recording)
                throw RecordingError.noDisplayFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            width = display.width
            height = display.height
            smLog.info("Capture mode: fullScreen \(width)x\(height)", category: .recording)

        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            width = Int(window.frame.width)
            height = Int(window.frame.height)
            smLog.info("Capture mode: window '\(window.title ?? "?")' \(width)x\(height) pid=\(window.owningApplication?.processID ?? 0)", category: .recording)

        case .region(let rect):
            guard let display = content.displays.first else {
                smLog.error("No display found for region capture", category: .recording)
                throw RecordingError.noDisplayFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            width = Int(rect.width)
            height = Int(rect.height)
            smLog.info("Capture mode: region \(rect) on display \(display.width)x\(display.height)", category: .recording)
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

        smLog.debug("SCStreamConfiguration — \(width)x\(height) fps=\(config.fps) audio=\(config.includeSystemAudio) queueDepth=5", category: .recording)

        // Save to ~/Movies/ScreenMuse/ — create directory if needed
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse", isDirectory: true)
        try FileManager.default.createDirectory(at: screenMuseDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let fileName = "ScreenMuse_\(formatter.string(from: Date())).mp4"
            .replacingOccurrences(of: ":", with: "-")
        let url = screenMuseDir.appendingPathComponent(fileName)
        smLog.info("Output file: \(url.path)", category: .recording)

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
        smLog.debug("Video settings — codec=H264 bitrate=\(config.quality.bitrate) profile=H264HighAutoLevel", category: .recording)

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
            smLog.debug("Audio track added — AAC 48kHz stereo", category: .recording)
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
        droppedFrameCount = 0
        audioSampleCount = 0
        writer.startWriting()
        smLog.info("AVAssetWriter.startWriting() — status=\(writer.status.rawValue) url=\(url.lastPathComponent)", category: .recording)

        if writer.status == .failed {
            smLog.error("AVAssetWriter failed immediately after startWriting: \(writer.error?.localizedDescription ?? "unknown")", category: .recording)
        }

        // Use self as delegate to catch stream errors
        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        smLog.debug("SCStream screen output registered", category: .recording)
        if config.includeSystemAudio {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            smLog.debug("SCStream audio output registered", category: .recording)
        }

        smLog.info("Calling SCStream.startCapture()...", category: .recording)
        try await scStream.startCapture()
        smLog.info("✅ SCStream.startCapture() succeeded — recording is live", category: .recording)

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
                // Periodic heartbeat log every 5 seconds
                if Int(self.duration) % 5 == 0 {
                    smLog.debug("🎥 Recording heartbeat — elapsed=\(Int(self.duration))s frames=\(self.frameCount) dropped=\(self.droppedFrameCount) audio=\(self.audioSampleCount)", category: .recording)
                }
            }
        }
    }

    @MainActor
    public func stopRecording() async throws -> URL {
        smLog.info("stopRecording() called — elapsed=\(String(format: "%.1f", duration))s paused=\(isPaused) totalFrames=\(frameCount) droppedFrames=\(droppedFrameCount) audioSamples=\(audioSampleCount)", category: .recording)
        timer?.invalidate()
        timer = nil

        // If paused, the SCStream is already stopped — calling stopCapture() again would throw.
        // We only stop the stream if it's actively running.
        if let stream {
            if isPaused {
                smLog.debug("Stream was paused — skipping stopCapture() (already stopped)", category: .recording)
            } else {
                smLog.debug("Calling SCStream.stopCapture()...", category: .recording)
                try await stream.stopCapture()
                smLog.info("SCStream.stopCapture() completed", category: .recording)
            }
            self.stream = nil
        } else {
            smLog.error("stopRecording() called but stream is nil — writer may still need finalizing", category: .recording)
        }

        guard let writer = assetWriter else {
            smLog.error("assetWriter is nil — recording was never properly started", category: .recording)
            throw RecordingError.writerNotConfigured
        }

        if frameCount == 0 {
            smLog.warning("⚠️ Zero frames captured — Screen Recording permission may not be fully granted", category: .recording)
            smLog.warning("Check: System Settings → Privacy & Security → Screen Recording", category: .permissions)
            smLog.warning("Also try: ./scripts/reset-permissions.sh", category: .permissions)
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

        let outputURL = writer.outputURL
        smLog.debug("Marking inputs as finished and calling finishWriting...", category: .recording)
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            let errMsg = writer.error?.localizedDescription ?? "unknown"
            smLog.error("AVAssetWriter.finishWriting() failed: \(errMsg)", category: .recording)
            throw RecordingError.writerFailed(errMsg)
        }

        isRecording = false
        assetWriter = nil
        videoInput = nil
        videoAdaptor = nil
        audioInput = nil
        sessionStarted = false

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let fileSizeMB = Double(fileSize) / 1_048_576
        smLog.info("✅ Recording saved — path=\(outputURL.path) size=\(String(format: "%.2f", fileSizeMB))MB frames=\(frameCount) duration=\(String(format: "%.1f", duration))s", category: .recording)
        return outputURL
    }
}

// MARK: - Pause / Resume

extension RecordingManager {
    @MainActor
    public func pauseRecording() async throws {
        guard isRecording, !isPaused else {
            let reason = isPaused ? "Already paused" : "Not recording"
            smLog.warning("pauseRecording() rejected — \(reason)", category: .recording)
            throw RecordingError.invalidState(isPaused ? "Already paused" : "Not recording")
        }
        guard let stream else {
            smLog.error("pauseRecording() — no stream reference", category: .recording)
            throw RecordingError.notRecording
        }
        smLog.info("Pausing stream at elapsed=\(String(format: "%.1f", duration))s", category: .recording)
        try await stream.stopCapture()
        self.stream = nil  // nil out so stopRecording() won't call stopCapture() again on a dead stream
        isPaused = true
        isPausedCallback = true
        timer?.invalidate()
        smLog.info("⏸️ Paused — frames so far: \(frameCount)", category: .recording)
    }

    @MainActor
    public func resumeRecording() async throws {
        guard isRecording, isPaused else {
            let reason = !isRecording ? "Not recording" : "Not paused"
            smLog.warning("resumeRecording() rejected — \(reason)", category: .recording)
            throw RecordingError.invalidState(!isRecording ? "Not recording" : "Not paused")
        }
        guard let filter = streamFilter, let streamConf = streamConfig else {
            smLog.error("resumeRecording() — streamFilter or streamConfig is nil", category: .recording)
            throw RecordingError.writerNotConfigured
        }
        smLog.info("Resuming stream from elapsed=\(String(format: "%.1f", duration))s", category: .recording)
        let newStream = SCStream(filter: filter, configuration: streamConf, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await newStream.startCapture()
        stream = newStream
        isPaused = false
        isPausedCallback = false
        smLog.info("▶️ Resumed — frames so far: \(frameCount)", category: .recording)

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
        guard sampleBuffer.isValid else {
            smLog.debug("Invalid sample buffer received — skipping", category: .recording)
            return
        }

        guard let writer = assetWriter else {
            if frameCount == 0 {
                smLog.error("Frame arrived but assetWriter is nil — writer may have failed to initialise", category: .recording)
            }
            return
        }
        guard writer.status == .writing else {
            if frameCount == 0 {
                smLog.error("Frame arrived but writer.status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none")", category: .recording)
            }
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
            smLog.info("▶️ AVAssetWriter session started at t=\(String(format: "%.3f", timestamp.seconds))s", category: .recording)
        }

        switch type {
        case .screen:
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first,
                  let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else {
                return
            }

            if let adaptor = videoAdaptor,
               let videoInput = videoInput,
               videoInput.isReadyForMoreMediaData,
               let pixelBuffer = sampleBuffer.imageBuffer {
                let success = adaptor.append(pixelBuffer, withPresentationTime: timestamp)
                frameCount += 1
                if frameCount == 1 {
                    smLog.info("📹 First video frame captured successfully — adaptor.append=\(success)", category: .recording)
                }
                if !success {
                    droppedFrameCount += 1
                    if droppedFrameCount <= 5 || droppedFrameCount % 50 == 0 {
                        smLog.warning("Frame append failed #\(droppedFrameCount) — writer error: \(assetWriter?.error?.localizedDescription ?? "none")", category: .recording)
                    }
                }
            } else if frameCount == 0 {
                let hasAdaptor = videoAdaptor != nil
                let hasInput = videoInput != nil
                let hasPixelBuffer = sampleBuffer.imageBuffer != nil
                let isReady = videoInput?.isReadyForMoreMediaData ?? false
                droppedFrameCount += 1
                smLog.error("Frame dropped — adaptor=\(hasAdaptor) input=\(hasInput) pixelBuf=\(hasPixelBuffer) ready=\(isReady)", category: .recording)
            }

        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
                audioSampleCount += 1
                if audioSampleCount == 1 {
                    smLog.debug("First audio sample captured", category: .recording)
                }
            }

        @unknown default:
            smLog.warning("Unknown SCStreamOutputType: \(type) — ignoring", category: .recording)
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension RecordingManager: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        smLog.error("SCStream stopped unexpectedly: \(error.localizedDescription)", category: .recording)
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
