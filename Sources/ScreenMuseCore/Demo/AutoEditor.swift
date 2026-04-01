import AVFoundation
import CoreMedia

/// Automatically edits videos by removing pauses and adding transitions
@MainActor
public final class AutoEditor {
    
    public struct EditOptions: Codable, Sendable {
        public let removePauses: Bool
        public let pauseThreshold: TimeInterval
        public let speedUpIdle: Bool
        public let idleSpeed: Double
        public let addTransitions: Bool
        
        public init(
            removePauses: Bool = true,
            pauseThreshold: TimeInterval = 3.0,
            speedUpIdle: Bool = false,
            idleSpeed: Double = 2.0,
            addTransitions: Bool = false
        ) {
            self.removePauses = removePauses
            self.pauseThreshold = pauseThreshold
            self.speedUpIdle = speedUpIdle
            self.idleSpeed = idleSpeed
            self.addTransitions = addTransitions
        }
    }
    
    public struct EditResult: Codable, Sendable {
        public let originalPath: String
        public let editedPath: String
        public let originalDuration: TimeInterval
        public let editedDuration: TimeInterval
        public let compressionRatio: Double
        public let editsApplied: EditsApplied
        
        public struct EditsApplied: Codable, Sendable {
            public let pausesRemoved: Int
            public let idleSectionsSpedUp: Int
            public let transitionsAdded: Int
        }
    }
    
    /// Edit video with specified options
    public static func edit(
        videoURL: URL,
        options: EditOptions
    ) async throws -> EditResult {
        
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let originalDuration = CMTimeGetSeconds(duration)
        
        smLog.info("Auto-editing video: \(originalDuration)s", category: .server)
        
        var pausesRemoved = 0
        var editsApplied = 0
        
        // Detect pauses
        var pauseSegments: [PauseSegment] = []
        if options.removePauses {
            pauseSegments = try await PauseDetector.detectPauses(
                in: videoURL,
                threshold: options.pauseThreshold
            )
            pausesRemoved = pauseSegments.count
        }
        
        // Build composition
        let composition = AVMutableComposition()
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw AutoEditorError.compositionFailed
        }
        
        // Copy segments, skipping pauses
        var currentTime = CMTime.zero
        var lastEnd: TimeInterval = 0
        
        for pause in pauseSegments.sorted(by: { $0.start < $1.start }) {
            // Add segment before pause
            if pause.start > lastEnd {
                let segmentStart = CMTime(seconds: lastEnd, preferredTimescale: 600)
                let segmentDuration = CMTime(seconds: pause.start - lastEnd, preferredTimescale: 600)
                let timeRange = CMTimeRange(start: segmentStart, duration: segmentDuration)
                
                try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: currentTime)
                currentTime = CMTimeAdd(currentTime, segmentDuration)
            }
            
            lastEnd = pause.end
        }
        
        // Add final segment
        if lastEnd < originalDuration {
            let segmentStart = CMTime(seconds: lastEnd, preferredTimescale: 600)
            let segmentDuration = CMTime(seconds: originalDuration - lastEnd, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: segmentStart, duration: segmentDuration)
            
            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: currentTime)
        }
        
        // Add audio track
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            // Same logic for audio
            var audioTime = CMTime.zero
            var audioLastEnd: TimeInterval = 0
            
            for pause in pauseSegments.sorted(by: { $0.start < $1.start }) {
                if pause.start > audioLastEnd {
                    let segmentStart = CMTime(seconds: audioLastEnd, preferredTimescale: 600)
                    let segmentDuration = CMTime(seconds: pause.start - audioLastEnd, preferredTimescale: 600)
                    let timeRange = CMTimeRange(start: segmentStart, duration: segmentDuration)
                    
                    try? compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: audioTime)
                    audioTime = CMTimeAdd(audioTime, segmentDuration)
                }
                
                audioLastEnd = pause.end
            }
            
            if audioLastEnd < originalDuration {
                let segmentStart = CMTime(seconds: audioLastEnd, preferredTimescale: 600)
                let segmentDuration = CMTime(seconds: originalDuration - audioLastEnd, preferredTimescale: 600)
                let timeRange = CMTimeRange(start: segmentStart, duration: segmentDuration)
                
                try? compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: audioTime)
            }
        }
        
        // Export
        let outputURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent + "-edited.mp4")
        
        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw AutoEditorError.exporterCreationFailed
        }
        
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        
        await exporter.export()
        
        guard exporter.status == .completed else {
            throw AutoEditorError.exportFailed(exporter.error?.localizedDescription ?? "Unknown error")
        }
        
        let editedDuration = CMTimeGetSeconds(composition.duration)
        let compressionRatio = originalDuration / editedDuration
        
        smLog.info("Edit complete: \(originalDuration)s → \(editedDuration)s (compression: \(compressionRatio)x)", category: .server)
        
        return EditResult(
            originalPath: videoURL.path,
            editedPath: outputURL.path,
            originalDuration: originalDuration,
            editedDuration: editedDuration,
            compressionRatio: compressionRatio,
            editsApplied: EditResult.EditsApplied(
                pausesRemoved: pausesRemoved,
                idleSectionsSpedUp: 0,
                transitionsAdded: 0
            )
        )
    }
}

public enum AutoEditorError: Error, LocalizedError {
    case compositionFailed
    case exporterCreationFailed
    case exportFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .compositionFailed:
            return "Failed to create video composition"
        case .exporterCreationFailed:
            return "Failed to create export session"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        }
    }
}
