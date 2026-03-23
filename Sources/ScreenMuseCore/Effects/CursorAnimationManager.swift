import CoreGraphics
import CoreImage
import AppKit

/// Cursor style types
public enum CursorStyle: String, Sendable, CaseIterable {
    case arrow = "Arrow"
    case pointer = "Pointer"
    case iBeam = "I-Beam"
    case crosshair = "Crosshair"
    case openHand = "Open Hand"
    case closedHand = "Closed Hand"
    case resizeLeftRight = "Resize Left-Right"
    
    /// Get system cursor image for this style
    public func cursorImage(scale: CGFloat = 1.0) -> NSImage? {
        let cursor: NSCursor
        
        switch self {
        case .arrow:
            cursor = .arrow
        case .pointer:
            cursor = .pointingHand
        case .iBeam:
            cursor = .iBeam
        case .crosshair:
            cursor = .crosshair
        case .openHand:
            cursor = .openHand
        case .closedHand:
            cursor = .closedHand
        case .resizeLeftRight:
            cursor = .resizeLeftRight
        }
        
        guard let image = cursor.image else { return nil }
        
        if scale == 1.0 {
            return image
        }
        
        // Scale the cursor
        let newSize = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        
        let scaledImage = NSImage(size: newSize)
        scaledImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        scaledImage.unlockFocus()
        
        return scaledImage
    }
}

/// Configuration for cursor animations
public struct CursorAnimationConfig: Sendable {
    /// Cursor style to render
    public let style: CursorStyle
    
    /// Cursor scale multiplier (1.0 = normal size, 2.0 = 2x size)
    public let scale: CGFloat
    
    /// Enable motion blur when cursor moves fast
    public let enableMotionBlur: Bool
    
    /// Motion blur intensity (0.0-1.0)
    public let motionBlurIntensity: CGFloat
    
    /// Velocity threshold for motion blur (points/second)
    public let motionBlurThreshold: CGFloat
    
    /// Enable smooth path interpolation
    public let enableSmoothPath: Bool
    
    /// Smoothing factor (0.0 = no smoothing, 1.0 = maximum smoothing)
    public let pathSmoothingFactor: CGFloat
    
    /// Show cursor trail effect
    public let enableTrail: Bool
    
    /// Trail length (number of ghost cursors)
    public let trailLength: Int
    
    /// Trail fade factor (0.0-1.0)
    public let trailFadeFactor: CGFloat
    
    public init(
        style: CursorStyle = .arrow,
        scale: CGFloat = 1.5,
        enableMotionBlur: Bool = true,
        motionBlurIntensity: CGFloat = 0.6,
        motionBlurThreshold: CGFloat = 500.0,
        enableSmoothPath: Bool = true,
        pathSmoothingFactor: CGFloat = 0.3,
        enableTrail: Bool = false,
        trailLength: Int = 5,
        trailFadeFactor: CGFloat = 0.7
    ) {
        self.style = style
        self.scale = scale
        self.enableMotionBlur = enableMotionBlur
        self.motionBlurIntensity = motionBlurIntensity
        self.motionBlurThreshold = motionBlurThreshold
        self.enableSmoothPath = enableSmoothPath
        self.pathSmoothingFactor = pathSmoothingFactor
        self.enableTrail = enableTrail
        self.trailLength = trailLength
        self.trailFadeFactor = trailFadeFactor
    }
    
    /// Preset: Clean (default, professional)
    public static let clean = CursorAnimationConfig()
    
    /// Preset: Dramatic (motion blur + trail)
    public static let dramatic = CursorAnimationConfig(
        scale: 2.0,
        enableMotionBlur: true,
        motionBlurIntensity: 0.8,
        enableTrail: true,
        trailLength: 8
    )
    
    /// Preset: Minimal (no effects, just larger cursor)
    public static let minimal = CursorAnimationConfig(
        scale: 1.8,
        enableMotionBlur: false,
        enableSmoothPath: false,
        enableTrail: false
    )
}

/// Cursor position at a specific time with metadata
public struct CursorFrame: Sendable {
    public let position: CGPoint
    public let timestamp: TimeInterval
    public let velocity: CGFloat  // Points per second
    public let style: CursorStyle
    
    public init(position: CGPoint, timestamp: TimeInterval, velocity: CGFloat = 0, style: CursorStyle = .arrow) {
        self.position = position
        self.timestamp = timestamp
        self.velocity = velocity
        self.style = style
    }
}

/// Manages cursor rendering and animations
@MainActor
public final class CursorAnimationManager: ObservableObject {
    @Published public private(set) var cursorFrames: [CursorFrame] = []
    
    private var config: CursorAnimationConfig
    private var recordingStartTime: Date?
    private var cursorImageCache: [String: NSImage] = [:]
    
    public init(config: CursorAnimationConfig = .clean) {
        self.config = config
    }
    
    /// Start tracking cursor from recording start time
    public func startRecording(at startTime: Date) {
        recordingStartTime = startTime
        cursorFrames.removeAll()
        cursorImageCache.removeAll()
    }
    
    /// Add cursor position from cursor event
    public func addCursorPosition(at position: CGPoint, timestamp: Date, style: CursorStyle = .arrow) {
        guard let startTime = recordingStartTime else { return }
        
        let elapsedTime = timestamp.timeIntervalSince(startTime)
        
        // Calculate velocity from last frame
        let velocity: CGFloat
        if let lastFrame = cursorFrames.last {
            let deltaTime = elapsedTime - lastFrame.timestamp
            if deltaTime > 0 {
                let deltaX = position.x - lastFrame.position.x
                let deltaY = position.y - lastFrame.position.y
                let distance = sqrt(deltaX * deltaX + deltaY * deltaY)
                velocity = distance / deltaTime
            } else {
                velocity = 0
            }
        } else {
            velocity = 0
        }
        
        let frame = CursorFrame(
            position: position,
            timestamp: elapsedTime,
            velocity: velocity,
            style: style
        )
        
        cursorFrames.append(frame)
    }
    
    /// Update configuration (applies to rendering only)
    public func updateConfig(_ newConfig: CursorAnimationConfig) {
        config = newConfig
        cursorImageCache.removeAll() // Clear cache when config changes
    }
    
    /// Get cursor position at a specific time (with smoothing if enabled)
    public func cursorPosition(at currentTime: TimeInterval) -> CGPoint? {
        guard !cursorFrames.isEmpty else { return nil }
        
        // Find frames around current time
        var beforeFrame: CursorFrame?
        var afterFrame: CursorFrame?
        
        for frame in cursorFrames {
            if frame.timestamp <= currentTime {
                beforeFrame = frame
            } else if afterFrame == nil {
                afterFrame = frame
                break
            }
        }
        
        // Use nearest frame if at edges
        if beforeFrame == nil {
            return cursorFrames.first?.position
        }
        if afterFrame == nil {
            return beforeFrame?.position
        }
        
        guard let before = beforeFrame, let after = afterFrame else {
            return beforeFrame?.position
        }
        
        // Interpolate between frames
        let timeDelta = after.timestamp - before.timestamp
        guard timeDelta > 0 else { return before.position }
        
        let progress = (currentTime - before.timestamp) / timeDelta
        
        if config.enableSmoothPath {
            // Smooth interpolation using ease-in-out
            let smoothProgress = smoothInterpolation(progress, factor: config.pathSmoothingFactor)
            
            let x = before.position.x + (after.position.x - before.position.x) * smoothProgress
            let y = before.position.y + (after.position.y - before.position.y) * smoothProgress
            
            return CGPoint(x: x, y: y)
        } else {
            // Linear interpolation
            let x = before.position.x + (after.position.x - before.position.x) * progress
            let y = before.position.y + (after.position.y - before.position.y) * progress
            
            return CGPoint(x: x, y: y)
        }
    }
    
    /// Render cursor at current time onto CIImage
    public func renderCursor(at currentTime: TimeInterval, videoSize: CGSize, baseImage: CIImage? = nil) -> CIImage {
        var output = baseImage ?? CIImage.empty()
        
        guard let position = cursorPosition(at: currentTime) else {
            return output
        }
        
        // Get cursor image (with caching)
        let cacheKey = "\(config.style.rawValue)-\(config.scale)"
        let cursorImage: NSImage
        if let cached = cursorImageCache[cacheKey] {
            cursorImage = cached
        } else if let image = config.style.cursorImage(scale: config.scale) {
            cursorImageCache[cacheKey] = image
            cursorImage = image
        } else {
            return output // No cursor image available
        }
        
        // Convert NSImage to CIImage
        guard let tiffData = cursorImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cursorCGImage = bitmap.cgImage else {
            return output
        }
        
        var cursor = CIImage(cgImage: cursorCGImage)
        
        // Convert macOS coordinates (origin bottom-left) to video coordinates (origin top-left)
        let videoY = videoSize.height - position.y
        let cursorX = position.x - cursor.extent.width / 2
        let cursorY = videoY - cursor.extent.height / 2
        
        // Apply motion blur if enabled and velocity is high
        if config.enableMotionBlur {
            if let velocity = velocityAt(time: currentTime),
               velocity > config.motionBlurThreshold {
                cursor = applyMotionBlur(to: cursor, velocity: velocity, intensity: config.motionBlurIntensity)
            }
        }
        
        // Render trail if enabled
        if config.enableTrail {
            output = renderTrail(at: currentTime, videoSize: videoSize, baseImage: output)
        }
        
        // Position cursor
        cursor = cursor.transformed(by: CGAffineTransform(translationX: cursorX, y: cursorY))
        
        // Composite onto base
        output = cursor.composited(over: output)
        
        return output
    }
    
    /// Get velocity at specific time
    private func velocityAt(time: TimeInterval) -> CGFloat? {
        // Find closest frame
        let closest = cursorFrames.min(by: { abs($0.timestamp - time) < abs($1.timestamp - time) })
        return closest?.velocity
    }
    
    /// Apply motion blur effect
    private func applyMotionBlur(to image: CIImage, velocity: CGFloat, intensity: CGFloat) -> CIImage {
        // Use CIMotionBlur filter
        guard let filter = CIFilter(name: "CIMotionBlur") else { return image }
        
        filter.setValue(image, forKey: kCIInputImageKey)
        
        // Blur radius based on velocity and intensity
        let radius = min(velocity / 100.0 * intensity, 20.0) // Cap at 20 points
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        
        // Angle based on movement direction (simplified: horizontal for now)
        filter.setValue(0.0, forKey: kCIInputAngleKey)
        
        return filter.outputImage ?? image
    }
    
    /// Render cursor trail
    private func renderTrail(at currentTime: TimeInterval, videoSize: CGSize, baseImage: CIImage) -> CIImage {
        var output = baseImage
        
        // Get trail positions (past N frames)
        let trailInterval = 0.05 // 50ms between trail ghosts
        
        for i in 1...config.trailLength {
            let trailTime = currentTime - Double(i) * trailInterval
            guard trailTime >= 0 else { continue }
            
            guard let trailPosition = cursorPosition(at: trailTime) else { continue }
            
            // Get cursor image
            guard let cursorImage = config.style.cursorImage(scale: config.scale),
                  let tiffData = cursorImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let cursorCGImage = bitmap.cgImage else {
                continue
            }
            
            var cursor = CIImage(cgImage: cursorCGImage)
            
            // Fade based on trail position
            let fadeFactor = pow(config.trailFadeFactor, CGFloat(i))
            cursor = cursor.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: fadeFactor)
            ])
            
            // Position
            let videoY = videoSize.height - trailPosition.y
            let cursorX = trailPosition.x - cursor.extent.width / 2
            let cursorY = videoY - cursor.extent.height / 2
            
            cursor = cursor.transformed(by: CGAffineTransform(translationX: cursorX, y: cursorY))
            
            output = cursor.composited(over: output)
        }
        
        return output
    }
    
    /// Smooth interpolation function
    private func smoothInterpolation(_ t: CGFloat, factor: CGFloat) -> CGFloat {
        // Ease-in-out with configurable smoothing
        let smoothed = t * t * (3.0 - 2.0 * t) // Smoothstep
        return t + (smoothed - t) * factor
    }
    
    /// Reset all state
    public func reset() {
        cursorFrames.removeAll()
        recordingStartTime = nil
        cursorImageCache.removeAll()
    }
}
