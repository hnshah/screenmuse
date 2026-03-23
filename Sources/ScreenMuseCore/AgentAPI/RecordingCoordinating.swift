import Foundation

/// Protocol implemented by RecordViewModel (in ScreenMuseApp) so that
/// ScreenMuseServer (in ScreenMuseCore) can call the full effects pipeline
/// without a circular dependency.
@MainActor
public protocol RecordingCoordinating: AnyObject {
    var isRecording: Bool { get }
    /// Start recording. windowTitle/windowPid specify a specific window; nil = full screen.
    /// quality is the RecordingConfig.Quality rawValue string ("low"/"medium"/"high"/"max").
    func startRecording(name: String, windowTitle: String?, windowPid: Int?, quality: String?) async throws
    func stopAndGetVideo() async -> URL?
}
