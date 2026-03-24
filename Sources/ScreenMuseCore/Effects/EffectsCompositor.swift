import AVFoundation
import CoreImage
import Foundation

/// Composites click effects onto recorded video
@MainActor
public final class EffectsCompositor {
    private let clickEffects: ClickEffectsManager
    private let ciContext: CIContext
    
    public init(clickEffects: ClickEffectsManager) {
        self.clickEffects = clickEffects
        
        // Use Metal for hardware acceleration
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext()
        }
    }
    
    /// Apply click effects to a recorded video
    /// - Parameters:
    ///   - sourceURL: Original video file
    ///   - outputURL: Output file with effects applied
    ///   - progress: Optional progress callback (0.0 - 1.0)
    public func applyEffects(
        sourceURL: URL,
        outputURL: URL,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        smLog.info("EffectsCompositor.applyEffects() — source=\(sourceURL.lastPathComponent)", category: .effects)
        let asset = AVAsset(url: sourceURL)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            smLog.error("No video track in source: \(sourceURL.lastPathComponent)", category: .effects)
            throw EffectsError.noVideoTrack
        }
        
        let composition = AVMutableComposition()
        
        // Add video track
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw EffectsError.failedToCreateTrack
        }
        
        let timeRange = try await CMTimeRange(
            start: .zero,
            duration: asset.load(.duration)
        )
        
        try compositionVideoTrack.insertTimeRange(
            timeRange,
            of: videoTrack,
            at: .zero
        )
        
        // Copy audio tracks if present
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for (_, audioTrack) in audioTracks.enumerated() {
            if let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try compositionAudioTrack.insertTimeRange(
                    timeRange,
                    of: audioTrack,
                    at: .zero
                )
            }
        }
        
        // Create video composition with custom compositor
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60) // 60 FPS
        videoComposition.renderSize = try await videoTrack.load(.naturalSize)
        
        // Custom compositor instruction
        let instruction = EffectsCompositionInstruction(
            trackID: compositionVideoTrack.trackID,
            timeRange: timeRange,
            clickEffects: clickEffects,
            ciContext: ciContext
        )
        
        videoComposition.instructions = [instruction]
        videoComposition.customVideoCompositorClass = EffectsVideoCompositor.self
        
        // Export with effects
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw EffectsError.failedToCreateExporter
        }
        
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        
        smLog.info("Starting AVAssetExportSession (ClickEffects) → \(outputURL.lastPathComponent)", category: .effects)
        // Monitor progress
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak export] _ in
            guard let export = export else { return }
            Task { @MainActor in
                progress?(Double(export.progress))
            }
        }
        
        await export.export()
        progressTimer.invalidate()
        
        guard export.status == .completed else {
            let errMsg = export.error?.localizedDescription ?? "Unknown error"
            smLog.error("ClickEffects export failed — status=\(export.status.rawValue) error=\(errMsg)", category: .effects)
            throw EffectsError.exportFailed(errMsg)
        }
        smLog.info("✅ ClickEffects export complete — output=\(outputURL.lastPathComponent)", category: .effects)
    }
}

/// Custom AVVideoCompositing implementation for rendering effects
final class EffectsVideoCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String : Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    
    var requiredPixelBufferAttributesForRenderContext: [String : Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    
    private let renderQueue = DispatchQueue(label: "com.screenmuse.compositor", qos: .userInteractive)
    
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // No-op
    }
    
    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            guard let instruction = asyncVideoCompositionRequest.videoCompositionInstruction as? EffectsCompositionInstruction else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "EffectsCompositor",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid instruction"]
                ))
                return
            }
            
            guard let pixelBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: instruction.trackID) else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "EffectsCompositor",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No source frame"]
                ))
                return
            }
            
            let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
            let currentTime = CMTimeGetSeconds(asyncVideoCompositionRequest.compositionTime)
            
            // Render effects on main actor (ClickEffectsManager is @MainActor)
            Task { @MainActor in
                let outputImage = instruction.clickEffects.renderEffects(
                    at: currentTime,
                    videoSize: inputImage.extent.size,
                    baseImage: inputImage
                )
                
                guard let renderBuffer = asyncVideoCompositionRequest.renderContext.newPixelBuffer() else {
                    asyncVideoCompositionRequest.finish(with: NSError(
                        domain: "EffectsCompositor",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create render buffer"]
                    ))
                    return
                }
                
                instruction.ciContext.render(
                    outputImage,
                    to: renderBuffer,
                    bounds: outputImage.extent,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                
                asyncVideoCompositionRequest.finish(withComposedVideoFrame: renderBuffer)
            }
        }
    }
    
    func cancelAllPendingVideoCompositionRequests() {
        // Clean up any pending requests
    }
}

/// Custom instruction for effects composition
final class EffectsCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let trackID: CMPersistentTrackID
    let timeRange: CMTimeRange
    let clickEffects: ClickEffectsManager
    let ciContext: CIContext
    
    var enablePostProcessing = false
    var containsTweening = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    
    init(
        trackID: CMPersistentTrackID,
        timeRange: CMTimeRange,
        clickEffects: ClickEffectsManager,
        ciContext: CIContext
    ) {
        self.trackID = trackID
        self.timeRange = timeRange
        self.clickEffects = clickEffects
        self.ciContext = ciContext
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        super.init()
    }
}

public enum EffectsError: Error, LocalizedError {
    case noVideoTrack
    case failedToCreateTrack
    case failedToCreateExporter
    case exportFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "No video track found in source file"
        case .failedToCreateTrack:
            return "Failed to create composition track"
        case .failedToCreateExporter:
            return "Failed to create export session"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        }
    }
}
