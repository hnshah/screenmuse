import AVFoundation
import AppKit
import Foundation
import Network
import ScreenCaptureKit
import Vision

// MARK: - Export Handlers (/export, /trim, /speedramp, /concat, /frames, /frame, /thumbnail, /crop, /ocr)

extension ScreenMuseServer {

    func handleExport(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /export request", category: .server)

        let formatStr = body["format"] as? String ?? "gif"
        guard let format = GIFExporter.Config.Format(rawValue: formatStr.lowercased()) else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "Unsupported format '\(formatStr)'",
                "code": "UNSUPPORTED_FORMAT",
                "supported": ["gif", "webp"]
            ])
            return
        }

        let sourceStr = body["source"] as? String ?? "last"
        let sourceURL: URL?
        if sourceStr == "last" {
            sourceURL = currentVideoURL
        } else {
            sourceURL = URL(fileURLWithPath: sourceStr)
        }
        guard let resolvedSource = sourceURL,
              FileManager.default.fileExists(atPath: resolvedSource.path) else {
            smLog.warning("[\(reqID)] /export no video source (source='\(sourceStr)')", category: .server)
            sendResponse(connection: connection, status: 404, body: [
                "error": "No video available. Record something first, or pass 'source' with a file path.",
                "code": "NO_VIDEO"
            ])
            return
        }

        var config = GIFExporter.Config()
        config.format = format
        if let fps = body["fps"] as? Double { config.fps = fps }
        else if let fps = body["fps"] as? Int { config.fps = Double(fps) }
        if let scale = body["scale"] as? Int { config.scale = scale }
        else if let scale = body["scale"] as? Double { config.scale = Int(scale) }
        if let q = body["quality"] as? String,
           let quality = GIFExporter.Config.Quality(rawValue: q.lowercased()) {
            config.quality = quality
        }
        if let start = body["start"] as? Double,
           let end = body["end"] as? Double {
            config.timeRange = start...end
        } else if let start = body["start"] as? Double {
            config.timeRange = start...Double.infinity
        }

        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let outputURL: URL
        if let customOutput = body["output"] as? String {
            outputURL = URL(fileURLWithPath: customOutput)
        } else {
            outputURL = GIFExporter.defaultOutputURL(for: resolvedSource, format: format, exportsDir: exportsDir)
        }

        smLog.info("[\(reqID)] /export source=\(resolvedSource.lastPathComponent) format=\(format.rawValue) fps=\(config.fps) scale=\(config.scale) quality=\(config.quality.rawValue) → \(outputURL.lastPathComponent)", category: .server)

        do {
            let exporter = GIFExporter()
            let result = try await exporter.export(
                sourceURL: resolvedSource,
                outputURL: outputURL,
                config: config,
                progress: { pct in
                    smLog.debug("[\(reqID)] /export progress \(Int(pct * 100))%", category: .server)
                }
            )
            sendResponse(connection: connection, status: 200, body: result.asDictionary())
        } catch let err as GIFExporter.ExportError {
            smLog.error("[\(reqID)] /export failed: \(err.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: [
                "error": err.errorDescription ?? err.localizedDescription,
                "code": "EXPORT_FAILED"
            ])
        } catch {
            smLog.error("[\(reqID)] /export error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleTrim(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /trim request", category: .server)

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

        var trimConfig = VideoTrimmer.Config()
        if let start = body["start"] as? Double { trimConfig.start = start }
        else if let start = body["start"] as? Int { trimConfig.start = Double(start) }
        if let end = body["end"] as? Double { trimConfig.end = end }
        else if let end = body["end"] as? Int { trimConfig.end = Double(end) }
        if let reencode = body["reencode"] as? Bool { trimConfig.reencode = reencode }

        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let outputURL: URL
        if let customOut = body["output"] as? String {
            outputURL = URL(fileURLWithPath: customOut)
        } else {
            outputURL = VideoTrimmer.defaultOutputURL(for: resolvedSource, exportsDir: exportsDir)
        }

        smLog.info("[\(reqID)] /trim source=\(resolvedSource.lastPathComponent) start=\(trimConfig.start) end=\(trimConfig.end.map{String($0)} ?? "full") reencode=\(trimConfig.reencode) → \(outputURL.lastPathComponent)", category: .server)

        do {
            let trimmer = VideoTrimmer()
            let result = try await trimmer.trim(sourceURL: resolvedSource, outputURL: outputURL, config: trimConfig)
            sendResponse(connection: connection, status: 200, body: result.asDictionary())
        } catch let err as VideoTrimmer.TrimError {
            let code: String
            switch err {
            case .noVideoSource: code = "NO_VIDEO"
            case .invalidRange: code = "INVALID_RANGE"
            case .exportFailed: code = "EXPORT_FAILED"
            case .exportCancelled: code = "CANCELLED"
            }
            smLog.error("[\(reqID)] /trim failed [\(code)]: \(err.localizedDescription)", category: .server)
            let status = (code == "INVALID_RANGE" || code == "NO_VIDEO") ? 400 : 500
            sendResponse(connection: connection, status: status, body: [
                "error": err.errorDescription ?? err.localizedDescription,
                "code": code
            ])
        } catch {
            smLog.error("[\(reqID)] /trim error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleSpeedRamp(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /speedramp request", category: .server)

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

        var rampConfig = SpeedRamper.Config()
        if let v = body["idle_threshold_sec"] as? Double { rampConfig.idleThresholdSec = v }
        if let v = body["idle_speed"] as? Double { rampConfig.idleSpeed = max(1.0, v) }
        if let v = body["active_speed"] as? Double { rampConfig.activeSpeed = max(0.1, v) }

        // Pull real event data from the coordinator when available (Track 2 fix)
        let cursorEvents: [CursorEvent] = coordinator?.cursorEvents ?? []
        let keystrokeTimestamps: [Date] = coordinator?.keystrokeTimestamps ?? []
        let recordingStart = startTime

        let analyzer = ActivityAnalyzer()
        let asset = AVURLAsset(url: resolvedSource)
        let assetDuration: Double
        do {
            let dur = try await asset.load(.duration)
            assetDuration = CMTimeGetSeconds(dur)
        } catch {
            sendResponse(connection: connection, status: 500, body: [
                "error": "Could not load video duration: \(error.localizedDescription)",
                "code": "ASSET_LOAD_FAILED"
            ])
            return
        }

        let segments: [ActivityAnalyzer.Segment]
        let analysisMethod: String
        if !cursorEvents.isEmpty || !keystrokeTimestamps.isEmpty, let start = recordingStart {
            segments = analyzer.analyze(
                cursorEvents: cursorEvents,
                keystrokeTimestamps: keystrokeTimestamps,
                recordingStart: start,
                duration: assetDuration,
                idleThreshold: rampConfig.idleThresholdSec
            )
            analysisMethod = "cursor_keystroke"
            smLog.info("[\(reqID)] /speedramp using agent event data (\(cursorEvents.count) cursor, \(keystrokeTimestamps.count) keystrokes)", category: .server)
        } else {
            smLog.info("[\(reqID)] /speedramp no event data — falling back to audio analysis", category: .server)
            do {
                segments = try await analyzer.analyzeFromAudio(
                    asset: asset,
                    duration: assetDuration,
                    idleThreshold: rampConfig.idleThresholdSec
                )
            } catch {
                sendResponse(connection: connection, status: 500, body: [
                    "error": "Activity analysis failed: \(error.localizedDescription)",
                    "code": "ANALYSIS_FAILED"
                ])
                return
            }
            analysisMethod = "audio"
        }

        let moviesURL2 = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let exportsDir2 = moviesURL2.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir2, withIntermediateDirectories: true)
        let rampOutputURL: URL
        if let customOut = body["output"] as? String {
            rampOutputURL = URL(fileURLWithPath: customOut)
        } else {
            rampOutputURL = SpeedRamper.defaultOutputURL(for: resolvedSource, exportsDir: exportsDir2)
        }

        smLog.info("[\(reqID)] /speedramp segments=\(segments.count) idle=\(segments.filter{$0.isIdle}.count) → \(rampOutputURL.lastPathComponent)", category: .server)

        do {
            let ramper = SpeedRamper()
            let result = try await ramper.ramp(
                sourceURL: resolvedSource,
                outputURL: rampOutputURL,
                segments: segments,
                config: rampConfig
            )
            var responseBody = result.asDictionary()
            responseBody["analysis_method"] = analysisMethod
            sendResponse(connection: connection, status: 200, body: responseBody)
        } catch let err as SpeedRamper.SpeedRampError {
            smLog.error("[\(reqID)] /speedramp failed: \(err.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: [
                "error": err.errorDescription ?? err.localizedDescription,
                "code": "SPEEDRAMP_FAILED"
            ])
        } catch {
            smLog.error("[\(reqID)] /speedramp error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleConcat(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /concat request", category: .server)

        guard let rawSources = body["sources"] as? [String], !rawSources.isEmpty else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "'sources' must be a non-empty array of file paths",
                "example": "{\"sources\": [\"/path/1.mp4\", \"/path/2.mp4\"]}"
            ])
            return
        }

        var sourceURLs: [URL] = []
        for s in rawSources {
            if s == "last" {
                guard let last = currentVideoURL else {
                    sendResponse(connection: connection, status: 404, body: [
                        "error": "No recent recording available for 'last'",
                        "code": "NO_VIDEO"
                    ])
                    return
                }
                sourceURLs.append(last)
            } else {
                sourceURLs.append(URL(fileURLWithPath: s))
            }
        }

        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let outputURL: URL
        if let customOut = body["output"] as? String {
            outputURL = URL(fileURLWithPath: customOut)
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
            let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            outputURL = exportsDir.appendingPathComponent("ScreenMuse_\(ts).concat.mp4")
        }

        do {
            let concatenator = VideoConcatenator()
            let result = try await concatenator.concatenate(sources: sourceURLs, outputURL: outputURL)
            currentVideoURL = outputURL
            sendResponse(connection: connection, status: 200, body: [
                "path": result.outputURL.path,
                "duration": result.duration,
                "source_count": result.sourceCount,
                "size_mb": result.fileSizeMB
            ])
        } catch let err as VideoConcatenator.ConcatError {
            smLog.error("[\(reqID)] /concat failed: \(err.localizedDescription)", category: .server)
            let status = (err.localizedDescription.contains("not found")) ? 404 : 500
            sendResponse(connection: connection, status: status, body: [
                "error": err.errorDescription ?? err.localizedDescription,
                "code": "CONCAT_FAILED"
            ])
        } catch {
            smLog.error("[\(reqID)] /concat error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleFrames(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /frames request", category: .server)

        let sourceStr = body["source"] as? String ?? "last"
        let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
        guard let src = sourceURL, FileManager.default.fileExists(atPath: src.path) else {
            sendResponse(connection: connection, status: 404, body: [
                "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                "code": "NO_VIDEO"
            ])
            return
        }

        let rawTimestamps = body["timestamps"] as? [Any] ?? []
        let timestamps: [Double] = rawTimestamps.compactMap { val in
            if let d = val as? Double { return d }
            if let i = val as? Int { return Double(i) }
            return nil
        }
        guard !timestamps.isEmpty else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "'timestamps' must be a non-empty array of numbers",
                "example": "{\"source\":\"last\",\"timestamps\":[1.0,2.5,5.0],\"format\":\"png\"}"
            ])
            return
        }

        let formatStr = (body["format"] as? String ?? "png").lowercased()
        let usePNG = formatStr != "jpg" && formatStr != "jpeg"

        let framesDir = URL(fileURLWithPath: "/tmp/screenmuse-frames")
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: src)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var frames: [[String: Any]] = []
        for ts in timestamps {
            let cmTime = CMTime(seconds: ts, preferredTimescale: 600)
            let ext = usePNG ? "png" : "jpg"
            let filename = "frame-\(String(format: "%.1f", ts))s.\(ext)"
            let outputPath = framesDir.appendingPathComponent(filename)

            do {
                let (cgImage, _) = try await generator.image(at: cmTime)
                let rep = NSBitmapImageRep(cgImage: cgImage)
                let imageData: Data?
                if usePNG {
                    imageData = rep.representation(using: .png, properties: [:])
                } else {
                    imageData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
                }
                if let data = imageData {
                    try data.write(to: outputPath)
                    frames.append(["time": ts, "path": outputPath.path])
                } else {
                    frames.append(["time": ts, "error": "Image conversion failed"])
                }
            } catch {
                frames.append(["time": ts, "error": error.localizedDescription])
            }
        }

        sendResponse(connection: connection, status: 200, body: [
            "frames": frames,
            "count": frames.filter { $0["path"] != nil }.count
        ])
    }

    func handleFrame(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /frame requested", category: .capture)
        let frameIsRecording = isRecording
        let frameIsPaused = !isRecording && startTime != nil

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                sendResponse(connection: connection, status: 500, body: ["error": "No display found"])
                return
            }

            let formatStr = (body["format"] as? String ?? "png").lowercased()
            let useJPEG = formatStr == "jpeg" || formatStr == "jpg"
            let jpegQuality = body["quality"] as? Double ?? 0.85

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let ext = useJPEG ? "jpg" : "png"
            let savePath: URL
            if let customPath = body["path"] as? String {
                savePath = URL(fileURLWithPath: customPath)
            } else {
                let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
                let framesDir = moviesURL.appendingPathComponent("ScreenMuse/Frames", isDirectory: true)
                try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
                let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                savePath = framesDir.appendingPathComponent("frame-\(ts).\(ext)")
            }

            if #available(macOS 14.0, *) {
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let rep = NSBitmapImageRep(cgImage: cgImage)

                let imageData: Data?
                if useJPEG {
                    imageData = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
                } else {
                    imageData = rep.representation(using: .png, properties: [:])
                }

                guard let data = imageData else {
                    sendResponse(connection: connection, status: 500, body: ["error": "Image conversion failed"])
                    return
                }
                try data.write(to: savePath)

                var response: [String: Any] = [
                    "path": savePath.path,
                    "format": ext,
                    "width": cgImage.width,
                    "height": cgImage.height,
                    "size": data.count
                ]

                let frameElapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                if frameIsRecording || frameIsPaused {
                    response["recording"] = true
                    response["paused"] = frameIsPaused
                    response["recording_elapsed"] = frameElapsed
                    if let sid = sessionID { response["session_id"] = sid }
                    if let currentChapter = chapters.last(where: { $0.time <= frameElapsed }) {
                        response["current_chapter"] = currentChapter.name
                    }
                } else {
                    response["recording"] = false
                }

                smLog.info("[\(reqID)] ✅ /frame saved \(savePath.lastPathComponent) \(cgImage.width)×\(cgImage.height) recording=\(frameIsRecording)", category: .capture)
                smLog.usage("FRAME CAPTURE", details: ["file": savePath.lastPathComponent, "format": ext, "recording": "\(frameIsRecording)"])
                sendResponse(connection: connection, status: 200, body: response)
            } else {
                sendResponse(connection: connection, status: 400, body: ["error": "Frame capture requires macOS 14+"])
            }
        } catch {
            smLog.error("[\(reqID)] /frame failed: \(error.localizedDescription)", category: .capture)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleThumbnail(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /thumbnail request", category: .server)

        let sourceStr = body["source"] as? String ?? "last"
        let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
        guard let src = sourceURL else {
            sendResponse(connection: connection, status: 404, body: [
                "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                "code": "NO_VIDEO"
            ])
            return
        }

        let thumbTime = (body["time"] as? Double) ?? (body["time"] as? Int).map(Double.init)
        let scale = body["scale"] as? Int ?? 800
        let format = body["format"] as? String ?? "jpeg"
        let quality = Double(body["quality"] as? Int ?? 85) / 100.0

        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let thumbsDir = moviesURL.appendingPathComponent("ScreenMuse/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        let ext = (format == "png") ? "png" : "jpg"
        let outputURL = thumbsDir.appendingPathComponent("thumb_\(Int(Date().timeIntervalSince1970)).\(ext)")

        do {
            let extractor = ThumbnailExtractor()
            let result = try await extractor.extract(
                sourceURL: src,
                time: thumbTime,
                scale: scale,
                format: format,
                quality: quality,
                outputURL: outputURL
            )
            sendResponse(connection: connection, status: 200, body: [
                "path": result.outputURL.path,
                "time": result.actualTime,
                "width": result.width,
                "height": result.height,
                "size_bytes": result.fileSizeBytes,
                "format": format
            ])
        } catch {
            smLog.error("[\(reqID)] /thumbnail failed: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleCrop(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /crop request", category: .server)

        let sourceStr = body["source"] as? String ?? "last"
        let sourceURL: URL? = (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
        guard let src = sourceURL else {
            sendResponse(connection: connection, status: 404, body: [
                "error": "No video available. Record first or pass 'source': '/path/to/video.mp4'",
                "code": "NO_VIDEO"
            ])
            return
        }

        guard let regionDict = body["region"] as? [String: Any],
              let w = (regionDict["width"] as? Double) ?? (regionDict["width"] as? Int).map(Double.init),
              let h = (regionDict["height"] as? Double) ?? (regionDict["height"] as? Int).map(Double.init),
              w > 0, h > 0 else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "'region' is required: {x, y, width, height}",
                "example": "{\"source\":\"last\",\"region\":{\"x\":0,\"y\":0,\"width\":1280,\"height\":720}}"
            ])
            return
        }
        let rx = (regionDict["x"] as? Double) ?? (regionDict["x"] as? Int).map(Double.init) ?? 0
        let ry = (regionDict["y"] as? Double) ?? (regionDict["y"] as? Int).map(Double.init) ?? 0
        let cropRect = CGRect(x: rx, y: ry, width: w, height: h)
        let quality = RecordingConfig.Quality(rawValue: body["quality"] as? String ?? "medium") ?? .medium

        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let exportsDir = moviesURL.appendingPathComponent("ScreenMuse/Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let outputURL = exportsDir.appendingPathComponent("ScreenMuse_\(ts).cropped.mp4")

        do {
            let cropper = VideoCropper()
            let result = try await cropper.crop(sourceURL: src, region: cropRect, outputURL: outputURL, quality: quality)
            currentVideoURL = outputURL
            sendResponse(connection: connection, status: 200, body: [
                "path": result.outputURL.path,
                "crop_rect": ["x": result.cropRect.origin.x, "y": result.cropRect.origin.y,
                              "width": result.cropRect.width, "height": result.cropRect.height],
                "duration": result.duration,
                "size_mb": result.fileSizeMB
            ])
        } catch let err as VideoCropper.CropError {
            smLog.error("[\(reqID)] /crop failed: \(err.localizedDescription)", category: .server)
            let status = (err.localizedDescription.contains("not found")) ? 404 :
                         (err.localizedDescription.contains("required") || err.localizedDescription.contains("Invalid")) ? 400 : 500
            sendResponse(connection: connection, status: status, body: [
                "error": err.errorDescription ?? err.localizedDescription
            ])
        } catch {
            smLog.error("[\(reqID)] /crop error: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleOCR(body: [String: Any], connection: NWConnection, reqID: Int) async {
        smLog.info("[\(reqID)] /ocr request source=\(body["source"] as? String ?? "screen")", category: .server)

        let ocrSource = body["source"] as? String ?? "screen"
        let levelStr = body["level"] as? String ?? "accurate"
        let level: VNRequestTextRecognitionLevel = (levelStr == "fast") ? .fast : .accurate
        let langHint = body["lang"] as? String
        let languages: [String] = langHint.map { [$0] } ?? []
        let fullTextOnly = body["full_text_only"] as? Bool ?? false
        let debugMode = body["debug"] as? Bool ?? false

        do {
            let ocr = ScreenOCR()
            let result: ScreenOCR.OCRResult
            if ocrSource == "screen" || ocrSource == "display" {
                result = try await ocr.recognizeScreen(level: level, languages: languages)
            } else {
                result = try await ocr.recognizeFile(at: URL(fileURLWithPath: ocrSource), level: level, languages: languages)
            }

            var responseBody = debugMode ? result.asJSONWithDebug : result.asJSON
            if fullTextOnly {
                responseBody.removeValue(forKey: "blocks")
            }
            sendResponse(connection: connection, status: 200, body: responseBody)
        } catch {
            smLog.error("[\(reqID)] /ocr failed: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: [
                "error": error.localizedDescription,
                "tip": "Ensure Screen Recording permission is granted"
            ])
        }
    }
}
