import AVFoundation
import ScreenCaptureKit

@MainActor
public final class PermissionsManager: ObservableObject {
    @Published public var hasScreenPermission = false
    @Published public var hasMicPermission = false

    public init() {}

    public func checkAndRequestPermissions() async {
        await checkScreenPermission()
        await checkMicPermission()
    }

    private func checkScreenPermission() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            hasScreenPermission = true
        } catch {
            hasScreenPermission = false
        }
    }

    private func checkMicPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicPermission = true
        case .notDetermined:
            hasMicPermission = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            hasMicPermission = false
        }
    }
}
