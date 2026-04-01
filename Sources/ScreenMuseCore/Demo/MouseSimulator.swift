import Foundation
import CoreGraphics
import AppKit

/// Simulates mouse movements and clicks using CGEvent
@MainActor
public final class MouseSimulator {
    
    /// Click at current mouse position
    public static func click(button: MouseButton = .left, doubleClick: Bool = false) async throws {
        let currentLocation = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: currentLocation.x, y: CGDisplayBounds(CGMainDisplayID()).height - currentLocation.y)
        
        try await click(at: cgPoint, button: button, doubleClick: doubleClick)
    }
    
    /// Click at specific coordinates (screen coordinates)
    public static func click(at point: CGPoint, button: MouseButton = .left, doubleClick: Bool = false) async throws {
        let (downType, upType) = button.eventTypes
        
        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button.cgButton),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button.cgButton) else {
            throw MouseError.eventCreationFailed
        }
        
        if doubleClick {
            mouseDown.setIntegerValueField(.mouseEventClickState, value: 2)
            mouseUp.setIntegerValueField(.mouseEventClickState, value: 2)
        }
        
        mouseDown.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        mouseUp.post(tap: .cghidEventTap)
        
        if doubleClick {
            try await Task.sleep(nanoseconds: 100_000_000) // Extra delay for double-click
        }
    }
    
    /// Move mouse to specific coordinates with smooth animation
    public static func moveTo(_ point: CGPoint, duration: TimeInterval = 0.3) async throws {
        let currentLocation = NSEvent.mouseLocation
        let currentPoint = CGPoint(x: currentLocation.x, y: CGDisplayBounds(CGMainDisplayID()).height - currentLocation.y)
        
        let steps = Int(duration * 60) // 60fps
        let stepDuration = duration / Double(steps)
        
        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let x = currentPoint.x + (point.x - currentPoint.x) * progress
            let y = currentPoint.y + (point.y - currentPoint.y) * progress
            let intermediatePoint = CGPoint(x: x, y: y)
            
            guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: intermediatePoint, mouseButton: .left) else {
                throw MouseError.eventCreationFailed
            }
            
            moveEvent.post(tap: .cghidEventTap)
            
            if i < steps {
                try await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
        }
    }
    
    /// Drag from current position to target
    public static func drag(to point: CGPoint, button: MouseButton = .left, duration: TimeInterval = 0.5) async throws {
        let currentLocation = NSEvent.mouseLocation
        let currentPoint = CGPoint(x: currentLocation.x, y: CGDisplayBounds(CGMainDisplayID()).height - currentLocation.y)
        
        // Mouse down
        let (downType, upType) = button.eventTypes
        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: currentPoint, mouseButton: button.cgButton) else {
            throw MouseError.eventCreationFailed
        }
        mouseDown.post(tap: .cghidEventTap)
        
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Drag
        let steps = Int(duration * 60)
        let stepDuration = duration / Double(steps)
        
        for i in 1...steps {
            let progress = Double(i) / Double(steps)
            let x = currentPoint.x + (point.x - currentPoint.x) * progress
            let y = currentPoint.y + (point.y - currentPoint.y) * progress
            let dragPoint = CGPoint(x: x, y: y)
            
            guard let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: dragPoint, mouseButton: button.cgButton) else {
                throw MouseError.eventCreationFailed
            }
            
            dragEvent.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
        }
        
        // Mouse up
        guard let mouseUp = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button.cgButton) else {
            throw MouseError.eventCreationFailed
        }
        mouseUp.post(tap: .cghidEventTap)
    }
    
    public enum MouseButton {
        case left, right, middle
        
        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .right: return .right
            case .middle: return .center
            }
        }
        
        var eventTypes: (down: CGEventType, up: CGEventType) {
            switch self {
            case .left: return (.leftMouseDown, .leftMouseUp)
            case .right: return (.rightMouseDown, .rightMouseUp)
            case .middle: return (.otherMouseDown, .otherMouseUp)
            }
        }
    }
}

public enum MouseError: Error, LocalizedError {
    case eventCreationFailed
    
    public var errorDescription: String? {
        "Failed to create mouse event"
    }
}
