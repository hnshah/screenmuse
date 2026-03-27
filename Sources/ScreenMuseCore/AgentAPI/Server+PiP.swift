import Foundation
import Network
import ScreenCaptureKit

// MARK: - PiP Handlers (/start/pip, PiP stop flow)

extension ScreenMuseServer {

    func handleStartPiP(body: [String: Any], connection: NWConnection, reqID: Int) async {
        guard !isRecording else {
            sendResponse(connection: connection, status: 409, body: [
                "error": "Already recording. Stop the current session first.",
                "code": "ALREADY_RECORDING"
            ])
            return
        }

        let windowNames = body["windows"] as? [String] ?? []
        guard windowNames.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "'windows' must be an array of at least 2 app names or titles",
                "example": "{\"windows\": [\"Google Chrome\", \"Terminal\"], \"layout\": \"picture-in-picture\"}"
            ])
            return
        }

        let layoutStr = body["layout"] as? String ?? "picture-in-picture"
        let layout = PiPRecordingManager.Layout(rawValue: layoutStr) ?? .pictureInPicture
        let quality = RecordingConfig.Quality(rawValue: body["quality"] as? String ?? "medium") ?? .medium
        let fps = body["fps"] as? Int ?? 30
        let overlayScale = body["overlay_scale"] as? Double ?? 0.25
        let includeAudio = body["include_audio"] as? Bool ?? true

        smLog.info("[\(reqID)] /start/pip windows=\(windowNames) layout=\(layoutStr)", category: .server)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            func findWindow(_ query: String) -> SCWindow? {
                content.windows.first(where: { $0.title?.localizedCaseInsensitiveContains(query) ?? false })
                ?? content.windows.first(where: { $0.owningApplication?.applicationName.localizedCaseInsensitiveContains(query) ?? false })
                ?? content.windows.first(where: { $0.owningApplication?.bundleIdentifier.localizedCaseInsensitiveContains(query) ?? false })
            }

            guard let primaryWindow = findWindow(windowNames[0]) else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "Primary window not found: '\(windowNames[0])'",
                    "code": "WINDOW_NOT_FOUND",
                    "tip": "Use GET /windows to see available windows"
                ])
                return
            }
            guard let overlayWindow = findWindow(windowNames[1]) else {
                sendResponse(connection: connection, status: 404, body: [
                    "error": "Overlay window not found: '\(windowNames[1])'",
                    "code": "WINDOW_NOT_FOUND",
                    "tip": "Use GET /windows to see available windows"
                ])
                return
            }

            var pipConfig = PiPRecordingManager.PiPConfig()
            pipConfig.layout = layout
            pipConfig.quality = quality
            pipConfig.fps = fps
            pipConfig.overlayScale = overlayScale
            pipConfig.includeAudio = includeAudio

            try await pipManager.startRecording(
                primaryWindow: primaryWindow,
                overlayWindow: overlayWindow,
                config: pipConfig
            )

            sessionID = UUID().uuidString
            sessionName = body["name"] as? String ?? "pip-recording"
            startTime = Date()
            isRecording = true

            sendResponse(connection: connection, status: 200, body: [
                "session_id": sessionID!,
                "status": "recording",
                "mode": "pip",
                "layout": layoutStr,
                "primary_window": primaryWindow.title ?? windowNames[0],
                "overlay_window": overlayWindow.title ?? windowNames[1]
            ])
        } catch let err as PiPRecordingManager.PiPError {
            smLog.error("[\(reqID)] /start/pip failed: \(err.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: [
                "error": err.errorDescription ?? err.localizedDescription,
                "code": "PIP_FAILED"
            ])
        } catch {
            smLog.error("[\(reqID)] /start/pip error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    /// Handle /stop when a PiP session is active. Returns true if PiP was active and handled.
    func handlePiPStop(body: [String: Any], connection: NWConnection, reqID: Int) async -> Bool {
        guard pipManager.isRecording else { return false }

        smLog.info("[\(reqID)] Stopping PiP session", category: .server)
        do {
            let url = try await pipManager.stopRecording()
            isRecording = false
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            currentVideoURL = url
            smLog.usage("RECORD STOP (PiP)", details: ["elapsed": "\(Int(elapsed))s", "file": url.lastPathComponent])

            let capturedSessionID = sessionID
            let capturedChapters = chapters
            let capturedNotes = sessionNotes

            sessionID = nil
            startTime = nil
            chapters.removeAll()

            let resp = enrichedStopResponse(
                videoURL: url, elapsed: elapsed,
                sessionID: capturedSessionID,
                chapters: capturedChapters,
                notes: capturedNotes
            )
            var enrichedResp = resp
            enrichedResp["mode"] = "pip"
            sendResponse(connection: connection, status: 200, body: enrichedResp)
        } catch {
            smLog.error("[\(reqID)] PiP stop failed: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
        return true
    }
}
