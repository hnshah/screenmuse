import Foundation
import CoreGraphics
import AppKit

/// Simulates keyboard input using CGEvent
@MainActor
public final class KeyboardSimulator {
    
    /// Type text character by character
    public static func type(_ text: String, delayBetweenKeys: TimeInterval = 0.05) async throws {
        for char in text {
            try await typeCharacter(char)
            if delayBetweenKeys > 0 {
                try await Task.sleep(nanoseconds: UInt64(delayBetweenKeys * 1_000_000_000))
            }
        }
    }
    
    /// Type a single character
    private static func typeCharacter(_ char: Character) async throws {
        let string = String(char)
        
        // Special handling for newline
        if char == "\n" {
            try await pressKey(keyCode: 0x24) // Return key
            return
        }
        
        // For regular characters, use CGEvent with the character
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw KeyboardError.eventCreationFailed
        }
        
        // Set the keyboard event's characters
        keyDown.keyboardSetUnicodeString(stringLength: string.utf16.count, unicodeString: Array(string.utf16))
        keyUp.keyboardSetUnicodeString(stringLength: string.utf16.count, unicodeString: Array(string.utf16))
        
        // Post events
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms between down/up
    }
    
    /// Press a specific key by virtual key code
    public static func pressKey(keyCode: CGKeyCode, modifiers: [Modifier] = []) async throws {
        var flags = CGEventFlags()
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            }
        }
        
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw KeyboardError.eventCreationFailed
        }
        
        keyDown.flags = flags
        keyUp.flags = flags
        
        keyDown.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        keyUp.post(tap: .cghidEventTap)
    }
    
    /// Paste text via clipboard (faster for large text)
    public static func paste(_ text: String) async throws {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        
        // Set new content
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Cmd+V
        try await pressKey(keyCode: 0x09, modifiers: [.command]) // V key
        
        try await Task.sleep(nanoseconds: 200_000_000) // Wait 200ms for paste
        
        // Restore old clipboard
        if let old = oldContents {
            pasteboard.clearContents()
            pasteboard.setString(old, forType: .string)
        }
    }
    
    public enum Modifier {
        case command, shift, option, control
    }
}

public enum KeyboardError: Error, LocalizedError {
    case eventCreationFailed
    case accessibilityPermissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .eventCreationFailed:
            return "Failed to create keyboard event"
        case .accessibilityPermissionDenied:
            return "Accessibility permission required for keyboard simulation"
        }
    }
}
