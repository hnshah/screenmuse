import CoreGraphics
import CoreImage
import QuartzCore

/// Configuration for click ripple effects
public struct ClickEffectConfig: Sendable {
    /// Maximum radius of the ripple circle (in points)
    public let maxRadius: CGFloat
    
    /// Duration of the ripple animation (in seconds)
    public let duration: TimeInterval
    
    /// Color of the ripple (RGBA)
    public let color: CIColor
    
    /// Initial opacity (0.0 - 1.0)
    public let initialOpacity: CGFloat
    
    /// Spring damping factor (0.0 = no damping, 1.0 = critically damped)
    public let springDamping: CGFloat
    
    /// Ring width (in points)
    public let ringWidth: CGFloat
    
    public init(
        maxRadius: CGFloat = 40.0,
        duration: TimeInterval = 0.6,
        color: CIColor = CIColor(red: 0.0, green: 0.47, blue: 1.0, alpha: 1.0), // Blue
        initialOpacity: CGFloat = 0.8,
        springDamping: CGFloat = 0.7,
        ringWidth: CGFloat = 3.0
    ) {
        self.maxRadius = maxRadius
        self.duration = duration
        self.color = color
        self.initialOpacity = initialOpacity
        self.springDamping = springDamping
        self.ringWidth = ringWidth
    }
    
    /// Preset: Subtle blue ripple (default)
    public static let subtle = ClickEffectConfig()
    
    /// Preset: Strong red ripple (for emphasis)
    public static let strong = ClickEffectConfig(
        maxRadius: 60.0,
        duration: 0.8,
        color: CIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0),
        initialOpacity: 1.0,
        springDamping: 0.5,
        ringWidth: 4.0
    )
    
    /// Preset: Quick yellow ripple (for fast clicks)
    public static let quick = ClickEffectConfig(
        maxRadius: 30.0,
        duration: 0.3,
        color: CIColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0),
        initialOpacity: 0.9,
        springDamping: 0.8,
        ringWidth: 2.0
    )
}

/// Represents a single click effect instance
public struct ClickEffect: Sendable {
    public let position: CGPoint
    public let startTime: TimeInterval
    public let config: ClickEffectConfig
    
    public init(position: CGPoint, startTime: TimeInterval, config: ClickEffectConfig) {
        self.position = position
        self.startTime = startTime
        self.config = config
    }
    
    /// Calculate ripple radius at a given time using spring easing
    public func radius(at currentTime: TimeInterval) -> CGFloat {
        let elapsed = currentTime - startTime
        guard elapsed >= 0, elapsed <= config.duration else { return 0 }
        
        let progress = elapsed / config.duration
        
        // Spring easing function
        // https://easings.net/#easeOutElastic
        let c4 = (2.0 * .pi) / 3.0
        let springProgress: CGFloat
        
        if progress == 0 {
            springProgress = 0
        } else if progress == 1 {
            springProgress = 1
        } else {
            let powValue = pow(2, -10 * progress)
            springProgress = powValue * sin((progress * 10 - 0.75) * c4) + 1
        }
        
        // Apply damping
        let dampedProgress = springProgress * (1.0 - config.springDamping * (1.0 - progress))
        
        return config.maxRadius * dampedProgress
    }
    
    /// Calculate opacity at a given time (fade out)
    public func opacity(at currentTime: TimeInterval) -> CGFloat {
        let elapsed = currentTime - startTime
        guard elapsed >= 0, elapsed <= config.duration else { return 0 }
        
        let progress = elapsed / config.duration
        let fadeProgress = 1.0 - progress // Linear fade out
        
        return config.initialOpacity * fadeProgress
    }
    
    /// Check if this effect is still active
    public func isActive(at currentTime: TimeInterval) -> Bool {
        let elapsed = currentTime - startTime
        return elapsed >= 0 && elapsed <= config.duration
    }
}

/// Manages click effects for video rendering
@MainActor
public final class ClickEffectsManager: ObservableObject {
    @Published public private(set) var activeEffects: [ClickEffect] = []
    
    private var config: ClickEffectConfig
    private var recordingStartTime: Date?
    
    public init(config: ClickEffectConfig = .subtle) {
        self.config = config
    }
    
    /// Start tracking effects from recording start time
    public func startRecording(at startTime: Date) {
        recordingStartTime = startTime
        activeEffects.removeAll()
    }
    
    /// Add a click effect at a specific position and time
    public func addClick(at position: CGPoint, timestamp: Date) {
        guard let startTime = recordingStartTime else { return }
        
        let elapsedTime = timestamp.timeIntervalSince(startTime)
        let effect = ClickEffect(
            position: position,
            startTime: elapsedTime,
            config: config
        )
        
        activeEffects.append(effect)
    }
    
    /// Update configuration (applies to new effects only)
    public func updateConfig(_ newConfig: ClickEffectConfig) {
        config = newConfig
    }
    
    /// Render all active effects at a given timestamp onto a CIImage
    public func renderEffects(
        at currentTime: TimeInterval,
        videoSize: CGSize,
        baseImage: CIImage? = nil
    ) -> CIImage {
        var outputImage = baseImage ?? CIImage.empty()
        
        // Filter active effects at this timestamp
        let active = activeEffects.filter { $0.isActive(at: currentTime) }
        
        for effect in active {
            let radius = effect.radius(at: currentTime)
            let opacity = effect.opacity(at: currentTime)
            
            guard radius > 0, opacity > 0 else { continue }
            
            // Create ripple circle using CIFilter
            let ripple = createRippleCircle(
                at: effect.position,
                radius: radius,
                color: effect.config.color,
                opacity: opacity,
                ringWidth: effect.config.ringWidth,
                canvasSize: videoSize
            )
            
            // Composite over existing image
            if let ripple {
                outputImage = ripple.composited(over: outputImage)
            }
        }
        
        return outputImage
    }
    
    /// Create a ripple circle CIImage
    private func createRippleCircle(
        at center: CGPoint,
        radius: CGFloat,
        color: CIColor,
        opacity: CGFloat,
        ringWidth: CGFloat,
        canvasSize: CGSize
    ) -> CIImage? {
        // Convert macOS screen coordinates (origin bottom-left) to video coordinates (origin top-left)
        let videoY = canvasSize.height - center.y
        let videoCenter = CGPoint(x: center.x, y: videoY)
        
        // Create outer circle
        let outerCircle = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(cgPoint: videoCenter),
            "inputRadius0": radius - ringWidth / 2,
            "inputRadius1": radius + ringWidth / 2,
            "inputColor0": color.copy(alpha: opacity * color.alpha),
            "inputColor1": CIColor.clear
        ])?.outputImage
        
        guard let circle = outerCircle else { return nil }
        
        // Crop to canvas size
        return circle.cropped(to: CGRect(origin: .zero, size: canvasSize))
    }
    
    /// Clean up old effects (called periodically or after recording)
    public func cleanupOldEffects(before time: TimeInterval) {
        activeEffects.removeAll { !$0.isActive(at: time) }
    }
    
    /// Reset all effects
    public func reset() {
        activeEffects.removeAll()
        recordingStartTime = nil
    }
}

extension CIColor {
    func copy(alpha: CGFloat) -> CIColor {
        CIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
