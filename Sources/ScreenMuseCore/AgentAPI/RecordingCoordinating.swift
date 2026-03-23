import Foundation

/// Protocol implemented by RecordViewModel (in ScreenMuseApp) so that
/// ScreenMuseServer (in ScreenMuseCore) can call the full effects pipeline
/// without a circular dependency.
@MainActor
public protocol RecordingCoordinating: AnyObject {
    var isRecording: Bool { get }
    func startRecording(name: String) async throws
    func stopAndGetVideo() async -> URL?
}
