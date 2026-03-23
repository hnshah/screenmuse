import AVFoundation
import CoreImage
import Foundation

/// Composites both auto-zoom and click effects onto recorded video
@MainActor
public final class CombinedEffectsCompositor {
    private let clickEffects: ClickEffectsManager
    private let autoZoom: AutoZoomManager
    private let ciContext: CIContext
    
    public init(clickEffects: ClickEffectsManager, autoZoom: AutoZoomManager) {
        self.clickEffects = clickEffects
        self.autoZoom = autoZoom
        
        // Use Metal for hardware acceleration
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext()
        }
    }
    
    /// Apply both zoom and click effects to a recorded video
    public func applyEffects(
        sourceURL: URL,
        outputURL: URL,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        let asset = AVAsset(url: sourceURL)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
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
        for audioTrack in audioTracks {
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
        let instruction = CombinedEffectsInstruction(
            trackID: compositionVideoTrack.trackID,
            timeRange: timeRange,
            clickEffects: clickEffects,
            autoZoom: autoZoom,
            ciContext: ciContext
        )
        
        videoComposition.instructions = [instruction]
        videoComposition.customVideoCompositorClass = CombinedEffectsVideoCompositor.self
        
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
        
        // Monitor progress
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            progress?(Double(export.progress))
        }
        
        await export.export()
        progressTimer.invalidate()
        
        guard export.status == .completed else {
            throw EffectsError.exportFailed(export.error?.localizedDescription ?? "Unknown error")
        }
    }
}

/// Custom AVVideoCompositing for combined effects
final class CombinedEffectsVideoCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String : Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    
    var requiredPixelBufferAttributesForRenderContext: [String : Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    
    private let renderQueue = DispatchQueue(label: "com.screenmuse.combined-compositor", qos: .userInteractive)
    
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // No-op
    }
    
    func startRequest(_ asyncVideoCompositionRequest: AVAsyncVideoCompositionRequest) {
        renderQueue.async {
            guard let instruction = asyncVideoCompositionRequest.videoCompositionInstruction as? CombinedEffectsInstruction else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "CombinedEffectsCompositor",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid instruction"]
                ))
                return
            }
            
            guard let pixelBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: instruction.trackID) else {
                asyncVideoCompositionRequest.finish(with: NSError(
                    domain: "CombinedEffectsCompositor",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No source frame"]
                ))
                return
            }
            
            let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
            let currentTime = CMTimeGetSeconds(asyncVideoCompositionRequest.compositionTime)
            
            // Render effects on main actor
            Task { @MainActor in
                // Step 1: Apply auto-zoom transform
                let zoomTransform = instruction.autoZoom.transform(
                    at: currentTime,
                    videoSize: inputImage.extent.size
                )
                
                let zoomedImage = inputImage.applyingZoom(
                    zoomTransform,
                    outputSize: inputImage.extent.size
                )
                
                // Step 2: Render click effects on top of zoomed image
                let finalImage = instruction.clickEffects.renderEffects(
                    at: currentTime,
                    videoSize: inputImage.extent.size,
                    baseImage: zoomedImage
                )
                
                // Render to buffer
                guard let renderBuffer = asyncVideoCompositionRequest.renderContext.newPixelBuffer() else {
                    asyncVideoCompositionRequest.finish(with: NSError(
                        domain: "CombinedEffectsCompositor",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create render buffer"]
                    ))
                    return
                }
                
                instruction.ciContext.render(
                    finalImage,
                    to: renderBuffer,
                    bounds: finalImage.extent,
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

/// Combined instruction
final class CombinedEffectsInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let trackID: CMPersistentTrackID
    let timeRange: CMTimeRange
    let clickEffects: ClickEffectsManager
    let autoZoom: AutoZoomManager
    let ciContext: CIContext
    
    var enablePostProcessing = false
    var containsTweening = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    
    init(
        trackID: CMPersistentTrackID,
        timeRange: CMTimeRange,
        clickEffects: ClickEffectsManager,
        autoZoom: AutoZoomManager,
        ciContext: CIContext
    ) {
        self.trackID = trackID
        self.timeRange = timeRange
        self.clickEffects = clickEffects
        self.autoZoom = autoZoom
        self.ciContext = ciContext
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        super.init()
    }
}
