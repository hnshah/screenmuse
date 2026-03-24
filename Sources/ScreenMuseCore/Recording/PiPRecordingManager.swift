import AVFoundation
import CoreImage
import Foundation
import ScreenCaptureKit

/// Records two windows simultaneously and composites them into a single video.
///
/// The primary window fills the frame. The overlay window is scaled and positioned
/// in a corner (picture-in-picture). Both streams run concurrently; frames are
/// synchronized by timestamp and composited using CIImage before writing to disk.
///
/// Layout options:
///   picture-in-picture: overlay in bottom-right corner (default)
///   side-by-side:       primary left, overlay right, equal width
///   stacked:            primary top, overlay bottom, equal height
///
/// Audio: captured from primary window's stream only (avoiding double audio).
///
/// Usage:
///   let manager = PiPRecordingManager()
///   try await manager.startRecording(primary: window1, overlay: window2, config: pipConfig)
///   let url = try await manager.stopRecording()

@MainActor
public final class PiPRecordingManager: NSObject {

    // MARK: - Types

    public enum Layout: String, Sendable {
        case pictureInPicture = "picture-in-picture"
        case sideBySide = "side-by-side"
        case stacked = "stacked"
    }

    public struct PiPConfig: Sendable {
        public var layout: Layout = .pictureInPicture
        /// PiP overlay size relative to main frame (0.0–1.0). Default 0.25 (25% of width).
        public var overlayScale: Double = 0.25
        /// Video quality
        public var quality: RecordingConfig.Quality = .medium
        /// FPS for both streams
        public var fps: Int = 30
        /// Whether to capture audio from the primary window
        public var includeAudio: Bool = true

        public init() {}
    }

    public enum PiPError: Error, LocalizedError {
        case alreadyRecording
        case notRecording
        case windowSetupFailed(String)
        case writerSetupFailed(String)
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Already recording. Stop the current session first."
            case .notRecording: return "Not recording."
            case .windowSetupFailed(let m): return "Window setup failed: \(m)"
            case .writerSetupFailed(let m): return "Writer setup failed: \(m)"
            case .exportFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    // MARK: - State

    public private(set) var isRecording = false
    public private(set) var outputURL: URL?
    public private(set) var frameCount = 0

    private var primaryStream: SCStream?
    private var overlayStream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Latest frame from each stream (thread-safe via MainActor)
    private var latestPrimaryPixelBuffer: CVPixelBuffer?
    private var latestOverlayPixelBuffer: CVPixelBuffer?
    private var sessionStartTime: CMTime?
    private var config = PiPConfig()
    private var outputSize = CGSize(width: 1920, height: 1080)

    // MARK: - Start

    public func startRecording(
        primaryWindow: SCWindow,
        overlayWindow: SCWindow,
        config: PiPConfig
    ) async throws {
        guard !isRecording else { throw PiPError.alreadyRecording }
        smLog.info("PiPRecordingManager: start layout=\(config.layout.rawValue) primary='\(primaryWindow.title ?? "?")' overlay='\(overlayWindow.title ?? "?")'", category: .recording)

        self.config = config

        // Compute output dimensions
        let primarySize = primaryWindow.frame.size
        outputSize = computeOutputSize(primarySize: primarySize, layout: config.layout, overlayScale: config.overlayScale)

        // Set up AVAssetWriter
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse", isDirectory: true)
        try FileManager.default.createDirectory(at: screenMuseDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let fileName = "ScreenMuse_PiP_\(formatter.string(from: Date())).mp4".replacingOccurrences(of: ":", with: "-")
        let url = screenMuseDir.appendingPathComponent(fileName)
        outputURL = url

        guard let assetWriter = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw PiPError.writerSetupFailed("Could not create AVAssetWriter at \(url.path)")
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.quality.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: config.fps
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: adaptorAttrs)

        assetWriter.add(vInput)

        if config.includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            assetWriter.add(aInput)
            audioInput = aInput
        }

        self.writer = assetWriter
        self.videoInput = vInput
        self.pixelAdaptor = adaptor

        // Start both SCStreams
        let streamCfg = SCStreamConfiguration()
        streamCfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamCfg.pixelFormat = kCVPixelFormatType_32BGRA
        streamCfg.capturesAudio = false  // Only primary stream captures audio
        streamCfg.queueDepth = 3

        // Primary stream (full quality)
        let primaryFilter = SCContentFilter(desktopIndependentWindow: primaryWindow)
        let primaryStreamCfg = streamCfg.mutableCopy() as! SCStreamConfiguration
        primaryStreamCfg.width = Int(primaryWindow.frame.width)
        primaryStreamCfg.height = Int(primaryWindow.frame.height)
        primaryStreamCfg.capturesAudio = config.includeAudio

        let primary = SCStream(filter: primaryFilter, configuration: primaryStreamCfg, delegate: nil)
        try primary.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        if config.includeAudio {
            try primary.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }

        // Overlay stream (can be lower res — we'll scale it down anyway)
        let overlayFilter = SCContentFilter(desktopIndependentWindow: overlayWindow)
        let overlayStreamCfg = streamCfg.mutableCopy() as! SCStreamConfiguration
        overlayStreamCfg.width = Int(overlayWindow.frame.width)
        overlayStreamCfg.height = Int(overlayWindow.frame.height)

        let overlay = SCStream(filter: overlayFilter, configuration: overlayStreamCfg, delegate: nil)
        try overlay.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        primaryStream = primary
        overlayStream = overlay

        assetWriter.startWriting()
        // startSession called on first frame to get accurate CMTime

        try await primary.startCapture()
        try await overlay.startCapture()

        isRecording = true
        frameCount = 0
        smLog.info("PiPRecordingManager: ✅ both streams started — output \(Int(outputSize.width))×\(Int(outputSize.height)) → \(url.lastPathComponent)", category: .recording)
        smLog.usage("PIP RECORD START", details: ["layout": config.layout.rawValue, "primary": primaryWindow.title ?? "?", "overlay": overlayWindow.title ?? "?"])
    }

    // MARK: - Stop

    public func stopRecording() async throws -> URL {
        guard isRecording, let writer, let url = outputURL else {
            throw PiPError.notRecording
        }
        smLog.info("PiPRecordingManager: stopping — \(frameCount) frames written", category: .recording)
        isRecording = false

        // Stop both streams
        try? await primaryStream?.stopCapture()
        try? await overlayStream?.stopCapture()
        primaryStream = nil
        overlayStream = nil

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await writer.finishWriting()
        if writer.status == .failed {
            let msg = writer.error?.localizedDescription ?? "unknown"
            smLog.error("PiPRecordingManager: finishWriting failed — \(msg)", category: .recording)
            throw PiPError.exportFailed(msg)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        smLog.info("PiPRecordingManager: ✅ saved — \(url.lastPathComponent) \(frameCount) frames \(String(format:"%.2f",Double(fileSize)/1_048_576))MB", category: .recording)
        smLog.usage("PIP RECORD STOP", details: ["file": url.lastPathComponent, "frames": "\(frameCount)", "size": "\(String(format:"%.2f",Double(fileSize)/1_048_576))MB"])

        return url
    }

    // MARK: - Layout

    private func computeOutputSize(primarySize: CGSize, layout: Layout, overlayScale: Double) -> CGSize {
        // Round to even dimensions (required by H.264)
        func even(_ v: CGFloat) -> CGFloat { CGFloat(Int(v) & ~1) }
        switch layout {
        case .pictureInPicture:
            return CGSize(width: even(primarySize.width), height: even(primarySize.height))
        case .sideBySide:
            return CGSize(width: even(primarySize.width * 2), height: even(primarySize.height))
        case .stacked:
            return CGSize(width: even(primarySize.width), height: even(primarySize.height * 2))
        }
    }

    private func compositeFrame(primary: CIImage, overlay: CIImage) -> CIImage {
        let outW = outputSize.width
        let outH = outputSize.height

        switch config.layout {
        case .pictureInPicture:
            // Primary fills frame; overlay is small, bottom-right corner with margin
            let pipW = outW * config.overlayScale
            let pipH = pipW * overlay.extent.height / max(overlay.extent.width, 1)
            let margin: CGFloat = 16
            let scaledOverlay = overlay.transformed(by: CGAffineTransform(
                scaleX: pipW / overlay.extent.width,
                y: pipH / overlay.extent.height
            )).transformed(by: CGAffineTransform(translationX: outW - pipW - margin, y: margin))
            let scaledPrimary = primary.transformed(by: CGAffineTransform(
                scaleX: outW / primary.extent.width,
                y: outH / primary.extent.height
            ))
            return scaledOverlay.composited(over: scaledPrimary)

        case .sideBySide:
            let halfW = outW / 2
            let scaledPrimary = primary.transformed(by: CGAffineTransform(
                scaleX: halfW / primary.extent.width,
                y: outH / primary.extent.height
            ))
            let scaledOverlay = overlay.transformed(by: CGAffineTransform(
                scaleX: halfW / overlay.extent.width,
                y: outH / overlay.extent.height
            )).transformed(by: CGAffineTransform(translationX: halfW, y: 0))
            return scaledOverlay.composited(over: scaledPrimary)

        case .stacked:
            let halfH = outH / 2
            let scaledPrimary = primary.transformed(by: CGAffineTransform(
                scaleX: outW / primary.extent.width,
                y: halfH / primary.extent.height
            )).transformed(by: CGAffineTransform(translationX: 0, y: halfH))
            let scaledOverlay = overlay.transformed(by: CGAffineTransform(
                scaleX: outW / overlay.extent.width,
                y: halfH / overlay.extent.height
            ))
            return scaledOverlay.composited(over: scaledPrimary)
        }
    }
}

// MARK: - SCStreamOutput

extension PiPRecordingManager: SCStreamOutput {

    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        Task { @MainActor [weak self] in
            guard let self, self.isRecording else { return }

            if outputType == .audio {
                guard let aInput = self.audioInput, aInput.isReadyForMoreMediaData else { return }
                aInput.append(sampleBuffer)
                return
            }

            guard outputType == .screen else { return }

            // Determine if this is from primary or overlay stream
            let isPrimary = (stream === self.primaryStream)

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            if isPrimary {
                self.latestPrimaryPixelBuffer = pixelBuffer
            } else {
                self.latestOverlayPixelBuffer = pixelBuffer
            }

            // Only composite and write on primary frames
            guard isPrimary,
                  let primaryBuf = self.latestPrimaryPixelBuffer,
                  let vInput = self.videoInput,
                  let adaptor = self.pixelAdaptor,
                  let writer = self.writer else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Start writer session on first frame
            if self.sessionStartTime == nil {
                self.sessionStartTime = pts
                writer.startSession(atSourceTime: pts)
            }

            guard vInput.isReadyForMoreMediaData else { return }

            let primaryCI = CIImage(cvPixelBuffer: primaryBuf)

            // Composite with overlay if available, otherwise just primary
            let outputCI: CIImage
            if let overlayBuf = self.latestOverlayPixelBuffer {
                let overlayCI = CIImage(cvPixelBuffer: overlayBuf)
                outputCI = self.compositeFrame(primary: primaryCI, overlay: overlayCI)
            } else {
                // No overlay frame yet — stretch primary to output size
                outputCI = primaryCI.transformed(by: CGAffineTransform(
                    scaleX: self.outputSize.width / primaryCI.extent.width,
                    y: self.outputSize.height / primaryCI.extent.height
                ))
            }

            // Render to a new pixel buffer
            guard let pool = adaptor.pixelBufferPool else { return }
            var outBuf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
            guard let outputBuf = outBuf else { return }

            self.ciContext.render(outputCI, to: outputBuf)
            adaptor.append(outputBuf, withPresentationTime: pts)
            self.frameCount += 1
        }
    }
}
