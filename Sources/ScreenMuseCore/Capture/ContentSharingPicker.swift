import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - SCContentSharingPicker wrapper (macOS 15+)

/// Wraps Apple's system-provided `SCContentSharingPicker` so agents can
/// start a recording on a user-selected window **without requiring the
/// full Screen Recording TCC permission**.
///
/// Why this matters: the default ScreenCaptureKit path requires the app
/// to hold `com.apple.security.device.capture-screen` which triggers the
/// system consent prompt on first launch and must be re-approved any
/// time the app binary's code signature changes (see
/// `scripts/reset-permissions.sh`). `SCContentSharingPicker` short-circuits
/// that friction on macOS 15+: the user picks the window they want in
/// a system sheet, and ScreenCaptureKit silently grants access to *just*
/// that window for the duration of the session. Zero prompt, zero cache,
/// zero TCC management on the app side.
///
/// Availability model:
///   * macOS 15+ — `availability.supported == true`, `present()` works
///   * macOS 14  — `availability.supported == false`, the existing
///                 ScreenCaptureKit flow stays the only option
///
/// This wrapper is intentionally thin — it surfaces exactly the two
/// questions agents and the HTTP server need to answer:
///   1. Is the picker available on this OS?
///   2. Can it be presented from the current process state?
///
/// Real picker presentation (which is a UI operation on a system sheet)
/// is isolated into one method, feature-flagged behind `@available`.
public struct ContentSharingPicker: Sendable {

    // MARK: - Availability

    public struct Availability: Codable, Sendable {
        public let supported: Bool
        public let reason: String?
        public let macosVersion: String

        enum CodingKeys: String, CodingKey {
            case supported, reason
            case macosVersion = "macos_version"
        }

        public init(supported: Bool, reason: String?, macosVersion: String) {
            self.supported = supported
            self.reason = reason
            self.macosVersion = macosVersion
        }

        public func asDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "supported": supported,
                "macos_version": macosVersion
            ]
            if let reason { dict["reason"] = reason }
            return dict
        }
    }

    /// Pure availability check — does not touch AppKit, does not
    /// present any UI, safe to call from any thread.
    public static func availability() -> Availability {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        if os.majorVersion >= 15 {
            return Availability(
                supported: true,
                reason: nil,
                macosVersion: versionString
            )
        }
        return Availability(
            supported: false,
            reason: "SCContentSharingPicker requires macOS 15 or later",
            macosVersion: versionString
        )
    }

    // MARK: - Picker configuration

    /// Options for presenting the picker. Exposed as a Codable struct so
    /// the HTTP layer can accept JSON that maps 1:1 onto SCContentSharingPickerConfiguration.
    public struct Configuration: Codable, Sendable {
        /// Filter what the picker will offer. Defaults to "any on-screen source".
        public var allowScreens: Bool
        public var allowWindows: Bool
        public var allowApplications: Bool

        public init(
            allowScreens: Bool = true,
            allowWindows: Bool = true,
            allowApplications: Bool = true
        ) {
            self.allowScreens = allowScreens
            self.allowWindows = allowWindows
            self.allowApplications = allowApplications
        }

        /// At least one source type must be enabled, otherwise the picker
        /// has nothing to display. Returns a validation error string or nil.
        public func validationError() -> String? {
            if !allowScreens && !allowWindows && !allowApplications {
                return "at least one of allow_screens / allow_windows / allow_applications must be true"
            }
            return nil
        }
    }

    // MARK: - Errors

    public enum PickerError: Error, LocalizedError, Equatable {
        case unavailable(String)
        case cancelled
        case noSelection
        case alreadyPresented
        case invalidConfiguration(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return "SCContentSharingPicker unavailable: \(reason)"
            case .cancelled:
                return "user cancelled the content-sharing picker"
            case .noSelection:
                return "the picker returned without a valid selection"
            case .alreadyPresented:
                return "another picker is already being presented"
            case .invalidConfiguration(let msg):
                return "invalid picker configuration: \(msg)"
            }
        }
    }

    // MARK: - Capability probe helpers

    /// True if the current runtime supports presenting the picker.
    /// Useful for tests and feature-flag branches without having to
    /// go through `availability()`.
    public static var isRuntimeSupported: Bool {
        availability().supported
    }

    /// Build the exact availability dictionary emitted by
    /// `GET /system/picker/availability`. Split out so unit tests
    /// can assert the wire shape without spinning the server.
    public static func availabilityResponse() -> [String: Any] {
        availability().asDictionary()
    }
}
