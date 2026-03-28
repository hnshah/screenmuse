import AVFoundation
import Foundation
import Network

// MARK: - Job Handlers (GET /job/:id, GET /jobs)

extension ScreenMuseServer {

    func handleJob(jobID: String, connection: NWConnection, reqID: Int) async {
        smLog.debug("[\(reqID)] /job/\(jobID) requested", category: .server)
        guard let job = await JobQueue.shared.get(jobID) else {
            sendResponse(connection: connection, status: 404, body: [
                "error": "Job not found",
                "code": "JOB_NOT_FOUND",
                "job_id": jobID
            ])
            return
        }
        let status: Int
        switch job.status {
        case .pending, .running: status = 202
        case .completed, .failed: status = 200
        }
        sendResponse(connection: connection, status: status, body: job.asDictionary())
    }

    func handleJobs(connection: NWConnection, reqID: Int) async {
        smLog.debug("[\(reqID)] /jobs list requested", category: .server)
        let jobs = await JobQueue.shared.list()
        sendResponse(connection: connection, status: 200, body: [
            "jobs": jobs.map { $0.asDictionary() },
            "count": jobs.count
        ])
    }
}

// MARK: - System Handlers (/status, /health, /debug, /logs, /report, /version, /recordings, DELETE /recording, /openapi, /system/*)

extension ScreenMuseServer {

    func handleHealth(body: [String: Any], connection: NWConnection, reqID: Int) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        sendResponse(connection: connection, status: 200, body: ["ok": true, "version": version])
    }

    func handleStatus(body: [String: Any], connection: NWConnection, reqID: Int) {
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        smLog.debug("[\(reqID)] /status — recording=\(isRecording) elapsed=\(String(format: "%.1f", elapsed))s", category: .server)
        sendResponse(connection: connection, status: 200, body: [
            "recording": isRecording,
            "elapsed": elapsed,
            "session_id": sessionID ?? "",
            "chapters": chapters.map { ["name": $0.name, "time": $0.time] },
            "last_video": currentVideoURL?.path ?? ""
        ])
    }

    func handleDebug(body: [String: Any], connection: NWConnection, reqID: Int) {
        smLog.debug("[\(reqID)] /debug requested", category: .server)
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse")
        var recentFiles: [String] = []
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: screenMuseDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) {
            recentFiles = contents
                .filter { $0.pathExtension == "mp4" }
                .sorted { ($0.path) > ($1.path) }
                .prefix(5)
                .map { $0.path }
        }
        sendResponse(connection: connection, status: 200, body: [
            "save_directory": screenMuseDir.path,
            "directory_exists": FileManager.default.fileExists(atPath: screenMuseDir.path),
            "recent_recordings": recentFiles,
            "last_video": currentVideoURL?.path ?? "",
            "server_recording": isRecording,
            "request_count": requestCount,
            "log_file": smLog.logFilePath,
            "log_buffer_count": smLog.bufferCount
        ])
    }

    func handleLogs(body: [String: Any], connection: NWConnection, reqID: Int) {
        let limit = body["limit"] as? Int ?? 200
        let minLevel = ScreenMuseLogger.Level(rawValue: body["level"] as? String ?? "debug") ?? .debug
        let filterCategory = (body["category"] as? String).flatMap { ScreenMuseLogger.Category(rawValue: $0) }

        smLog.debug("[\(reqID)] /logs limit=\(limit) minLevel=\(minLevel.rawValue) category=\(filterCategory?.rawValue ?? "all")", category: .server)

        let entries = smLog.recentEntries(limit: limit, category: filterCategory, minLevel: minLevel)
        sendResponse(connection: connection, status: 200, body: [
            "count": entries.count,
            "log_file": smLog.logFilePath,
            "entries": entries
        ])
    }

    func handleReport(body: [String: Any], connection: NWConnection, reqID: Int) {
        smLog.debug("[\(reqID)] /report requested", category: .server)
        let usageEvents = smLog.recentUsageEvents(limit: 100)
        let errors = smLog.recentEntries(limit: 50, minLevel: .warning)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var reportLines: [String] = [
            "═══════════════════════════════════════════════",
            "  ScreenMuse Session Report",
            "  Generated: \(df.string(from: Date()))",
            "═══════════════════════════════════════════════",
            "",
            "── Usage Timeline ──────────────────────────────"
        ]
        if usageEvents.isEmpty {
            reportLines.append("  (no usage events yet)")
        } else {
            for event in usageEvents {
                reportLines.append("  " + event.formatted())
            }
        }
        reportLines += [
            "",
            "── Warnings & Errors ───────────────────────────"
        ]
        let warnErrors = errors.filter { $0["level"] == "warning" || $0["level"] == "error" }
        if warnErrors.isEmpty {
            reportLines.append("  ✅ No warnings or errors")
        } else {
            for e in warnErrors {
                let ts = String((e["timestamp"] ?? "").dropFirst(11).prefix(8))
                let lvl = (e["level"] ?? "").uppercased()
                let msg = e["message"] ?? ""
                reportLines.append("  [\(ts)] \(lvl)  \(msg)")
            }
        }
        reportLines += [
            "",
            "── System Info ─────────────────────────────────",
            "  Log file:   \(smLog.logFilePath)",
            "  Usage log:  \(smLog.usageLogFilePath)",
            "  Recording:  \(isRecording ? "▶ ACTIVE (session: \(sessionID ?? "?"))" : "⏹ idle")",
            "  Last video: \(currentVideoURL?.path ?? "(none)")",
            "═══════════════════════════════════════════════"
        ]

        let reportText = reportLines.joined(separator: "\n")

        sendResponse(connection: connection, status: 200, body: [
            "report": reportText,
            "usage_events": usageEvents.map { $0.asDictionary() },
            "warnings_and_errors": warnErrors,
            "log_file": smLog.logFilePath,
            "usage_log_file": smLog.usageLogFilePath
        ])
    }

    func handleVersion(body: [String: Any], connection: NWConnection, reqID: Int) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        smLog.debug("[\(reqID)] /version requested", category: .server)
        let endpoints: [String] = [
            // Recording
            "POST /start", "POST /stop", "POST /pause", "POST /resume",
            "POST /chapter", "POST /highlight", "POST /screenshot", "POST /note",
            // Export
            "POST /export", "POST /trim", "POST /speedramp",
            // Frame capture
            "POST /frame",
            // Cloud
            "POST /upload/icloud",
            // Multi-window
            "POST /start/pip",
            // Recording management
            "GET /recordings", "DELETE /recording",
            // Window management
            "POST /window/focus", "POST /window/position", "POST /window/hide-others",
            // System state
            "GET /system/clipboard", "GET /system/active-window", "GET /system/running-apps",
            // Info / debug
            "GET /status", "GET /health", "GET /windows", "GET /debug", "GET /logs", "GET /report", "GET /version",
            // Live stream
            "GET /stream", "GET /stream/status",
            // Session timeline + concat
            "GET /timeline", "POST /concat",
            // Visual analysis
            "POST /thumbnail", "POST /ocr", "POST /crop",
            // Validation & frames
            "POST /validate", "POST /frames",
            // Video editing
            "POST /annotate",
            // Batch runner
            "POST /script", "POST /script/batch",
            // OpenAPI spec
            "GET /openapi",
            // Async job queue
            "GET /job/:id", "GET /jobs"
        ]
        sendResponse(connection: connection, status: 200, body: [
            "version": version,
            "build": build,
            "min_macos": "14.0 (Sonoma)",
            "endpoint_count": endpoints.count,
            "api_endpoints": endpoints
        ])
    }

    func handleRecordings(body: [String: Any], connection: NWConnection, reqID: Int) {
        smLog.debug("[\(reqID)] /recordings list", category: .server)
        let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse", isDirectory: true)
        let exportsDir = screenMuseDir.appendingPathComponent("Exports", isDirectory: true)

        var recordings: [[String: Any]] = []
        let fm = FileManager.default

        let scanDirs = [screenMuseDir, exportsDir].filter { fm.fileExists(atPath: $0.path) }
        for dir in scanDirs {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let ext = url.pathExtension.lowercased()
                guard ["mp4", "mov", "gif", "webp"].contains(ext) else { continue }
                let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                let fileSize = attrs?.fileSize ?? 0
                let sizeMB = (Double(fileSize) / 1_048_576 * 100).rounded() / 100
                var rec: [String: Any] = [
                    "path": url.path,
                    "filename": url.lastPathComponent,
                    "format": ext,
                    "size": fileSize,
                    "size_mb": sizeMB,
                    "folder": dir.lastPathComponent == "ScreenMuse" ? "recordings" : dir.lastPathComponent.lowercased()
                ]
                if let created = attrs?.creationDate {
                    rec["created_at"] = ISO8601DateFormatter().string(from: created)
                }
                if let last = currentVideoURL, last.path == url.path {
                    rec["is_last"] = true
                }
                recordings.append(rec)
            }
        }

        smLog.debug("[\(reqID)] /recordings found \(recordings.count) files", category: .server)
        sendResponse(connection: connection, status: 200, body: [
            "recordings": recordings,
            "count": recordings.count,
            "directory": screenMuseDir.path
        ])
    }

    func handleDeleteRecording(body: [String: Any], connection: NWConnection, reqID: Int) {
        let pathStr = body["path"] as? String
        let filenameStr = body["filename"] as? String

        guard pathStr != nil || filenameStr != nil else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "Provide 'path' or 'filename'",
                "example_path": "{\"path\": \"/Users/you/Movies/ScreenMuse/recording.mp4\"}",
                "example_filename": "{\"filename\": \"ScreenMuse_2026-03-24.mp4\"}"
            ])
            return
        }

        let fm = FileManager.default
        let targetURL: URL?
        if let p = pathStr {
            targetURL = URL(fileURLWithPath: p)
        } else if let name = filenameStr {
            let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            let screenMuseDir = moviesURL.appendingPathComponent("ScreenMuse", isDirectory: true)
            let candidates = [
                screenMuseDir.appendingPathComponent(name),
                screenMuseDir.appendingPathComponent("Exports/\(name)")
            ]
            targetURL = candidates.first { fm.fileExists(atPath: $0.path) }
        } else {
            targetURL = nil
        }

        guard let url = targetURL, fm.fileExists(atPath: url.path) else {
            smLog.warning("[\(reqID)] /recording DELETE — file not found", category: .server)
            sendResponse(connection: connection, status: 404, body: [
                "error": "Recording not found",
                "code": "NOT_FOUND",
                "tip": "Use GET /recordings to list available files"
            ])
            return
        }

        if let last = currentVideoURL, last.path == url.path {
            sendResponse(connection: connection, status: 409, body: [
                "error": "Cannot delete the currently loaded recording. Stop and start a new session first.",
                "code": "IN_USE"
            ])
            return
        }

        smLog.info("[\(reqID)] Deleting recording: \(url.lastPathComponent)", category: .server)
        do {
            try fm.removeItem(at: url)
            smLog.usage("DELETE RECORDING", details: ["file": url.lastPathComponent])
            sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "deleted": url.lastPathComponent,
                "path": url.path
            ])
        } catch {
            smLog.error("[\(reqID)] Delete failed: \(error.localizedDescription)", category: .server)
            sendResponse(connection: connection, status: 500, body: ["error": error.localizedDescription])
        }
    }

    func handleOpenAPI(body: [String: Any], connection: NWConnection, reqID: Int) {
        smLog.debug("[\(reqID)] /openapi spec requested", category: .server)
        guard let specData = OpenAPISpec.json.data(using: .utf8) else {
            sendResponse(connection: connection, status: 500, body: ["error": "spec encoding failed"])
            return
        }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(specData.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(OpenAPISpec.json)"
        if let responseData = response.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed { @Sendable _ in connection.cancel() })
        }
    }

    func handleSystemClipboard(body: [String: Any], connection: NWConnection, reqID: Int) {
        smLog.debug("[\(reqID)] /system/clipboard", category: .server)
        let contents = SystemState.clipboardContents()
        sendResponse(connection: connection, status: 200, body: contents)
    }

    func handleSystemActiveWindow(body: [String: Any], connection: NWConnection, reqID: Int) {
        smLog.debug("[\(reqID)] /system/active-window", category: .server)
        let info = SystemState.activeWindow()
        sendResponse(connection: connection, status: 200, body: info)
    }

    func handleSystemRunningApps(body: [String: Any], connection: NWConnection, reqID: Int) {
        smLog.debug("[\(reqID)] /system/running-apps", category: .server)
        let apps = SystemState.runningApps()
        sendResponse(connection: connection, status: 200, body: ["apps": apps, "count": apps.count])
    }
}
