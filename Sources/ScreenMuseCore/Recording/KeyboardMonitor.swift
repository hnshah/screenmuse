@preconcurrency import AppKit
import ApplicationServices
import Combine
import Carbon

/// Monitors keyboard events globally
@MainActor
public final class KeyboardMonitor: ObservableObject {
    @Published public private(set) var events: [(key: String, modifiers: [String], timestamp: Date)] = []
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    public init() {}
    
    /// Start monitoring keyboard events
    public func startMonitoring() {
        // Request accessibility permission if needed
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        
        guard accessEnabled else {
            smLog.warning("Accessibility permission required for keyboard monitoring — keystroke overlay will be disabled", category: .permissions)
            return
        }
        
        // Create event tap
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                Task { @MainActor in
                    monitor.handleKeyEvent(event)
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            smLog.error("Failed to create CGEvent tap for keyboard monitoring — accessibility may not be granted", category: .permissions)
            return
        }
        
        self.eventTap = eventTap
        
        // Add to run loop
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        self.runLoopSource = runLoopSource
        
        // Enable the tap
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
    
    /// Stop monitoring
    public func stopMonitoring() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }
    
    /// Handle individual key event
    private func handleKeyEvent(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        // Convert to readable string
        let key = KeystrokeOverlayManager.keyCodeToString(keyCode)
        let modifiers = KeystrokeOverlayManager.modifiersToSymbols(flags)
        
        // Record event
        events.append((key: key, modifiers: modifiers, timestamp: Date()))
    }
    
    /// Clear recorded events
    public func clearEvents() {
        events.removeAll()
    }
    
    /// Clean up on deinit
    deinit {
        // Schedule cleanup on main actor since stopMonitoring is @MainActor
        let tap = eventTap
        let src = runLoopSource
        DispatchQueue.main.async { @Sendable in
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let src = src {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
    }
}
