import AppKit
import Foundation
import Network
@preconcurrency import ScreenCaptureKit

// MARK: - Recording Handlers (/start, /stop, /pause, /resume, /chapter, /highlight, /note, /screenshot)

extension ScreenMuseServer {

    func handleStart(body: [String: Any], connection: NWConnection, reqID: Int) async {
        guard !isRecording else {
            smLog.warning("[\(reqID)] /start rejected — already recording session=\(sessionID ?? "?")", category: .server)
            sendResponse(connection: connection, status: 409, body: [
                "error": "Already recording",
                "code": "ALREADY_RECORDING",
                "suggestion": "Call POST /stop first to stop the current recording"
            ])
            return
        }
        let name = body["name"] as? String ?? "recording-\(Date().timeIntervalSince1970)"
        let windowTitle = body["window_title"] as? String
        let windowPid = body["window_pid"] as? Int
        let quality = body["quality"] as? String
        let audioSourceStr = body["audio_source"] as? String
        let regionDict = body["region"] as? [String: Any]
        let regionRect: CGRect? = regionDict.flatMap { d in
            guard let w = (d["width"] as? Double) ?? (d["width"] as? Int).map(Double.init),
                  let h = (d["height"] as? Double) ?? (d["height"] as? Int).map(Double.init),
                  w > 0, h > 0 else { return nil }
            let x = (d["x"] as? Double) ?? (d["x"] as? Int).map(Double.init) ?? 0
            let y = (d["y"] as? Double) ?? (d["y"] as? Int).map(Double.init) ?? 0
            return CGRect(x: x, y: y, width: w, height: h)
        }
        // Validate region against display bounds before attempting capture
        if let rect = regionRect {
            let unionBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            guard rect.width > 0, rect.height > 0 else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "Invalid region: width and height must be greater than 0",
                    "code": "INVALID_REGION"
                ])
                return
            }
            guard rect.origin.x >= unionBounds.minX, rect.origin.y >= unionBounds.minY,
                  rect.maxX <= unionBounds.maxX, rect.maxY <= unionBounds.maxY else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "Region \(Int(rect.width))×\(Int(rect.height)) at (\(Int(rect.origin.x)),\(Int(rect.origin.y))) falls outside display bounds \(Int(unionBounds.width))×\(Int(unionBounds.height))",
                    "code": "REGION_OUT_OF_BOUNDS",
                    "display_bounds": ["x": unionBounds.origin.x, "y": unionBounds.origin.y, "width": unionBounds.width, "height": unionBounds.height]
                ])
                return
            }
        }

        let webhookURL: URL? = (body["webhook"] as? String).flatMap { URL(string: $0) }
        if let wh = webhookURL { self.pendingWebhookURL = wh }
        smLog.info("[\(reqID)] Starting recording name='\(name)' quality=\(quality ?? "medium") windowTitle=\(windowTitle ?? "nil") region=\(regionRect.map { "\(Int($0.width))x\(Int($0.height))" } ?? "full")", category: .server)
        do {
            if let coord = coordinator {
                smLog.debug("[\(reqID)] Routing through coordinator (effects pipeline)", category: .server)
                try await coord.startRecording(name: name, windowTitle: windowTitle, windowPid: windowPid, quality: quality)
            } else {
                smLog.warning("[\(reqID)] No coordinator set — falling back to raw RecordingManager (no effects)", category: .server)
                let source: CaptureSource
                if let title = windowTitle {
                    smLog.debug("[\(reqID)] Looking up window: '\(title)'", category: .capture)
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    if let window = content.windows.first(where: { $0.title?.localizedCaseInsensitiveContains(title) ?? false }) {
                        smLog.info("[\(reqID)] Found window: '\(window.title ?? "?")' pid=\(window.owningApplication?.processID ?? 0)", category: .capture)
                        source = .window(window)
                    } else {
                        smLog.error("[\(reqID)] Window not found: '\(title)'", category: .capture)
                        sendResponse(connection: connection, status: 404, body: [
                            "error": "Window not found: '\(title)'",
                            "code": "WINDOW_NOT_FOUND",
                            "suggestion": "Call GET /windows to see available windows"
                        ])
                        return
                    }
                } else if let rect = regionRect {
                    smLog.debug("[\(reqID)] Region capture: \(Int(rect.width))×\(Int(rect.height)) at (\(Int(rect.origin.x)),\(Int(rect.origin.y)))", category: .capture)
                    source = .region(rect)
                } else {
                    smLog.debug("[\(reqID)] Using full screen capture", category: .capture)
                    source = .fullScreen
                }
                let resolvedQuality = RecordingConfig.Quality(rawValue: quality ?? "medium") ?? .medium
                let resolvedAudioSource: RecordingConfig.AudioSource
                switch audioSourceStr?.lowercased() {
                case "none", "off", "silent": resolvedAudioSource = .none
                case nil, "system", "all": resolvedAudioSource = .system
                default:
                    resolvedAudioSource = .appOnly(audioSourceStr!)
                }
                let config = RecordingConfig(
                    captureSource: source,
                    includeSystemAudio: resolvedAudioSource != RecordingConfig.AudioSource.none,
                    quality: resolvedQuality,
                    audioSource: resolvedAudioSource
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
            sessionRegistry.create(id: sessionID!, name: name)
            sessionRegistry.defaultSessionID = sessionID
            var resp: [String: Any] = [
                "session_id": sessionID!,
                "status": "recording",
                "name": name,
                "quality": quality ?? "medium"
            ]
            if let wt = windowTitle { resp["window_title"] = wt }
            if let wp = windowPid { resp["window_pid"] = wp }
            smLog.info("[\(reqID)] ✅ Recording started — session=\(sessionID!)", category: .server)
            var usageDetails: [String: String] = ["name": name, "quality": quality ?? "medium", "session": sessionID!]
            if let wt = windowTitle { usageDetails["window"] = wt }
            smLog.usage("RECORD START", details: usageDetails)
            sendResponse(connection: connection, status: 200, body: resp)
        } catch let err as RecordingError {
            smLog.error("[\(reqID)] /start failed (RecordingError): \(err.errorDescription ?? "\(err)")", category: .server)
            smLog.usage("RECORD ERROR", details: ["code": "RecordingError", "reason": err.errorDescription ?? "\(err)"])
            sendResponse(connection: connection, status: 500, body: structuredError(err))
        } catch {
            smLog.error("[\(reqID)] /start failed (unknown): \(error.localizedDescription)", category: .server)
            smLog.usage("RECORD ERROR", details: ["code": "unknown", "reason": error.localizedDescription])
            sendResponse(connection: connection, status: 500, body: [
                "error": error.localizedDescription,
                "code": "UNKNOWN_ERROR"
            ])
        }
    }

    func handleStop(body: [String: Any], connection: NWConnection, reqID: Int) async {
        guard isRecording else {
            smLog.warning("[\(reqID)] /stop rejected — not currently recording", category: .server)
            sendResponse(connection: connection, status: 409, body: ["error": "not recording"])
            return
        }
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        smLog.info("[\(reqID)] Stopping recording session=\(sessionID ?? "?") elapsed=\(String(format: "%.1f", elapsed))s chapters=\(chapters.count)", category: .server)
        let metadata: [String: Any] = [
            "session_id": sessionID ?? "",
            "name": sessionName ?? "",
            "elapsed": elapsed,
            "chapters": chapters.map { ["name": $0.name, "time": $0.time] }
        ]
        let capturedSessionID = sessionID
        let capturedSessionName = sessionName
        let capturedNotes = sessionNotes
        let capturedChapters = chapters
        let capturedWebhook = pendingWebhookURL
        sessionID = nil
        sessionName = nil
        startTime = nil
        isRecording = false
        sessionNotes.removeAll()
        sessionHighlights.removeAll()
        pendingWebhookURL = nil

        // Sync session state to registry before stopping
        if let sid = capturedSessionID {
            sessionRegistry.update(sid) { session in
                session.isRecording = false
                session.chapters = capturedChapters
                session.notes = capturedNotes
            }
        }

        if let coord = coordinator {
            smLog.debug("[\(reqID)] Awaiting coordinator.stopAndGetVideo() — effects compositing in progress...", category: .server)
            smLog.usage("EFFECTS COMPOSITING  started — applying zoom + click effects to raw video")
            if let url = await coord.stopAndGetVideo() {
                currentVideoURL = url
                if let sid = capturedSessionID {
                    sessionRegistry.update(sid) { $0.videoURL = url }
                }
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576)
                smLog.info("[\(reqID)] ✅ Video ready: \(url.path)", category: .server)
                smLog.usage("RECORD STOP", details: [
                    "elapsed": String(format: "%.0fs", elapsed),
                    "chapters": "\(capturedChapters.count)",
                    "size": "\(sizeMB)MB",
                    "video": url.lastPathComponent
                ])
                let resp = enrichedStopResponse(
                    videoURL: url, elapsed: elapsed,
                    sessionID: capturedSessionID,
                    chapters: capturedChapters,
                    notes: capturedNotes
                )
                sendResponse(connection: connection, status: 200, body: resp)
                fireWebhook(capturedWebhook, videoURL: url, sessionID: capturedSessionID, elapsed: elapsed)
            } else {
                smLog.error("[\(reqID)] coordinator.stopAndGetVideo() returned nil — video finalization failed", category: .server)
                smLog.usage("RECORD ERROR  Video finalization failed — coordinator returned nil")
                sendResponse(connection: connection, status: 500, body: ["error": "Recording stopped but video could not be finalized"])
            }
        } else {
            smLog.debug("[\(reqID)] No coordinator — using raw RecordingManager.stopRecording()", category: .server)
            do {
                let url = try await recordingManager.stopRecording()
                currentVideoURL = url
                if let sid = capturedSessionID {
                    sessionRegistry.update(sid) { $0.videoURL = url }
                }
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576)
                smLog.info("[\(reqID)] ✅ Video saved: \(url.path)", category: .server)
                smLog.usage("RECORD STOP (raw)", details: [
                    "elapsed": String(format: "%.0fs", elapsed),
                    "size": "\(sizeMB)MB",
                    "video": url.lastPathComponent
                ])
                let resp = enrichedStopResponse(
                    videoURL: url, elapsed: elapsed,
                    sessionID: capturedSessionID,
                    chapters: capturedChapters,
                    notes: capturedNotes
                )
                sendResponse(connection: connection, status: 200, body: resp)
                fireWebhook(capturedWebhook, videoURL: url, sessionID: capturedSessionID, elapsed: elapsed)
            } catch {
                smLog.error("[\(reqID)] stopRecording() threw: \(error.localizedDescription)", category: .server)
                smLog.usage("RECORD ERROR  \(error.localizedDescription)")
                sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
            }
        }
        _ = capturedSessionName
        _ = metadata
    }

    func handlePause(body: [String: Any], connection: NWConnection, reqID: Int) async {
        guard isRecording else {
            smLog.warning("[\(reqID)] /pause rejected — not recording", category: .server)
            sendResponse(connection: connection, status: 409, body: ["error": "Not recording", "code": "NOT_RECORDING"])
            return
        }
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        smLog.info("[\(reqID)] Pausing at elapsed=\(String(format: "%.1f", elapsed))s", category: .server)
        do {
            if let coord = coordinator {
                try await coord.pauseRecording()
            } else {
                try await recordingManager.pauseRecording()
            }
            smLog.info("[\(reqID)] ✅ Paused", category: .server)
            smLog.usage("PAUSED", details: ["at": String(format: "%.0fs", elapsed)])
            sendResponse(connection: connection, status: 200, body: ["status": "paused", "elapsed": elapsed])
        } catch {
            smLog.error("[\(reqID)] /pause failed: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: structuredError(error))
        }
    }

    func handleResume(body: [String: Any], connection: NWConnection, reqID: Int) async {
        guard isRecording else {
            smLog.warning("[\(reqID)] /resume rejected — not recording", category: .server)
            sendResponse(connection: connection, status: 409, body: ["error": "Not recording", "code": "NOT_RECORDING"])
            return
        }
        smLog.info("[\(reqID)] Resuming recording", category: .server)
        do {
            if let coord = coordinator {
                try await coord.resumeRecording()
            } else {
                try await recordingManager.resumeRecording()
            }
            let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
            smLog.info("[\(reqID)] ✅ Resumed at elapsed=\(String(format: "%.1f", elapsed))s", category: .server)
            smLog.usage("RESUMED", details: ["at": String(format: "%.0fs", elapsed)])
            sendResponse(connection: connection, status: 200, body: ["status": "recording", "elapsed": elapsed])
        } catch {
            smLog.error("[\(reqID)] /resume failed: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: structuredError(error))
        }
    }

    func handleChapter(body: [String: Any], connection: NWConnection, reqID: Int) {
        let name = body["name"] as? String ?? "Chapter"
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        chapters.append((name: name, time: elapsed))
        smLog.info("[\(reqID)] Chapter '\(name)' at \(String(format: "%.1f", elapsed))s (total chapters: \(chapters.count))", category: .server)
        smLog.usage("CHAPTER", details: ["name": name, "at": String(format: "%.0fs", elapsed), "total": "\(chapters.count)"])
        sendResponse(connection: connection, status: 200, body: ["ok": true, "time": elapsed])
    }

    func handleHighlight(body: [String: Any], connection: NWConnection, reqID: Int) {
        highlightNextClick = true
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        sessionHighlights.append(elapsed)
        smLog.info("[\(reqID)] Highlight flag set — next click will be highlighted", category: .server)
        smLog.usage("HIGHLIGHT  next click flagged for auto-zoom + enhanced effect")
        sendResponse(connection: connection, status: 200, body: ["ok": true, "timestamp": elapsed])
    }

    func handleNote(body: [String: Any], connection: NWConnection, reqID: Int) {
        let text = body["text"] as? String ?? body["note"] as? String ?? ""
        guard !text.isEmpty else {
            smLog.warning("[\(reqID)] /note called with empty text", category: .server)
            sendResponse(connection: connection, status: 400, body: ["error": "body must include 'text' field", "example": "{\"text\": \"audio dropped here\"}"])
            return
        }
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        sessionNotes.append((text: text, time: elapsed))
        var noteDetails: [String: String] = ["text": text]
        if isRecording { noteDetails["recording_elapsed"] = String(format: "%.0fs", elapsed) }
        smLog.usage("📝 NOTE", details: noteDetails)
        smLog.info("[\(reqID)] Note recorded: \"\(text)\"", category: .server)
        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "note": text,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "recording_elapsed": isRecording ? elapsed : -1
        ])
    }

    func handleScreenshot(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] Screenshot requested path=\(body["path"] as? String ?? "(auto)")", category: .capture)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                smLog.error("[\(reqID)] No display found for screenshot", category: .capture)
                sendResponse(connection: connection, status: 500, body: ["error": "No display found"])
                return
            }
            smLog.debug("[\(reqID)] Capture display \(display.width)x\(display.height)", category: .capture)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let savePath: URL
            if let customPath = body["path"] as? String {
                savePath = URL(fileURLWithPath: customPath)
            } else {
                let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
                let screenshotDir = moviesURL.appendingPathComponent("ScreenMuse/Screenshots", isDirectory: true)
                try FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
                let fileName = "screenshot-\(formatter.string(from: Date())).png".replacingOccurrences(of: ":", with: "-")
                savePath = screenshotDir.appendingPathComponent(fileName)
            }

            if #available(macOS 14.0, *) {
                smLog.debug("[\(reqID)] Calling SCScreenshotManager.captureImage()", category: .capture)
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let pngData = rep.representation(using: .png, properties: [:]) else {
                    smLog.error("[\(reqID)] PNG conversion failed", category: .capture)
                    sendResponse(connection: connection, status: 500, body: ["error": "PNG conversion failed"])
                    return
                }
                try pngData.write(to: savePath)
                let sizeMB = String(format: "%.2f", Double(pngData.count) / 1_048_576)
                smLog.info("[\(reqID)] ✅ Screenshot saved: \(savePath.path) (\(pngData.count) bytes, \(cgImage.width)x\(cgImage.height))", category: .capture)
                smLog.usage("SCREENSHOT", details: ["file": savePath.lastPathComponent, "size": "\(sizeMB)MB", "resolution": "\(cgImage.width)x\(cgImage.height)"])
                sendResponse(connection: connection, status: 200, body: [
                    "path": savePath.path,
                    "width": cgImage.width,
                    "height": cgImage.height,
                    "size": pngData.count
                ])
            } else {
                smLog.error("[\(reqID)] Screenshot API requires macOS 14+", category: .capture)
                sendResponse(connection: connection, status: 400, body: ["error": "Screenshot API requires macOS 14+"])
            }
        } catch {
            smLog.error("[\(reqID)] /screenshot failed: \(error.localizedDescription)", category: .capture)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    // MARK: POST /record — convenience: start + wait + stop in one call

    func handleRecord(body: [String: Any], connection: NWConnection, reqID: Int) async {
        guard let rawDuration = body["duration_seconds"] ?? body["duration"],
              let duration = (rawDuration as? Double) ?? (rawDuration as? Int).map(Double.init),
              duration > 0, duration <= 3600 else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "duration_seconds is required and must be between 1 and 3600",
                "code": "INVALID_DURATION"
            ])
            return
        }

        guard !isRecording else {
            sendResponse(connection: connection, status: 409, body: [
                "error": "Already recording",
                "code": "ALREADY_RECORDING",
                "suggestion": "Call POST /stop first to stop the current recording"
            ])
            return
        }

        // Start recording using the same logic as /start
        let name = body["name"] as? String ?? "recording-\(Date().timeIntervalSince1970)"
        let windowTitle = body["window_title"] as? String
        let windowPid = body["window_pid"] as? Int
        let quality = body["quality"] as? String
        let webhookURL: URL? = (body["webhook"] as? String).flatMap { URL(string: $0) }
        if let wh = webhookURL { self.pendingWebhookURL = wh }

        smLog.info("[\(reqID)] /record start — name='\(name)' duration=\(duration)s", category: .server)
        smLog.usage("RECORD ONE-SHOT START", details: ["name": name, "duration": "\(duration)s"])

        do {
            if let coord = coordinator {
                try await coord.startRecording(name: name, windowTitle: windowTitle, windowPid: windowPid, quality: quality)
            } else {
                let source: CaptureSource
                if let title = windowTitle {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    if let window = content.windows.first(where: { $0.title?.localizedCaseInsensitiveContains(title) ?? false }) {
                        source = .window(window)
                    } else {
                        sendResponse(connection: connection, status: 404, body: [
                            "error": "Window not found: '\(title)'",
                            "code": "WINDOW_NOT_FOUND",
                            "suggestion": "Call GET /windows to see available windows"
                        ])
                        return
                    }
                } else {
                    source = .fullScreen
                }
                let resolvedQuality = RecordingConfig.Quality(rawValue: quality ?? "medium") ?? .medium
                let config = RecordingConfig(captureSource: source, quality: resolvedQuality)
                try await recordingManager.startRecording(config: config)
            }
        } catch {
            smLog.error("[\(reqID)] /record start failed: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: structuredError(error))
            return
        }

        sessionID = UUID().uuidString
        sessionName = name
        startTime = Date()
        isRecording = true
        chapters = []
        highlightNextClick = false
        currentVideoURL = nil
        sessionRegistry.create(id: sessionID!, name: name)
        sessionRegistry.defaultSessionID = sessionID

        smLog.info("[\(reqID)] /record recording for \(duration)s...", category: .server)

        // Wait for duration
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        // Stop and return enriched response
        smLog.info("[\(reqID)] /record stopping after \(duration)s", category: .server)
        await handleStop(body: [:], connection: connection, reqID: reqID)
        smLog.usage("RECORD ONE-SHOT STOP", details: ["name": name, "duration": "\(duration)s"])
    }
}
