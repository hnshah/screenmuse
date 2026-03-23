import Foundation

/// Base protocol for all timeline events
public protocol TimelineEvent: Sendable, Identifiable {
    var id: UUID { get }
    var startTime: TimeInterval { get set }
    var duration: TimeInterval { get set }
    var eventType: TimelineEventType { get }
    
    /// Human-readable description
    var description: String { get }
    
    /// Can this event be moved on the timeline?
    var isMovable: Bool { get }
    
    /// Can this event's duration be adjusted?
    var isDurationAdjustable: Bool { get }
    
    /// Can this event be deleted?
    var isDeletable: Bool { get }
}

/// Types of timeline events
public enum TimelineEventType: String, Sendable, CaseIterable {
    case clickRipple = "Click Ripple"
    case autoZoom = "Auto Zoom"
    case keystroke = "Keystroke"
    case cursorPosition = "Cursor"
    case custom = "Custom"
}

/// Click ripple event on timeline
public struct ClickRippleEvent: TimelineEvent {
    public let id: UUID
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public let eventType: TimelineEventType = .clickRipple
    
    public var position: CGPoint
    public var scale: CGFloat
    public var color: RippleColor
    
    public var description: String {
        "Click at (\(Int(position.x)), \(Int(position.y)))"
    }
    
    public var isMovable: Bool { true }
    public var isDurationAdjustable: Bool { true }
    public var isDeletable: Bool { true }
    
    public init(id: UUID = UUID(), startTime: TimeInterval, duration: TimeInterval, position: CGPoint, scale: CGFloat = 1.5, color: RippleColor = .blue) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.position = position
        self.scale = scale
        self.color = color
    }
}

/// Auto-zoom event on timeline
public struct AutoZoomEvent: TimelineEvent {
    public let id: UUID
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public let eventType: TimelineEventType = .autoZoom
    
    public var targetPosition: CGPoint
    public var zoomScale: CGFloat
    public var holdDuration: TimeInterval
    
    public var description: String {
        "Zoom \(String(format: "%.1fx", zoomScale)) at (\(Int(targetPosition.x)), \(Int(targetPosition.y)))"
    }
    
    public var isMovable: Bool { true }
    public var isDurationAdjustable: Bool { true }
    public var isDeletable: Bool { true }
    
    public init(id: UUID = UUID(), startTime: TimeInterval, duration: TimeInterval, targetPosition: CGPoint, zoomScale: CGFloat = 1.5, holdDuration: TimeInterval = 1.5) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.targetPosition = targetPosition
        self.zoomScale = zoomScale
        self.holdDuration = holdDuration
    }
}

/// Keystroke event on timeline
public struct KeystrokeEvent: TimelineEvent {
    public let id: UUID
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public let eventType: TimelineEventType = .keystroke
    
    public var key: String
    public var modifiers: [String]
    
    public var description: String {
        let display = modifiers.isEmpty ? key : modifiers.joined() + key
        return "Key: \(display)"
    }
    
    public var isMovable: Bool { true }
    public var isDurationAdjustable: Bool { true }
    public var isDeletable: Bool { true }
    
    public init(id: UUID = UUID(), startTime: TimeInterval, duration: TimeInterval, key: String, modifiers: [String] = []) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.key = key
        self.modifiers = modifiers
    }
}

/// Cursor position marker (for reference, not adjustable)
public struct CursorPositionEvent: TimelineEvent {
    public let id: UUID
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public let eventType: TimelineEventType = .cursorPosition
    
    public var position: CGPoint
    
    public var description: String {
        "Cursor at (\(Int(position.x)), \(Int(position.y)))"
    }
    
    public var isMovable: Bool { false }  // Cursor path is fixed
    public var isDurationAdjustable: Bool { false }
    public var isDeletable: Bool { false }
    
    public init(id: UUID = UUID(), startTime: TimeInterval, position: CGPoint) {
        self.id = id
        self.startTime = startTime
        self.duration = 0.01  // Instant
        self.position = position
    }
}

/// Ripple color options
public enum RippleColor: String, Sendable, CaseIterable {
    case blue = "Blue"
    case green = "Green"
    case red = "Red"
    case yellow = "Yellow"
    case purple = "Purple"
    case white = "White"
    
    public var cgColor: CGColor {
        switch self {
        case .blue:
            return CGColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1.0)
        case .green:
            return CGColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 1.0)
        case .red:
            return CGColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
        case .yellow:
            return CGColor(red: 1.0, green: 0.9, blue: 0.2, alpha: 1.0)
        case .purple:
            return CGColor(red: 0.7, green: 0.3, blue: 0.9, alpha: 1.0)
        case .white:
            return CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        }
    }
}
