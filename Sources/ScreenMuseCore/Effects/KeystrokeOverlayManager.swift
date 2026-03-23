import CoreGraphics
import CoreImage
import AppKit
import Carbon

/// Keyboard event types we track
public enum KeyEventType: Sendable {
    case keyPress
    case shortcut
    case modifier
}

/// Represents a keyboard event with metadata
public struct KeyEvent: Sendable {
    public let key: String          // Key name (e.g., "A", "Enter", "⌘C")
    public let timestamp: TimeInterval
    public let type: KeyEventType
    public let modifiers: [String]  // ["⌘", "⇧", "⌥", "⌃"]
    
    public init(key: String, timestamp: TimeInterval, type: KeyEventType, modifiers: [String] = []) {
        self.key = key
        self.timestamp = timestamp
        self.type = type
        self.modifiers = modifiers
    }
    
    /// Display string (e.g., "⌘⇧A")
    public var displayString: String {
        if modifiers.isEmpty {
            return key
        }
        return modifiers.joined() + key
    }
}

/// Configuration for keystroke overlay
public struct KeystrokeOverlayConfig: Sendable {
    /// Position on screen
    public enum Position: Sendable {
        case topLeft
        case topCenter
        case topRight
        case bottomLeft
        case bottomCenter
        case bottomRight
        case custom(CGPoint) // Normalized 0-1 coordinates
    }
    
    /// Visual style
    public enum Style: Sendable {
        case minimal      // Small, transparent
        case standard     // Medium, semi-opaque
        case bold         // Large, opaque
    }
    
    public let position: Position
    public let style: Style
    
    /// Font size multiplier
    public let fontSize: CGFloat
    
    /// Background opacity (0.0-1.0)
    public let backgroundOpacity: CGFloat
    
    /// How long to show each keystroke (seconds)
    public let displayDuration: TimeInterval
    
    /// Fade out duration (seconds)
    public let fadeOutDuration: TimeInterval
    
    /// Padding around text (points)
    public let padding: CGFloat
    
    /// Corner radius (points)
    public let cornerRadius: CGFloat
    
    /// Maximum keys to show simultaneously
    public let maxSimultaneousKeys: Int
    
    /// Filter: only show shortcuts (ignore single keys)
    public let shortcutsOnly: Bool
    
    public init(
        position: Position = .bottomRight,
        style: Style = .standard,
        fontSize: CGFloat = 24.0,
        backgroundOpacity: CGFloat = 0.8,
        displayDuration: TimeInterval = 1.5,
        fadeOutDuration: TimeInterval = 0.5,
        padding: CGFloat = 12.0,
        cornerRadius: CGFloat = 8.0,
        maxSimultaneousKeys: Int = 3,
        shortcutsOnly: Bool = false
    ) {
        self.position = position
        self.style = style
        self.fontSize = fontSize
        self.backgroundOpacity = backgroundOpacity
        self.displayDuration = displayDuration
        self.fadeOutDuration = fadeOutDuration
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.maxSimultaneousKeys = maxSimultaneousKeys
        self.shortcutsOnly = shortcutsOnly
    }
    
    /// Preset: Tutorial style (large, bottom-right)
    public static let tutorial = KeystrokeOverlayConfig(
        position: .bottomRight,
        style: .bold,
        fontSize: 32.0,
        backgroundOpacity: 0.9,
        displayDuration: 2.0,
        shortcutsOnly: true
    )
    
    /// Preset: Screencast style (medium, bottom-center)
    public static let screencast = KeystrokeOverlayConfig(
        position: .bottomCenter,
        style: .standard,
        fontSize: 24.0,
        displayDuration: 1.5,
        shortcutsOnly: true
    )
    
    /// Preset: Demo style (all keys, top-left)
    public static let demo = KeystrokeOverlayConfig(
        position: .topLeft,
        style: .minimal,
        fontSize: 18.0,
        backgroundOpacity: 0.6,
        displayDuration: 1.0,
        shortcutsOnly: false
    )
}

/// Active keystroke display
private struct ActiveKeystroke: Sendable {
    let event: KeyEvent
    let startTime: TimeInterval
    let config: KeystrokeOverlayConfig
    
    /// Calculate opacity at current time (1.0 → fade → 0.0)
    func opacity(at currentTime: TimeInterval) -> CGFloat {
        let elapsed = currentTime - startTime
        let totalDuration = config.displayDuration + config.fadeOutDuration
        
        if elapsed < 0 {
            return 0.0
        } else if elapsed <= config.displayDuration {
            return 1.0
        } else if elapsed <= totalDuration {
            // Fade out phase
            let fadeProgress = (elapsed - config.displayDuration) / config.fadeOutDuration
            return 1.0 - fadeProgress
        } else {
            return 0.0
        }
    }
    
    /// Check if still active
    func isActive(at currentTime: TimeInterval) -> Bool {
        let elapsed = currentTime - startTime
        let totalDuration = config.displayDuration + config.fadeOutDuration
        return elapsed >= 0 && elapsed <= totalDuration
    }
}

/// Manages keystroke overlay rendering
@MainActor
public final class KeystrokeOverlayManager: ObservableObject {
    @Published public private(set) var keyEvents: [KeyEvent] = []
    
    private var config: KeystrokeOverlayConfig
    private var recordingStartTime: Date?
    
    // Font and rendering cache
    private var fontCache: [CGFloat: NSFont] = [:]
    private let textAttributes: [NSAttributedString.Key: Any]
    
    public init(config: KeystrokeOverlayConfig = .screencast) {
        self.config = config
        
        // Setup text attributes
        let font = NSFont.systemFont(ofSize: config.fontSize, weight: .semibold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        self.textAttributes = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
    }
    
    /// Start tracking keystrokes
    public func startRecording(at startTime: Date) {
        recordingStartTime = startTime
        keyEvents.removeAll()
        fontCache.removeAll()
    }
    
    /// Add keystroke event
    public func addKeystroke(key: String, timestamp: Date, modifiers: [String] = []) {
        guard let startTime = recordingStartTime else { return }
        
        let elapsedTime = timestamp.timeIntervalSince(startTime)
        
        // Determine event type
        let type: KeyEventType = {
            if !modifiers.isEmpty {
                return .shortcut
            } else if ["⌘", "⇧", "⌥", "⌃"].contains(key) {
                return .modifier
            } else {
                return .keyPress
            }
        }()
        
        // Filter if shortcuts only
        if config.shortcutsOnly && type != .shortcut {
            return
        }
        
        let event = KeyEvent(
            key: key,
            timestamp: elapsedTime,
            type: type,
            modifiers: modifiers
        )
        
        keyEvents.append(event)
    }
    
    /// Update configuration
    public func updateConfig(_ newConfig: KeystrokeOverlayConfig) {
        config = newConfig
        fontCache.removeAll()
    }
    
    /// Render keystroke overlay at current time
    public func renderOverlay(at currentTime: TimeInterval, videoSize: CGSize, baseImage: CIImage? = nil) -> CIImage {
        var output = baseImage ?? CIImage.empty()
        
        // Get active keystrokes at this time
        let activeKeystrokes = keyEvents
            .map { event in
                ActiveKeystroke(
                    event: event,
                    startTime: event.timestamp,
                    config: config
                )
            }
            .filter { $0.isActive(at: currentTime) }
            .suffix(config.maxSimultaneousKeys) // Limit simultaneous
        
        guard !activeKeystrokes.isEmpty else {
            return output
        }
        
        // Calculate position on screen
        let overlayPosition = calculatePosition(videoSize: videoSize)
        
        // Render each active keystroke
        var yOffset: CGFloat = 0
        for activeKey in activeKeystrokes {
            let opacity = activeKey.opacity(at: currentTime)
            guard opacity > 0 else { continue }
            
            let keyImage = renderKey(
                activeKey.event.displayString,
                opacity: opacity,
                videoSize: videoSize
            )
            
            let positioned = keyImage.transformed(by: CGAffineTransform(
                translationX: overlayPosition.x,
                y: overlayPosition.y + yOffset
            ))
            
            output = positioned.composited(over: output)
            
            yOffset += keyImage.extent.height + config.padding / 2
        }
        
        return output
    }
    
    /// Calculate overlay position based on config
    private func calculatePosition(videoSize: CGSize) -> CGPoint {
        let margin: CGFloat = 40.0
        
        switch config.position {
        case .topLeft:
            return CGPoint(x: margin, y: videoSize.height - margin)
        case .topCenter:
            return CGPoint(x: videoSize.width / 2, y: videoSize.height - margin)
        case .topRight:
            return CGPoint(x: videoSize.width - margin, y: videoSize.height - margin)
        case .bottomLeft:
            return CGPoint(x: margin, y: margin)
        case .bottomCenter:
            return CGPoint(x: videoSize.width / 2, y: margin)
        case .bottomRight:
            return CGPoint(x: videoSize.width - margin, y: margin)
        case .custom(let point):
            return CGPoint(
                x: point.x * videoSize.width,
                y: point.y * videoSize.height
            )
        }
    }
    
    /// Render a single key as CIImage
    private func renderKey(_ text: String, opacity: CGFloat, videoSize: CGSize) -> CIImage {
        // Create attributed string
        let attrString = NSAttributedString(string: text, attributes: textAttributes)
        
        // Calculate text size
        let textSize = attrString.size()
        let boxWidth = textSize.width + config.padding * 2
        let boxHeight = textSize.height + config.padding * 2
        
        // Create image
        let image = NSImage(size: NSSize(width: boxWidth, height: boxHeight))
        
        image.lockFocus()
        
        // Draw background
        let bgColor = NSColor(white: 0.0, alpha: config.backgroundOpacity * opacity)
        bgColor.setFill()
        
        let bgRect = NSRect(origin: .zero, size: image.size)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: config.cornerRadius, yRadius: config.cornerRadius)
        bgPath.fill()
        
        // Draw text
        let textRect = NSRect(
            x: config.padding,
            y: config.padding,
            width: textSize.width,
            height: textSize.height
        )
        
        var mutableAttrs = textAttributes
        mutableAttrs[.foregroundColor] = NSColor(white: 1.0, alpha: opacity)
        
        let finalString = NSAttributedString(string: text, attributes: mutableAttrs)
        finalString.draw(in: textRect)
        
        image.unlockFocus()
        
        // Convert to CIImage
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            return CIImage.empty()
        }
        
        return CIImage(cgImage: cgImage)
    }
    
    /// Reset all state
    public func reset() {
        keyEvents.removeAll()
        recordingStartTime = nil
        fontCache.removeAll()
    }
}

/// Extension for converting key codes to readable names
extension KeystrokeOverlayManager {
    /// Convert CGKeyCode to readable string
    public static func keyCodeToString(_ keyCode: CGKeyCode) -> String {
        // Common key mappings
        let specialKeys: [CGKeyCode: String] = [
            53: "⎋",      // Escape
            36: "↩",      // Return
            48: "⇥",      // Tab
            51: "⌫",      // Delete
            117: "⌦",     // Forward Delete
            122: "F1",
            120: "F2",
            99: "F3",
            118: "F4",
            96: "F5",
            97: "F6",
            98: "F7",
            100: "F8",
            101: "F9",
            109: "F10",
            103: "F11",
            111: "F12",
            123: "←",     // Left arrow
            124: "→",     // Right arrow
            125: "↓",     // Down arrow
            126: "↑",     // Up arrow
            49: "␣"       // Space
        ]
        
        if let special = specialKeys[keyCode] {
            return special
        }
        
        // Try to get character from key code
        var char: UniChar = 0
        var deadKeys: UInt32 = 0
        var actualLength: Int = 0
        let keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(keyboard, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        let layoutPtr = unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)
        
        let status = UCKeyTranslate(
            layoutPtr,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysMask),
            &deadKeys,
            1,
            &actualLength,
            &char
        )
        
        if status == noErr {
            return String(UnicodeScalar(char)!).uppercased()
        }
        
        return "?"
    }
    
    /// Convert modifier flags to symbol array
    public static func modifiersToSymbols(_ flags: CGEventFlags) -> [String] {
        var symbols: [String] = []
        
        if flags.contains(.maskCommand) {
            symbols.append("⌘")
        }
        if flags.contains(.maskShift) {
            symbols.append("⇧")
        }
        if flags.contains(.maskAlternate) {
            symbols.append("⌥")
        }
        if flags.contains(.maskControl) {
            symbols.append("⌃")
        }
        
        return symbols
    }
}
