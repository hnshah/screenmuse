import CoreGraphics
import QuartzCore

/// Configuration for auto-zoom camera behavior
public struct AutoZoomConfig: Sendable {
    /// Zoom scale when focused on click (1.0 = no zoom, 2.0 = 2x zoom)
    public let zoomScale: CGFloat
    
    /// Duration of zoom-in animation (seconds)
    public let zoomInDuration: TimeInterval
    
    /// Duration of zoom-out animation (seconds)
    public let zoomOutDuration: TimeInterval
    
    /// How long to hold the zoom before zooming out (seconds)
    public let holdDuration: TimeInterval
    
    /// Padding around click point (in points)
    public let padding: CGFloat
    
    /// Spring damping for zoom animation (0.0-1.0)
    public let springDamping: CGFloat
    
    /// Minimum time between zoom triggers (prevents rapid zoom spam)
    public let minTimeBetweenZooms: TimeInterval
    
    public init(
        zoomScale: CGFloat = 1.5,
        zoomInDuration: TimeInterval = 0.4,
        zoomOutDuration: TimeInterval = 0.6,
        holdDuration: TimeInterval = 1.5,
        padding: CGFloat = 100.0,
        springDamping: CGFloat = 0.7,
        minTimeBetweenZooms: TimeInterval = 0.3
    ) {
        self.zoomScale = zoomScale
        self.zoomInDuration = zoomInDuration
        self.zoomOutDuration = zoomOutDuration
        self.holdDuration = holdDuration
        self.padding = padding
        self.springDamping = springDamping
        self.minTimeBetweenZooms = minTimeBetweenZooms
    }
    
    /// Preset: Subtle zoom (default, Screen Studio style)
    public static let subtle = AutoZoomConfig()
    
    /// Preset: Strong zoom (dramatic, presentation style)
    public static let strong = AutoZoomConfig(
        zoomScale: 2.0,
        zoomInDuration: 0.5,
        zoomOutDuration: 0.8,
        holdDuration: 2.0,
        padding: 150.0
    )
    
    /// Preset: Quick zoom (fast-paced, tutorial style)
    public static let quick = AutoZoomConfig(
        zoomScale: 1.3,
        zoomInDuration: 0.2,
        zoomOutDuration: 0.3,
        holdDuration: 0.8,
        padding: 80.0,
        springDamping: 0.8
    )
}

/// Represents a zoom event in the timeline
public struct ZoomEvent: Sendable {
    public let clickPosition: CGPoint
    public let startTime: TimeInterval
    public let config: AutoZoomConfig
    
    public init(clickPosition: CGPoint, startTime: TimeInterval, config: AutoZoomConfig) {
        self.clickPosition = clickPosition
        self.startTime = startTime
        self.config = config
    }
    
    /// Calculate the zoom transform at a given time
    public func transform(at currentTime: TimeInterval, videoSize: CGSize) -> CGAffineTransform {
        let elapsed = currentTime - startTime
        
        // Timeline:
        // 0.0 -> zoomInDuration: Zoom in (1.0 -> zoomScale)
        // zoomInDuration -> zoomInDuration + holdDuration: Hold at zoomScale
        // zoomInDuration + holdDuration -> zoomInDuration + holdDuration + zoomOutDuration: Zoom out (zoomScale -> 1.0)
        
        let zoomInEnd = config.zoomInDuration
        let holdEnd = zoomInEnd + config.holdDuration
        let zoomOutEnd = holdEnd + config.zoomOutDuration
        
        guard elapsed >= 0, elapsed <= zoomOutEnd else {
            return .identity // No transform before/after event
        }
        
        let scale: CGFloat
        
        if elapsed <= zoomInEnd {
            // Zoom in phase
            let progress = elapsed / config.zoomInDuration
            let easedProgress = easeOutCubic(progress)
            scale = 1.0 + (config.zoomScale - 1.0) * easedProgress
        } else if elapsed <= holdEnd {
            // Hold phase
            scale = config.zoomScale
        } else {
            // Zoom out phase
            let progress = (elapsed - holdEnd) / config.zoomOutDuration
            let easedProgress = easeInOutCubic(progress)
            scale = config.zoomScale - (config.zoomScale - 1.0) * easedProgress
        }
        
        // Calculate translation to keep click point centered
        let centerX = videoSize.width / 2
        let centerY = videoSize.height / 2
        
        // Convert click position to video coordinates (accounting for origin difference)
        let clickX = clickPosition.x
        let clickY = videoSize.height - clickPosition.y // Flip Y
        
        // Translation needed to center the click point
        let translateX = (centerX - clickX) * (scale - 1.0)
        let translateY = (centerY - clickY) * (scale - 1.0)
        
        return CGAffineTransform(translationX: translateX, y: translateY)
            .scaledBy(x: scale, y: scale)
    }
    
    /// Check if this zoom event is active at the given time
    public func isActive(at currentTime: TimeInterval) -> Bool {
        let elapsed = currentTime - startTime
        let totalDuration = config.zoomInDuration + config.holdDuration + config.zoomOutDuration
        return elapsed >= 0 && elapsed <= totalDuration
    }
    
    /// Cubic ease-out (decelerating)
    private func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let t1 = t - 1.0
        return t1 * t1 * t1 + 1.0
    }
    
    /// Cubic ease-in-out (smooth both ends)
    private func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        if t < 0.5 {
            return 4.0 * t * t * t
        } else {
            let t1 = 2.0 * t - 2.0
            return 1.0 + t1 * t1 * t1 / 2.0
        }
    }
}

/// Manages auto-zoom camera for video rendering
@MainActor
public final class AutoZoomManager: ObservableObject {
    @Published public private(set) var zoomEvents: [ZoomEvent] = []
    
    private var config: AutoZoomConfig
    private var recordingStartTime: Date?
    private var lastZoomTime: TimeInterval = -100.0 // Large negative to allow first zoom
    
    public init(config: AutoZoomConfig = .subtle) {
        self.config = config
    }
    
    /// Start tracking zoom events from recording start time
    public func startRecording(at startTime: Date) {
        recordingStartTime = startTime
        zoomEvents.removeAll()
        lastZoomTime = -100.0
    }
    
    /// Add a zoom event at click position
    public func addClick(at position: CGPoint, timestamp: Date) {
        guard let startTime = recordingStartTime else { return }
        
        let elapsedTime = timestamp.timeIntervalSince(startTime)
        
        // Prevent zoom spam - ignore clicks too close together
        if elapsedTime - lastZoomTime < config.minTimeBetweenZooms {
            return
        }
        
        let event = ZoomEvent(
            clickPosition: position,
            startTime: elapsedTime,
            config: config
        )
        
        zoomEvents.append(event)
        lastZoomTime = elapsedTime
    }
    
    /// Update configuration (applies to new events only)
    public func updateConfig(_ newConfig: AutoZoomConfig) {
        config = newConfig
    }
    
    /// Get the active transform at a given time
    /// Multiple zoom events blend if overlapping
    public func transform(at currentTime: TimeInterval, videoSize: CGSize) -> CGAffineTransform {
        let activeEvents = zoomEvents.filter { $0.isActive(at: currentTime) }
        
        guard !activeEvents.isEmpty else {
            return .identity
        }
        
        // If multiple zooms are active (rare), use the most recent
        guard let latestEvent = activeEvents.max(by: { $0.startTime < $1.startTime }) else {
            return .identity
        }
        
        return latestEvent.transform(at: currentTime, videoSize: videoSize)
    }
    
    /// Clean up old events (called periodically)
    public func cleanupOldEvents(before time: TimeInterval) {
        zoomEvents.removeAll { !$0.isActive(at: time) }
    }
    
    /// Reset all events
    public func reset() {
        zoomEvents.removeAll()
        recordingStartTime = nil
        lastZoomTime = -100.0
    }
}

/// Extension for applying zoom to CIImage
extension CIImage {
    /// Apply zoom transform to image
    public func applyingZoom(_ transform: CGAffineTransform, outputSize: CGSize) -> CIImage {
        guard transform != .identity else { return self }
        
        // Apply transform to image
        let transformed = self.transformed(by: transform)
        
        // Crop to output size (centered)
        let outputRect = CGRect(origin: .zero, size: outputSize)
        return transformed.cropped(to: outputRect)
    }
}
