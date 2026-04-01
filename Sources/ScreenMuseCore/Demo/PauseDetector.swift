import AVFoundation
import CoreImage

/// Detects idle/pause segments in recorded video
@MainActor
public final class PauseDetector {
    
    /// Analyze video and detect pause segments
    public static func detectPauses(
        in videoURL: URL,
        threshold: TimeInterval = 3.0,
        similarityThreshold: Double = 0.95
    ) async throws -> [PauseSegment] {
        
        let asset = AVAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PauseDetectorError.noVideoTrack
        }
        
        let duration = try await asset.load(.duration)
        let fps = try await track.load(.nominalFrameRate)
        
        var pauses: [PauseSegment] = []
        var currentPauseStart: TimeInterval?
        var lastFrame: CIImage?
        
        let frameInterval = 1.0 / Double(fps)
        let totalDuration = CMTimeGetSeconds(duration)
        
        // Sample every second for performance
        let sampleInterval = 1.0
        var currentTime: TimeInterval = 0
        
        smLog.info("Analyzing video for pauses: \(totalDuration)s @ \(fps)fps", category: .server)
        
        while currentTime < totalDuration {
            let time = CMTime(seconds: currentTime, preferredTimescale: 600)
            
            guard let frame = try? await extractFrame(from: asset, at: time) else {
                currentTime += sampleInterval
                continue
            }
            
            if let previous = lastFrame {
                let similarity = frameSimilarity(previous, frame)
                
                if similarity > similarityThreshold {
                    // Frames are very similar - likely paused
                    if currentPauseStart == nil {
                        currentPauseStart = currentTime
                    }
                } else {
                    // Motion detected
                    if let pauseStart = currentPauseStart {
                        let pauseDuration = currentTime - pauseStart
                        if pauseDuration >= threshold {
                            pauses.append(PauseSegment(
                                start: pauseStart,
                                end: currentTime,
                                duration: pauseDuration,
                                confidence: 1.0
                            ))
                        }
                        currentPauseStart = nil
                    }
                }
            }
            
            lastFrame = frame
            currentTime += sampleInterval
        }
        
        // Check for pause at end
        if let pauseStart = currentPauseStart {
            let pauseDuration = totalDuration - pauseStart
            if pauseDuration >= threshold {
                pauses.append(PauseSegment(
                    start: pauseStart,
                    end: totalDuration,
                    duration: pauseDuration,
                    confidence: 1.0
                ))
            }
        }
        
        smLog.info("Found \(pauses.count) pause segments", category: .server)
        return pauses
    }
    
    /// Extract a single frame from video
    private static func extractFrame(from asset: AVAsset, at time: CMTime) async throws -> CIImage? {
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.requestedTimeToleranceBefore = .zero
        
        let (cgImage, _) = try await imageGenerator.image(at: time)
        return CIImage(cgImage: cgImage)
    }
    
    /// Calculate similarity between two frames (0.0 = different, 1.0 = identical)
    private static func frameSimilarity(_ frame1: CIImage, _ frame2: CIImage) -> Double {
        // Simple pixel difference approach
        // For better accuracy, could use perceptual hashing or feature detection
        
        let context = CIContext()
        
        // Resize to small size for faster comparison
        let size = CGSize(width: 64, height: 64)
        let scale = CGAffineTransform(scaleX: size.width / frame1.extent.width, y: size.height / frame1.extent.height)
        
        guard let small1 = context.createCGImage(frame1.transformed(by: scale), from: CGRect(origin: .zero, size: size)),
              let small2 = context.createCGImage(frame2.transformed(by: scale), from: CGRect(origin: .zero, size: size)) else {
            return 0
        }
        
        // Compare pixel data
        guard let data1 = small1.dataProvider?.data as Data?,
              let data2 = small2.dataProvider?.data as Data? else {
            return 0
        }
        
        let bytes1 = [UInt8](data1)
        let bytes2 = [UInt8](data2)
        
        guard bytes1.count == bytes2.count else { return 0 }
        
        var totalDiff = 0
        for i in 0..<bytes1.count {
            totalDiff += abs(Int(bytes1[i]) - Int(bytes2[i]))
        }
        
        let maxDiff = bytes1.count * 255
        let similarity = 1.0 - (Double(totalDiff) / Double(maxDiff))
        
        return similarity
    }
}

public struct PauseSegment: Codable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let duration: TimeInterval
    public let confidence: Double
}

public enum PauseDetectorError: Error, LocalizedError {
    case noVideoTrack
    case frameExtractionFailed
    
    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "No video track found in asset"
        case .frameExtractionFailed:
            return "Failed to extract video frames"
        }
    }
}
