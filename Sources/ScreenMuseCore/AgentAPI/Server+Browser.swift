import AVFoundation
import Foundation
import Network
@preconcurrency import ScreenCaptureKit

// MARK: - Browser Recording Handlers (/browser, /browser/install, /browser/status)
//
// These endpoints drive a Node.js + Playwright subprocess that launches
// a headful Chromium window, then use ScreenMuse's standard recording
// pipeline to capture the window. The Node runner lives in
// ~/.screenmuse/playwright-runner/ and is installed on first use via
// POST /browser/install.
//
// Zero external dependencies for the Swift binary itself — Node is only
// invoked as an optional subprocess for this endpoint.

extension ScreenMuseServer {

    /// Maximum `duration_seconds` accepted by POST /browser.
    /// Matches the `POST /record` convenience endpoint.
    static let browserMaxDuration: Double = 600  // 10 minutes

    // MARK: - POST /browser/status

    func handleBrowserStatus(body: [String: Any], connection: NWConnection, reqID: Int) {
        smLog.debug("[\(reqID)] /browser/status", category: .server)
        let installer = NodeRunnerInstaller()
        let status = installer.status()
        sendResponse(connection: connection, status: 200, body: status.asDictionary())
    }

    // MARK: - POST /browser/install

    func handleBrowserInstall(body: [String: Any], connection: NWConnection, reqID: Int) async {
        // Dispatch to a job if async=true — npm install + chromium download
        // can take minutes, so most callers will want the poll-via-/job flow.
        if await dispatchAsync(endpoint: "/browser/install", body: body, connection: connection, reqID: reqID,
                               handler: { b, c, r in await self.handleBrowserInstall(body: b, connection: c, reqID: r) }) { return }

        smLog.info("[\(reqID)] /browser/install starting…", category: .server)
        let installer = NodeRunnerInstaller()

        // Run the install off the MainActor so the HTTP listener stays
        // responsive to other requests while npm install churns.
        let result: Result<NodeRunnerInstaller.Status, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let status = try installer.install { line in
                    smLog.info("[\(reqID)] [runner-install] \(line)", category: .server)
                }
                return .success(status)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let status):
            smLog.info("[\(reqID)] /browser/install complete — ready=\(status.isReady)", category: .server)
            smLog.usage("BROWSER INSTALL", details: [
                "ready": "\(status.isReady)",
                "node": status.nodePath ?? "nil"
            ])
            sendResponse(connection: connection, status: 200, body: status.asDictionary())
        case .failure(let error):
            smLog.error("[\(reqID)] /browser/install failed: \(error.localizedDescription)", category: .server)
            smLog.usage("BROWSER INSTALL FAILED", details: ["reason": error.localizedDescription])
            sendResponse(connection: connection, status: 500, body: [
                "error": error.localizedDescription,
                "code": "BROWSER_INSTALL_FAILED",
                "suggestion": "Install Node.js 18+ from https://nodejs.org, then retry POST /browser/install"
            ])
        }
    }

    // MARK: - POST /browser

    func handleBrowser(body: [String: Any], connection: NWConnection, reqID: Int) async {
        if await dispatchAsync(endpoint: "/browser", body: body, connection: connection, reqID: reqID,
                               handler: { b, c, r in await self.handleBrowser(body: b, connection: c, reqID: r) }) { return }

        // ── Validation ─────────────────────────────────────────────────
        if let err = validateBrowserRequest(body: body) {
            sendResponse(connection: connection, status: 400, body: err)
            return
        }

        // Refuse if we're already recording — browser runs take exclusive
        // ownership of the capture pipeline, same as /start and /record.
        guard !isRecording else {
            smLog.warning("[\(reqID)] /browser rejected — already recording", category: .server)
            sendResponse(connection: connection, status: 409, body: [
                "error": "Already recording",
                "code": "ALREADY_RECORDING",
                "suggestion": "Call POST /stop first, or wait for the current session to finish"
            ])
            return
        }

        let installer = NodeRunnerInstaller()
        let status = installer.status()
        guard status.isReady else {
            smLog.warning("[\(reqID)] /browser rejected — runner not installed", category: .server)
            sendResponse(connection: connection, status: 503, body: [
                "error": "Node runner not installed",
                "code": "RUNNER_NOT_INSTALLED",
                "status": status.asDictionary(),
                "suggestion": "Call POST /browser/install (first-time install downloads Playwright + Chromium, can take a couple of minutes)"
            ])
            return
        }

        let config = makeBrowserConfig(body: body)
        let name = body["name"] as? String ?? "browser-\(Int(Date().timeIntervalSince1970))"
        let quality = body["quality"] as? String ?? "medium"

        smLog.info("[\(reqID)] /browser url=\(config.url) duration=\(config.durationMs)ms script=\(config.script != nil)", category: .server)
        smLog.usage("BROWSER RECORD", details: [
            "url": truncate(config.url, to: 120),
            "duration_ms": "\(config.durationMs)",
            "has_script": "\(config.script != nil)"
        ])

        let recorder = BrowserRecorder(installer: installer, config: config)

        do {
            // 1. Launch the Node runner
            try recorder.launch()

            // 2. Wait for SM:READY with window metadata
            let ready = try await recorder.waitForReady(timeout: 45)
            smLog.info("[\(reqID)] Browser ready — window '\(ready.title)' pid=\(ready.pid)", category: .server)

            if let navErr = ready.navError {
                // Navigation failed — still proceed so the error page gets
                // recorded, but surface it in the response.
                smLog.warning("[\(reqID)] Browser nav error: \(navErr)", category: .server)
            }

            // 3. Start recording the Chromium window
            try await startBrowserRecording(
                name: name,
                windowTitle: ready.title,
                windowPid: ready.pid,
                quality: quality,
                reqID: reqID
            )

            // 4. Signal the runner to run its user script and await completion
            let outcome: BrowserRecorder.Outcome
            do {
                outcome = try await recorder.signalGoAndWaitForCompletion(
                    timeout: Double(config.durationMs) / 1000.0 + 60
                )
            } catch {
                // Runner failure — still stop the recording so we don't leak
                // state, then surface the error.
                _ = await stopAndCollectVideo(reqID: reqID)
                throw error
            }

            // 5. Stop recording and collect the video
            guard let stopResult = await stopAndCollectVideo(reqID: reqID) else {
                sendResponse(connection: connection, status: 500, body: [
                    "error": "recording stopped but no video file produced",
                    "code": "NO_VIDEO",
                    "browser": browserMetadata(ready: ready, outcome: outcome, config: config)
                ])
                return
            }

            var respBody = enrichedStopResponse(
                videoURL: stopResult.videoURL,
                elapsed: stopResult.elapsed,
                sessionID: stopResult.sessionID,
                chapters: [],
                notes: [],
                windowPid: ready.pid,
                windowApp: "Chromium",
                windowTitle: ready.title
            )
            respBody["browser"] = browserMetadata(ready: ready, outcome: outcome, config: config)

            smLog.info("[\(reqID)] ✅ Browser recording done — \(stopResult.videoURL.lastPathComponent)", category: .server)
            smLog.usage("BROWSER RECORD DONE", details: [
                "video": stopResult.videoURL.lastPathComponent,
                "elapsed": String(format: "%.1f", stopResult.elapsed)
            ])

            let statusCode: Int = (outcome.scriptError != nil || outcome.navError != nil) ? 207 : 200
            sendResponse(connection: connection, status: statusCode, body: respBody)
        } catch {
            smLog.error("[\(reqID)] /browser failed: \(error.localizedDescription)", category: .server)
            recorder.terminateRunner()
            // Best-effort cleanup — don't leave isRecording=true if we errored
            // after starting.
            if isRecording {
                _ = await stopAndCollectVideo(reqID: reqID)
            }
            sendResponse(connection: connection, status: 500, body: [
                "error": error.localizedDescription,
                "code": browserErrorCode(error)
            ])
        }
    }

    // MARK: - Helpers

    /// Pure validation — returns an error body, or nil if the request is valid.
    /// Extracted into a free helper so it can be unit-tested.
    func validateBrowserRequest(body: [String: Any]) -> [String: Any]? {
        guard let url = body["url"] as? String, !url.isEmpty else {
            return [
                "error": "'url' is required",
                "code": "MISSING_URL",
                "example": ["url": "https://example.com", "duration_seconds": 5]
            ]
        }
        // Very light sanity check — we don't enforce https or block http
        // because local file:// and http://localhost are both valid for agents.
        let lower = url.lowercased()
        if !(lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://")) {
            return [
                "error": "'url' must start with http://, https://, or file://",
                "code": "INVALID_URL",
                "received": url
            ]
        }
        let duration = (body["duration_seconds"] as? Double)
            ?? (body["duration_seconds"] as? Int).map(Double.init)
            ?? (body["duration"] as? Double)
            ?? (body["duration"] as? Int).map(Double.init)
        guard let d = duration, d > 0, d <= Self.browserMaxDuration else {
            return [
                "error": "'duration_seconds' is required and must be between 1 and \(Int(Self.browserMaxDuration))",
                "code": "INVALID_DURATION"
            ]
        }
        if let headless = body["headless"] as? Bool, headless == true {
            return [
                "error": "headless mode is not supported — browser recording requires a visible Chromium window for macOS-level screen capture",
                "code": "HEADLESS_NOT_SUPPORTED",
                "suggestion": "Omit 'headless' or set it to false"
            ]
        }
        if let w = body["width"] as? Int, (w < 320 || w > 3840) {
            return ["error": "'width' must be 320-3840", "code": "INVALID_WIDTH"]
        }
        if let h = body["height"] as? Int, (h < 240 || h > 2160) {
            return ["error": "'height' must be 240-2160", "code": "INVALID_HEIGHT"]
        }
        return nil
    }

    /// Build the `BrowserRecorder.Config` from a validated request body.
    func makeBrowserConfig(body: [String: Any]) -> BrowserRecorder.Config {
        let url = body["url"] as? String ?? ""
        let script = body["script"] as? String
        let durationSec = (body["duration_seconds"] as? Double)
            ?? (body["duration_seconds"] as? Int).map(Double.init)
            ?? (body["duration"] as? Double)
            ?? (body["duration"] as? Int).map(Double.init)
            ?? 5
        let width = body["width"] as? Int ?? 1280
        let height = body["height"] as? Int ?? 720
        return BrowserRecorder.Config(
            url: url,
            script: script,
            durationMs: Int(durationSec * 1000),
            width: width,
            height: height
        )
    }

    /// Start recording the browser window via the coordinator (effects path)
    /// or fall back to raw RecordingManager. Updates the server's session
    /// state fields the same way handleStart does, so /status and /stop can
    /// observe a browser session just like a normal one.
    private func startBrowserRecording(
        name: String,
        windowTitle: String,
        windowPid: Int,
        quality: String,
        reqID: Int
    ) async throws {
        if let coord = coordinator {
            try await coord.startRecording(
                name: name,
                windowTitle: windowTitle,
                windowPid: windowPid,
                quality: quality
            )
        } else {
            smLog.warning("[\(reqID)] /browser using raw RecordingManager (no effects)", category: .server)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: {
                $0.title?.localizedCaseInsensitiveContains(windowTitle) ?? false
            }) else {
                throw RecordingError.windowNotFound(windowTitle)
            }
            let config = RecordingConfig(
                captureSource: .window(window),
                includeSystemAudio: false,
                quality: RecordingConfig.Quality(rawValue: quality) ?? .medium,
                audioSource: .none
            )
            try await recordingManager.startRecording(config: config)
        }
        sessionID = UUID().uuidString
        sessionName = name
        startTime = Date()
        isRecording = true
        chapters = []
        highlightNextClick = false
        currentVideoURL = nil
        if let sid = sessionID {
            sessionRegistry.create(id: sid, name: name)
            sessionRegistry.defaultSessionID = sid
        }
    }

    /// Stop the current (browser) recording and return the URL + elapsed time.
    /// Mirrors the tail of handleStop, without the HTTP response/webhook logic.
    private struct StopResult {
        let videoURL: URL
        let elapsed: TimeInterval
        let sessionID: String?
    }

    private func stopAndCollectVideo(reqID: Int) async -> StopResult? {
        guard isRecording else { return nil }
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let capturedSessionID = sessionID
        sessionID = nil
        sessionName = nil
        startTime = nil
        isRecording = false
        sessionNotes.removeAll()
        sessionHighlights.removeAll()

        if let coord = coordinator {
            if let url = await coord.stopAndGetVideo() {
                currentVideoURL = url
                if let sid = capturedSessionID {
                    sessionRegistry.update(sid) { $0.videoURL = url }
                }
                return StopResult(videoURL: url, elapsed: elapsed, sessionID: capturedSessionID)
            }
            return nil
        } else {
            do {
                let url = try await recordingManager.stopRecording()
                currentVideoURL = url
                return StopResult(videoURL: url, elapsed: elapsed, sessionID: capturedSessionID)
            } catch {
                smLog.error("[\(reqID)] /browser stop failed: \(error.localizedDescription)", category: .server)
                return nil
            }
        }
    }

    private func browserMetadata(
        ready: BrowserRecorder.ReadyEvent,
        outcome: BrowserRecorder.Outcome,
        config: BrowserRecorder.Config
    ) -> [String: Any] {
        var info: [String: Any] = [
            "url_requested": config.url,
            "url_final": ready.url,
            "title": ready.title,
            "pid": ready.pid,
            "duration_ms": config.durationMs,
            "exit_code": Int(outcome.exitCode),
            "elapsed_ms": outcome.elapsedMs
        ]
        if let navErr = outcome.navError ?? ready.navError {
            info["nav_error"] = navErr
        }
        if let scriptErr = outcome.scriptError {
            info["script_error"] = scriptErr
        }
        return info
    }

    private func browserErrorCode(_ error: Error) -> String {
        if let re = error as? BrowserRecorder.RecorderError {
            switch re {
            case .runnerNotInstalled:          return "RUNNER_NOT_INSTALLED"
            case .runnerLaunchFailed:          return "RUNNER_LAUNCH_FAILED"
            case .readyTimeout:                return "READY_TIMEOUT"
            case .runnerFatal:                 return "RUNNER_FATAL"
            case .runnerExitedWithoutReady:    return "RUNNER_EXITED_WITHOUT_READY"
            case .navigationFailed:            return "NAV_FAILED"
            case .scriptFailed:                return "SCRIPT_FAILED"
            case .runnerExited:                return "RUNNER_EXITED"
            }
        }
        if let re = error as? RecordingError {
            switch re {
            case .windowNotFound: return "WINDOW_NOT_FOUND"
            case .permissionDenied: return "PERMISSION_DENIED"
            default: return "RECORDING_ERROR"
            }
        }
        return "BROWSER_ERROR"
    }

    private func truncate(_ s: String, to n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }
}
