import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
public final class PermissionManager: ObservableObject {
    @Published public var hasScreenRecording = false
    @Published public var hasAccessibility = false

    public var hasRequiredPermissions: Bool { hasScreenRecording }
    public var hasAllPermissions: Bool { hasScreenRecording && hasAccessibility }

    public init() {
        checkAll()
    }

    /// Re-check both permissions and publish updates.
    /// Safe to call frequently — CGPreflightScreenCaptureAccess() is a lightweight
    /// preflight that does not show any system prompt.
    public func checkAll() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        hasAccessibility = AXIsProcessTrusted()
    }

    /// Human-readable description of missing permissions for diagnostic display.
    public var missingPermissionsSummary: String? {
        var missing: [String] = []
        if !hasScreenRecording { missing.append("Screen Recording (required)") }
        if !hasAccessibility   { missing.append("Accessibility (optional)") }
        guard !missing.isEmpty else { return nil }
        return missing.joined(separator: ", ")
    }

    public func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        // Re-check after a short delay — the permission dialog is async
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            checkAll()
        }
    }

    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            checkAll()
        }
    }

    public func openScreenRecordingSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
    }

    public func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }
}
