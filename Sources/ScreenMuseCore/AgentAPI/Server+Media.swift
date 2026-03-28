import AVFoundation
import AppKit
import Foundation
import Network
import Vision

// MARK: - Media Handlers (/timeline, /validate, /annotate, /script, /upload/icloud)

extension ScreenMuseServer {

    func handleTimeline(body: [String: Any], connection: NWConnection, reqID: Int) {
        let sid = sessionID ?? "last"
        let sessionStart = startTime
        let elapsed = sessionStart.map { Date().timeIntervalSince($0) } ?? 0

        let chaptersJSON: [[String: Any]] = chapters.map { ["name": $0.name, "time": $0.time] }
        let notesJSON: [[String: Any]] = sessionNotes.map { ["text": $0.text, "time": $0.time] }
        let highlightsJSON: [Double] = sessionHighlights

        sendResponse(connection: connection, status: 200, body: [
            "session_id": sid,
            "recording": isRecording,
            "elapsed": isRecording ? elapsed : -1,
            "start_time": sessionStart.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "chapters": chaptersJSON,
            "notes": notesJSON,
            "highlights": highlightsJSON,
            "event_count": chaptersJSON.count + notesJSON.count + highlightsJSON.count
        ])
    }

    func handleValidate(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /validate request", category: .server)

        let sourceStr = body["source"] as? String ?? "last"
        let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
        guard let src = sourceURL, FileManager.default.fileExists(atPath: src.path) else {
            sendResponse(connection: connection, status: 404, body: [
                "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                "code": "NO_VIDEO"
            ])
            return
        }

        guard let checks = body["checks"] as? [[String: Any]], !checks.isEmpty else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "'checks' must be a non-empty array",
                "example": "{\"source\":\"last\",\"checks\":[{\"type\":\"duration\",\"min\":10,\"max\":30}]}"
            ])
            return
        }

        let asset = AVURLAsset(url: src)
        var checkResults: [[String: Any]] = []
        var issues: [String] = []

        var videoDuration: Double = 0
        do {
            let dur = try await asset.load(.duration)
            videoDuration = CMTimeGetSeconds(dur)
        } catch {
            sendResponse(connection: connection, status: 500, body: [
                "error": "Could not load video: \(error.localizedDescription)"
            ])
            return
        }

        for check in checks {
            guard let checkType = check["type"] as? String else { continue }

            switch checkType {
            case "duration":
                let minDur = (check["min"] as? Double) ?? (check["min"] as? Int).map(Double.init) ?? 0
                let maxDur = (check["max"] as? Double) ?? (check["max"] as? Int).map(Double.init) ?? Double.infinity
                let pass = videoDuration >= minDur && videoDuration <= maxDur
                checkResults.append([
                    "name": "duration",
                    "pass": pass,
                    "value": (videoDuration * 10).rounded() / 10
                ])
                if !pass {
                    issues.append("Duration \(String(format: "%.1f", videoDuration))s outside range [\(minDur), \(maxDur)]")
                }

            case "frame_count":
                let minFrames = (check["min"] as? Int) ?? 0
                var frameCount = 0
                if let track = asset.tracks(withMediaType: .video).first {
                    let fps = track.nominalFrameRate
                    frameCount = Int(Double(fps) * videoDuration)
                }
                let pass = frameCount >= minFrames
                checkResults.append([
                    "name": "frame_count",
                    "pass": pass,
                    "value": frameCount
                ])
                if !pass {
                    issues.append("Frame count \(frameCount) < min \(minFrames)")
                }

            case "no_black_frames":
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

                let sampleCount = min(10, max(1, Int(videoDuration)))
                var hasBlack = false
                for i in 0..<sampleCount {
                    let t = videoDuration * Double(i) / Double(sampleCount)
                    let time = CMTime(seconds: t, preferredTimescale: 600)
                    do {
                        let (cgImage, _) = try await generator.image(at: time)
                        let brightness = averageBrightness(of: cgImage)
                        if brightness < 0.05 {
                            hasBlack = true
                            break
                        }
                    } catch {
                        continue
                    }
                }
                let pass = !hasBlack
                checkResults.append(["name": "no_black_frames", "pass": pass])
                if !pass {
                    issues.append("Black frame detected")
                }

            case "text_at":
                let time = (check["time"] as? Double) ?? (check["time"] as? Int).map(Double.init) ?? 0
                let expected = check["expected"] as? String ?? ""
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

                let checkName = "text_at_\(String(format: "%.1f", time))s"
                do {
                    let cmTime = CMTime(seconds: time, preferredTimescale: 600)
                    let (cgImage, _) = try await generator.image(at: cmTime)
                    let ocr = ScreenOCR()
                    let ocrResult = try await ocr.recognizeImage(cgImage: cgImage, source: "frame@\(time)s")
                    let found = ocrResult.fullText.localizedCaseInsensitiveContains(expected)
                    checkResults.append([
                        "name": checkName,
                        "pass": found,
                        "found": String(ocrResult.fullText.prefix(200))
                    ])
                    if !found {
                        issues.append("Expected text '\(expected)' not found at \(time)s")
                    }
                } catch {
                    checkResults.append([
                        "name": checkName,
                        "pass": false,
                        "error": error.localizedDescription
                    ])
                    issues.append("text_at check failed: \(error.localizedDescription)")
                }

            default:
                issues.append("Unknown check type: '\(checkType)' — skipped")
            }
        }

        let passCount = checkResults.filter { $0["pass"] as? Bool == true }.count
        let score = checkResults.isEmpty ? 0 : Int((Double(passCount) / Double(checkResults.count)) * 100)
        let valid = score >= 70

        sendResponse(connection: connection, status: 200, body: [
            "valid": valid,
            "score": score,
            "checks": checkResults,
            "issues": issues
        ])
    }

    func handleAnnotate(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /annotate request", category: .server)

        let sourceStr = body["source"] as? String ?? "last"
        let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
        guard let src = sourceURL else {
            sendResponse(connection: connection, status: 404, body: [
                "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                "code": "NO_VIDEO"
            ])
            return
        }
        guard let overlayDicts = body["overlays"] as? [[String: Any]], !overlayDicts.isEmpty else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "'overlays' must be a non-empty array",
                "example": "{\"overlays\":[{\"text\":\"Step 1\",\"start\":2,\"end\":8,\"position\":\"bottom\"}]}"
            ])
            return
        }

        let quality = RecordingConfig.Quality(rawValue: body["quality"] as? String ?? "medium") ?? .medium
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let outputURL = exportsDir.appendingPathComponent("ScreenMuse_\(ts).annotated.mp4")

        do {
            let annotator = VideoAnnotator()
            let result = try await annotator.annotate(
                sourceURL: src,
                overlays: overlayDicts,
                outputURL: outputURL,
                quality: quality
            )
            currentVideoURL = outputURL
            sendResponse(connection: connection, status: 200, body: [
                "path": result.outputURL.path,
                "overlay_count": result.overlayCount,
                "duration": result.duration,
                "size_mb": result.fileSizeMB
            ])
        } catch {
            smLog.error("[\(reqID)] /annotate failed: \(error.localizedDescription)", category: .server)
            let status = error.localizedDescription.contains("required") ? 400 : 500
            sendResponse(connection: connection, status: status, body: ["error": error.localizedDescription])
        }
    }

    func handleScript(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /script request", category: .server)

        guard let commands = body["commands"] as? [[String: Any]], !commands.isEmpty else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "'commands' must be a non-empty array",
                "example": "{\"commands\":[{\"action\":\"start\"},{\"sleep\":5},{\"action\":\"chapter\",\"name\":\"Step 1\"},{\"action\":\"stop\"}]}"
            ])
            return
        }

        var scriptResults: [[String: Any]] = []
        var scriptError: String? = nil

        for (idx, cmd) in commands.enumerated() {
            let action = cmd["action"] as? String ?? ""

            if let sleepSeconds = cmd["sleep"] as? Double ?? (cmd["sleep"] as? Int).map(Double.init) {
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                scriptResults.append(["step": idx + 1, "action": "sleep", "seconds": sleepSeconds, "ok": true])
                continue
            }

            var stepResult: [String: Any] = ["step": idx + 1, "action": action]
            do {
                switch action {
                case "start":
                    let name = cmd["name"] as? String ?? "script-recording"
                    let quality = cmd["quality"] as? String
                    if let coord = coordinator {
                        try await coord.startRecording(name: name, windowTitle: cmd["window_title"] as? String, windowPid: nil, quality: quality)
                    } else {
                        try await recordingManager.startRecording(config: RecordingConfig(
                            captureSource: .fullScreen,
                            includeSystemAudio: true,
                            quality: RecordingConfig.Quality(rawValue: quality ?? "medium") ?? .medium
                        ))
                    }
                    sessionID = UUID().uuidString
                    sessionName = name
                    startTime = Date()
                    isRecording = true
                    stepResult["ok"] = true

                case "stop":
                    let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                    if let coord = coordinator, let url = await coord.stopAndGetVideo() {
                        currentVideoURL = url
                        stepResult["video_path"] = url.path
                    } else {
                        let url = try await recordingManager.stopRecording()
                        currentVideoURL = url
                        stepResult["video_path"] = url.path
                    }
                    isRecording = false
                    stepResult["elapsed"] = elapsed
                    stepResult["ok"] = true

                case "pause":
                    if let coord = coordinator {
                        try await coord.pauseRecording()
                    } else {
                        try await recordingManager.pauseRecording()
                    }
                    stepResult["ok"] = true

                case "resume":
                    if let coord = coordinator {
                        try await coord.resumeRecording()
                    } else {
                        try await recordingManager.resumeRecording()
                    }
                    stepResult["ok"] = true

                case "chapter":
                    let chapterName = cmd["name"] as? String ?? "Chapter \(chapters.count + 1)"
                    let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                    chapters.append((name: chapterName, time: elapsed))
                    smLog.usage("CHAPTER \(chapterName)  t=\(String(format:"%.1f",elapsed))s")
                    stepResult["name"] = chapterName
                    stepResult["timestamp"] = elapsed
                    stepResult["ok"] = true

                case "note":
                    let noteText = cmd["text"] as? String ?? ""
                    let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                    sessionNotes.append((text: noteText, time: elapsed))
                    smLog.usage("📝 NOTE", details: ["text": noteText])
                    stepResult["ok"] = true

                case "highlight":
                    highlightNextClick = true
                    stepResult["ok"] = true

                default:
                    stepResult["ok"] = false
                    stepResult["error"] = "Unknown action '\(action)'. Supported: start, stop, pause, resume, chapter, note, highlight, sleep"
                }
            } catch {
                stepResult["ok"] = false
                stepResult["error"] = error.localizedDescription
                scriptError = "Step \(idx + 1) (\(action)) failed: \(error.localizedDescription)"
                scriptResults.append(stepResult)
                break
            }
            scriptResults.append(stepResult)
        }

        sendResponse(connection: connection, status: scriptError == nil ? 200 : 500, body: [
            "ok": scriptError == nil,
            "steps_run": scriptResults.count,
            "steps": scriptResults,
            "error": scriptError as Any
        ])
    }

    // MARK: POST /script/batch — run multiple named scripts in sequence

    func handleScriptBatch(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /script/batch request", category: .server)

        guard let scripts = body["scripts"] as? [[String: Any]], !scripts.isEmpty else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "'scripts' must be a non-empty array of objects, each with a 'commands' array",
                "example": "{\"scripts\":[{\"name\":\"setup\",\"commands\":[{\"action\":\"start\"}]},{\"name\":\"teardown\",\"commands\":[{\"action\":\"stop\"}]}]}"
            ])
            return
        }

        let continueOnError = body["continue_on_error"] as? Bool ?? false
        var scriptResults: [[String: Any]] = []
        var batchOK = true

        for (sIdx, scriptObj) in scripts.enumerated() {
            let scriptName = scriptObj["name"] as? String ?? "script_\(sIdx + 1)"
            guard let commands = scriptObj["commands"] as? [[String: Any]], !commands.isEmpty else {
                let result: [String: Any] = [
                    "name": scriptName,
                    "ok": false,
                    "steps_run": 0,
                    "steps": [] as [[String: Any]],
                    "error": "Script '\(scriptName)' missing or empty 'commands' array"
                ]
                scriptResults.append(result)
                batchOK = false
                if !continueOnError { break }
                continue
            }

            // Execute each command in this script (same logic as handleScript)
            var stepResults: [[String: Any]] = []
            var scriptError: String? = nil

            for (idx, cmd) in commands.enumerated() {
                let action = cmd["action"] as? String ?? ""

                if let sleepSeconds = cmd["sleep"] as? Double ?? (cmd["sleep"] as? Int).map(Double.init) {
                    try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                    stepResults.append(["step": idx + 1, "action": "sleep", "seconds": sleepSeconds, "ok": true])
                    continue
                }

                var stepResult: [String: Any] = ["step": idx + 1, "action": action]
                do {
                    switch action {
                    case "start":
                        let name = cmd["name"] as? String ?? "script-recording"
                        let quality = cmd["quality"] as? String
                        if let coord = coordinator {
                            try await coord.startRecording(name: name, windowTitle: cmd["window_title"] as? String, windowPid: nil, quality: quality)
                        } else {
                            try await recordingManager.startRecording(config: RecordingConfig(
                                captureSource: .fullScreen,
                                includeSystemAudio: true,
                                quality: RecordingConfig.Quality(rawValue: quality ?? "medium") ?? .medium
                            ))
                        }
                        sessionID = UUID().uuidString
                        sessionName = name
                        startTime = Date()
                        isRecording = true
                        stepResult["ok"] = true

                    case "stop":
                        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                        if let coord = coordinator, let url = await coord.stopAndGetVideo() {
                            currentVideoURL = url
                            stepResult["video_path"] = url.path
                        } else {
                            let url = try await recordingManager.stopRecording()
                            currentVideoURL = url
                            stepResult["video_path"] = url.path
                        }
                        isRecording = false
                        stepResult["elapsed"] = elapsed
                        stepResult["ok"] = true

                    case "pause":
                        if let coord = coordinator {
                            try await coord.pauseRecording()
                        } else {
                            try await recordingManager.pauseRecording()
                        }
                        stepResult["ok"] = true

                    case "resume":
                        if let coord = coordinator {
                            try await coord.resumeRecording()
                        } else {
                            try await recordingManager.resumeRecording()
                        }
                        stepResult["ok"] = true

                    case "chapter":
                        let chapterName = cmd["name"] as? String ?? "Chapter \(chapters.count + 1)"
                        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                        chapters.append((name: chapterName, time: elapsed))
                        stepResult["name"] = chapterName
                        stepResult["timestamp"] = elapsed
                        stepResult["ok"] = true

                    case "note":
                        let noteText = cmd["text"] as? String ?? ""
                        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                        sessionNotes.append((text: noteText, time: elapsed))
                        stepResult["ok"] = true

                    case "highlight":
                        highlightNextClick = true
                        stepResult["ok"] = true

                    default:
                        stepResult["ok"] = false
                        stepResult["error"] = "Unknown action '\(action)'. Supported: start, stop, pause, resume, chapter, note, highlight, sleep"
                    }
                } catch {
                    stepResult["ok"] = false
                    stepResult["error"] = error.localizedDescription
                    scriptError = "Step \(idx + 1) (\(action)) failed: \(error.localizedDescription)"
                    stepResults.append(stepResult)
                    break
                }
                stepResults.append(stepResult)
            }

            let scriptOK = scriptError == nil
            scriptResults.append([
                "name": scriptName,
                "ok": scriptOK,
                "steps_run": stepResults.count,
                "steps": stepResults,
                "error": scriptError as Any
            ])

            if !scriptOK {
                batchOK = false
                if !continueOnError { break }
            }
        }

        sendResponse(connection: connection, status: batchOK ? 200 : 500, body: [
            "ok": batchOK,
            "scripts_run": scriptResults.count,
            "scripts": scriptResults
        ])
    }

    func handleUploadICloud(body: [String: Any], connection: NWConnection, reqID: Int) {
        smLog.info("[\(reqID)] /upload/icloud request", category: .server)

        let sourceStr = body["source"] as? String ?? "last"
        let sourceURL: URL?
        if sourceStr == "last" {
            sourceURL = currentVideoURL
        } else {
            sourceURL = URL(fileURLWithPath: sourceStr)
        }
        guard let resolvedSource = sourceURL,
              FileManager.default.fileExists(atPath: resolvedSource.path) else {
            sendResponse(connection: connection, status: 404, body: [
                "error": "No video available. Record something first, or pass 'source' with a file path.",
                "code": "NO_VIDEO"
            ])
            return
        }

        let filename = body["filename"] as? String
        let overwrite = body["overwrite"] as? Bool ?? false

        smLog.info("[\(reqID)] /upload/icloud source=\(resolvedSource.lastPathComponent) overwrite=\(overwrite)", category: .server)

        do {
            let uploader = iCloudUploader()
            let result = try uploader.upload(sourceURL: resolvedSource, filename: filename, overwrite: overwrite)
            sendResponse(connection: connection, status: 200, body: result.asDictionary())
        } catch let err as iCloudUploader.UploadError {
            let code: String
            let status: Int
            switch err {
            case .sourceNotFound: code = "SOURCE_NOT_FOUND"; status = 404
            case .iCloudDriveNotAvailable: code = "ICLOUD_NOT_AVAILABLE"; status = 503
            case .copyFailed: code = "COPY_FAILED"; status = 500
            }
            smLog.error("[\(reqID)] /upload/icloud failed [\(code)]: \(err.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: status, body: [
                "error": err.errorDescription ?? err.localizedDescription,
                "code": code
            ])
        } catch {
            smLog.error("[\(reqID)] /upload/icloud error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }
}
