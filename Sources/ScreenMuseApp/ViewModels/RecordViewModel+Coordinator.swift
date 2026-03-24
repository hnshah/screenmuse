import ScreenMuseCore

// MARK: - RecordingCoordinating
// Connects RecordViewModel (ScreenMuseApp) to ScreenMuseServer (ScreenMuseCore)
// so the agent API gets the full effects pipeline (click ripples, zoom, keystroke overlay).

extension RecordViewModel: RecordingCoordinating {
    func pauseRecording() async throws {
        try await recordingManager.pauseRecording()
        timer?.invalidate()
    }

    func resumeRecording() async throws {
        try await recordingManager.resumeRecording()
    }
}
