import SwiftUI
import ScreenCaptureKit
import ScreenMuseCore

@MainActor
final class RecordViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedSourceIndex = 0
    @Published var includeSystemAudio = true
    @Published var includeMicrophone = false

    private let recordingManager = RecordingManager()
    private var timer: Timer?

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func startRecording() async {
        let source: CaptureSource
        if selectedSourceIndex == 0 {
            source = .fullScreen
        } else {
            let windowIndex = selectedSourceIndex - 1
            guard windowIndex < availableWindows.count else { return }
            source = .window(availableWindows[windowIndex])
        }

        let config = RecordingConfig(
            captureSource: source,
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: includeMicrophone
        )

        do {
            try await recordingManager.startRecording(config: config)
            isRecording = true
            duration = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.duration += 1
                }
            }
        } catch {
            print("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        timer?.invalidate()
        timer = nil
        do {
            let url = try await recordingManager.stopRecording()
            isRecording = false
            print("Recording saved to \(url.path)")
        } catch {
            print("Failed to stop recording: \(error.localizedDescription)")
        }
    }

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            availableWindows = content.windows.filter { $0.isOnScreen }
        } catch {
            print("Failed to refresh windows: \(error.localizedDescription)")
        }
    }
}
