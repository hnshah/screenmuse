import Foundation

// MARK: - JSON Helpers

/// Lightweight JSON value type for dynamic encoding/decoding without external dependencies.
enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    subscript(key: String) -> JSON? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }
}

extension JSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSON].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSON].self) {
            self = .object(obj)
        } else {
            self = .null
        }
    }
}

extension JSON: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let b):    try container.encode(b)
        case .int(let i):     try container.encode(i)
        case .double(let d):  try container.encode(d)
        case .string(let s):  try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }
}

/// Convert a JSON value to a Foundation object suitable for JSONSerialization.
private func jsonToAny(_ json: JSON) -> Any {
    switch json {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .array(let arr): return arr.map { jsonToAny($0) }
    case .object(let obj):
        var dict: [String: Any] = [:]
        for (k, v) in obj { dict[k] = jsonToAny(v) }
        return dict
    }
}

/// Convert a Foundation object from JSONSerialization back into a JSON value.
private func anyToJSON(_ value: Any) -> JSON {
    switch value {
    case is NSNull:
        return .null
    case let b as Bool:
        return .bool(b)
    case let n as NSNumber:
        // NSNumber can represent Int or Double; prefer Int if it round-trips
        if n.doubleValue == Double(n.intValue) {
            return .int(n.intValue)
        }
        return .double(n.doubleValue)
    case let s as String:
        return .string(s)
    case let arr as [Any]:
        return .array(arr.map { anyToJSON($0) })
    case let dict as [String: Any]:
        return .object(dict.mapValues { anyToJSON($0) })
    default:
        return .null
    }
}

// MARK: - MCP Request

struct MCPRequest: Decodable, Sendable {
    let jsonrpc: String?
    let id: JSON?
    let method: String?
    let params: JSON?
}

// MARK: - Tool Definitions

struct ToolDef: @unchecked Sendable {
    let name: String
    let description: String
    /// JSON-compatible dict for the input schema
    let inputSchema: [String: Any]

    /// HTTP method
    let httpMethod: String
    /// HTTP path
    let httpPath: String
    /// How to build the body from tool arguments
    let bodyBuilder: @Sendable (JSON?) -> Any?
}

/// Build the complete list of 33 tools, copying descriptions exactly from screenmuse-mcp.js.
private func buildTools() -> [ToolDef] {
    // Shorthand helpers for body builders
    let passArgs: @Sendable (JSON?) -> Any? = { args in
        guard let args else { return [:] as [String: Any] }
        return jsonToAny(args)
    }
    let emptyBody: @Sendable (JSON?) -> Any? = { _ in [:] as [String: Any] }
    let noBody: @Sendable (JSON?) -> Any? = { _ in nil }
    let emptySchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]

    return [
        // 1. screenmuse_start
        ToolDef(
            name: "screenmuse_start",
            description: "Start a screen recording. Optionally record a specific window, region, or quality level. Supports webhooks.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Recording name/label (default: auto-generated)"] as [String: Any],
                    "quality": ["type": "string", "enum": ["low", "medium", "high", "max"], "description": "Video quality (default: medium)"] as [String: Any],
                    "window_title": ["type": "string", "description": "Record a specific window (e.g. \"Google Chrome\")"] as [String: Any],
                    "region": [
                        "type": "object",
                        "description": "Record a specific screen region",
                        "properties": [
                            "x": ["type": "number"] as [String: Any],
                            "y": ["type": "number"] as [String: Any],
                            "width": ["type": "number"] as [String: Any],
                            "height": ["type": "number"] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any],
                    "audio_source": ["type": "string", "description": "\"system\" (default), \"none\", or app name for app-only audio"] as [String: Any],
                    "webhook": ["type": "string", "description": "URL to POST to when recording stops"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/start", bodyBuilder: passArgs
        ),
        // 2. screenmuse_stop
        ToolDef(
            name: "screenmuse_stop",
            description: "Stop the current recording. Returns the video file path.",
            inputSchema: emptySchema,
            httpMethod: "POST", httpPath: "/stop", bodyBuilder: emptyBody
        ),
        // 3. screenmuse_pause
        ToolDef(
            name: "screenmuse_pause",
            description: "Pause the current recording.",
            inputSchema: emptySchema,
            httpMethod: "POST", httpPath: "/pause", bodyBuilder: emptyBody
        ),
        // 4. screenmuse_resume
        ToolDef(
            name: "screenmuse_resume",
            description: "Resume a paused recording.",
            inputSchema: emptySchema,
            httpMethod: "POST", httpPath: "/resume", bodyBuilder: emptyBody
        ),
        // 5. screenmuse_chapter
        ToolDef(
            name: "screenmuse_chapter",
            description: "Add a named chapter marker at the current recording timestamp.",
            inputSchema: [
                "type": "object",
                "required": ["name"] as [Any],
                "properties": [
                    "name": ["type": "string", "description": "Chapter name (e.g. \"Step 3: Configure settings\")"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/chapter",
            bodyBuilder: { args in
                guard let name = args?["name"]?.stringValue else { return ["name": ""] as [String: Any] }
                return ["name": name] as [String: Any]
            }
        ),
        // 6. screenmuse_note
        ToolDef(
            name: "screenmuse_note",
            description: "Add a timestamped annotation to the recording log.",
            inputSchema: [
                "type": "object",
                "required": ["text"] as [Any],
                "properties": [
                    "text": ["type": "string", "description": "Note text"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/note",
            bodyBuilder: { args in
                guard let text = args?["text"]?.stringValue else { return ["text": ""] as [String: Any] }
                return ["text": text] as [String: Any]
            }
        ),
        // 7. screenmuse_screenshot
        ToolDef(
            name: "screenmuse_screenshot",
            description: "Capture a full-screen screenshot and return the file path.",
            inputSchema: emptySchema,
            httpMethod: "POST", httpPath: "/screenshot", bodyBuilder: emptyBody
        ),
        // 8. screenmuse_ocr
        ToolDef(
            name: "screenmuse_ocr",
            description: "Read text from the screen or an image file using Apple Vision (no API key needed, runs locally).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "\"screen\" (default) or absolute path to an image file"] as [String: Any],
                    "level": ["type": "string", "enum": ["accurate", "fast"], "description": "Recognition quality (default: accurate)"] as [String: Any],
                    "full_text_only": ["type": "boolean", "description": "Return only full_text, omit bounding boxes (default: false)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/ocr", bodyBuilder: passArgs
        ),
        // 9. screenmuse_export
        ToolDef(
            name: "screenmuse_export",
            description: "Export the last recording as an animated GIF or WebP.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "format": ["type": "string", "enum": ["gif", "webp"], "description": "Output format (default: gif)"] as [String: Any],
                    "fps": ["type": "integer", "description": "Frames per second (default: 10)"] as [String: Any],
                    "scale": ["type": "integer", "description": "Max width in pixels (default: 800)"] as [String: Any],
                    "start": ["type": "number", "description": "Start time in seconds"] as [String: Any],
                    "end": ["type": "number", "description": "End time in seconds"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/export", bodyBuilder: passArgs
        ),
        // 10. screenmuse_trim
        ToolDef(
            name: "screenmuse_trim",
            description: "Trim the last recording to a time range (stream copy — near instant, no re-encode).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "start": ["type": "number", "description": "Start time in seconds (default: 0)"] as [String: Any],
                    "end": ["type": "number", "description": "End time in seconds (default: end of video)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/trim", bodyBuilder: passArgs
        ),
        // 11. screenmuse_thumbnail
        ToolDef(
            name: "screenmuse_thumbnail",
            description: "Extract a still frame from a recording at a specific timestamp.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "time": ["type": "number", "description": "Timestamp in seconds (default: middle of video)"] as [String: Any],
                    "scale": ["type": "integer", "description": "Max width in pixels (default: 800)"] as [String: Any],
                    "format": ["type": "string", "enum": ["jpeg", "png"], "description": "Image format (default: jpeg)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/thumbnail", bodyBuilder: passArgs
        ),
        // 12. screenmuse_status
        ToolDef(
            name: "screenmuse_status",
            description: "Get the current recording status — whether recording is active, elapsed time, chapters.",
            inputSchema: emptySchema,
            httpMethod: "GET", httpPath: "/status", bodyBuilder: noBody
        ),
        // 13. screenmuse_timeline
        ToolDef(
            name: "screenmuse_timeline",
            description: "Get the structured timeline of the current/last session: chapters, notes, and highlights.",
            inputSchema: emptySchema,
            httpMethod: "GET", httpPath: "/timeline", bodyBuilder: noBody
        ),
        // 14. screenmuse_recordings
        ToolDef(
            name: "screenmuse_recordings",
            description: "List all recordings in ~/Movies/ScreenMuse/ with file metadata.",
            inputSchema: emptySchema,
            httpMethod: "GET", httpPath: "/recordings", bodyBuilder: noBody
        ),
        // 15. screenmuse_window_focus
        ToolDef(
            name: "screenmuse_window_focus",
            description: "Bring an application window to the front.",
            inputSchema: [
                "type": "object",
                "required": ["app"] as [Any],
                "properties": [
                    "app": ["type": "string", "description": "App name (e.g. \"Google Chrome\") or bundle ID"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/window/focus",
            bodyBuilder: { args in
                guard let app = args?["app"]?.stringValue else { return ["app": ""] as [String: Any] }
                return ["app": app] as [String: Any]
            }
        ),
        // 16. screenmuse_active_window
        ToolDef(
            name: "screenmuse_active_window",
            description: "Get information about the currently focused window (app name, title, position, size).",
            inputSchema: emptySchema,
            httpMethod: "GET", httpPath: "/system/active-window", bodyBuilder: noBody
        ),
        // 17. screenmuse_clipboard
        ToolDef(
            name: "screenmuse_clipboard",
            description: "Get the current clipboard contents.",
            inputSchema: emptySchema,
            httpMethod: "GET", httpPath: "/system/clipboard", bodyBuilder: noBody
        ),
        // 18. screenmuse_running_apps
        ToolDef(
            name: "screenmuse_running_apps",
            description: "List all running applications with their names and bundle IDs.",
            inputSchema: emptySchema,
            httpMethod: "GET", httpPath: "/system/running-apps", bodyBuilder: noBody
        ),
        // 19. screenmuse_record
        ToolDef(
            name: "screenmuse_record",
            description: "Start a recording, wait for the specified duration, then stop and return the video. One-shot convenience endpoint.",
            inputSchema: [
                "type": "object",
                "required": ["duration_seconds"] as [Any],
                "properties": [
                    "name": ["type": "string", "description": "Recording name/label (default: auto-generated)"] as [String: Any],
                    "duration_seconds": ["type": "number", "description": "Recording duration in seconds (1-3600)", "minimum": 1, "maximum": 3600] as [String: Any],
                    "quality": ["type": "string", "enum": ["low", "medium", "high", "max"], "description": "Video quality (default: medium)"] as [String: Any],
                    "window_title": ["type": "string", "description": "Record a specific window"] as [String: Any],
                    "webhook": ["type": "string", "description": "URL to POST to when recording stops"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/record", bodyBuilder: passArgs
        ),
        // 20. screenmuse_speedramp
        ToolDef(
            name: "screenmuse_speedramp",
            description: "Speed-ramp a video: speed up idle sections, keep active sections at normal speed. Uses cursor/keystroke activity analysis.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "Video path or \"last\" (default: last recording)"] as [String: Any],
                    "idle_threshold_sec": ["type": "number", "description": "Seconds of inactivity before section is considered idle (default: 2.0)"] as [String: Any],
                    "idle_speed": ["type": "number", "description": "Playback speed for idle sections (default: 4.0x, min 1.0)"] as [String: Any],
                    "active_speed": ["type": "number", "description": "Playback speed for active sections (default: 1.0x, min 0.1)"] as [String: Any],
                    "output": ["type": "string", "description": "Custom output path (default: auto-generated in Exports)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/speedramp", bodyBuilder: passArgs
        ),
        // 21. screenmuse_concat
        ToolDef(
            name: "screenmuse_concat",
            description: "Concatenate multiple video files into one.",
            inputSchema: [
                "type": "object",
                "required": ["sources"] as [Any],
                "properties": [
                    "sources": ["type": "array", "items": ["type": "string"] as [String: Any], "description": "Array of video file paths (use \"last\" for most recent recording)"] as [String: Any],
                    "output": ["type": "string", "description": "Custom output path (default: auto-generated in Exports)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/concat", bodyBuilder: passArgs
        ),
        // 22. screenmuse_crop
        ToolDef(
            name: "screenmuse_crop",
            description: "Crop a video to a specific region.",
            inputSchema: [
                "type": "object",
                "required": ["region"] as [Any],
                "properties": [
                    "source": ["type": "string", "description": "Video path or \"last\" (default: last recording)"] as [String: Any],
                    "region": [
                        "type": "object",
                        "required": ["x", "y", "width", "height"] as [Any],
                        "description": "Crop region in pixels",
                        "properties": [
                            "x": ["type": "number", "description": "Left offset"] as [String: Any],
                            "y": ["type": "number", "description": "Top offset"] as [String: Any],
                            "width": ["type": "number", "description": "Crop width"] as [String: Any],
                            "height": ["type": "number", "description": "Crop height"] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any],
                    "quality": ["type": "string", "enum": ["low", "medium", "high", "max"], "description": "Output quality (default: medium)"] as [String: Any],
                    "output": ["type": "string", "description": "Custom output path"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/crop", bodyBuilder: passArgs
        ),
        // 23. screenmuse_annotate
        ToolDef(
            name: "screenmuse_annotate",
            description: "Overlay text, shapes, or highlights on a video.",
            inputSchema: [
                "type": "object",
                "required": ["overlays"] as [Any],
                "properties": [
                    "source": ["type": "string", "description": "Video path or \"last\" (default: last recording)"] as [String: Any],
                    "overlays": [
                        "type": "array",
                        "description": "Array of overlay objects (text, shape, highlight)",
                        "items": ["type": "object"] as [String: Any]
                    ] as [String: Any],
                    "quality": ["type": "string", "enum": ["low", "medium", "high", "max"], "description": "Output quality (default: medium)"] as [String: Any],
                    "output": ["type": "string", "description": "Custom output path"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/annotate", bodyBuilder: passArgs
        ),
        // 24. screenmuse_script
        ToolDef(
            name: "screenmuse_script",
            description: "Run a sequence of recording commands (start, stop, chapter, sleep, etc.) as a batch script.",
            inputSchema: [
                "type": "object",
                "required": ["commands"] as [Any],
                "properties": [
                    "commands": [
                        "type": "array",
                        "description": "Array of command objects: {action: \"start\"|\"stop\"|\"chapter\"|...} or {sleep: seconds}",
                        "items": ["type": "object"] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/script", bodyBuilder: passArgs
        ),
        // 25. screenmuse_script_batch
        ToolDef(
            name: "screenmuse_script_batch",
            description: "Run multiple named scripts in sequence. Each script contains a commands array. Stops on first failure unless continue_on_error is true.",
            inputSchema: [
                "type": "object",
                "required": ["scripts"] as [Any],
                "properties": [
                    "scripts": [
                        "type": "array",
                        "description": "Array of script objects: {name: \"setup\", commands: [...]}",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "Script name"] as [String: Any],
                                "commands": ["type": "array", "items": ["type": "object"] as [String: Any], "description": "Array of command objects"] as [String: Any]
                            ] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any],
                    "continue_on_error": ["type": "boolean", "description": "Continue running remaining scripts if one fails (default: false)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/script/batch", bodyBuilder: passArgs
        ),
        // 26. screenmuse_highlight
        ToolDef(
            name: "screenmuse_highlight",
            description: "Flag the next mouse click to be highlighted with an enhanced visual effect (auto-zoom + ring).",
            inputSchema: emptySchema,
            httpMethod: "POST", httpPath: "/highlight", bodyBuilder: emptyBody
        ),
        // 27. screenmuse_windows
        ToolDef(
            name: "screenmuse_windows",
            description: "List all visible on-screen windows with title, app name, pid, and position. Use before recording to find a specific window.",
            inputSchema: emptySchema,
            httpMethod: "GET", httpPath: "/windows", bodyBuilder: noBody
        ),
        // 28. screenmuse_window_position
        ToolDef(
            name: "screenmuse_window_position",
            description: "Move and resize an application window.",
            inputSchema: [
                "type": "object",
                "required": ["app"] as [Any],
                "properties": [
                    "app": ["type": "string", "description": "Application name (e.g. \"Google Chrome\")"] as [String: Any],
                    "x": ["type": "number", "description": "New X position in screen coordinates"] as [String: Any],
                    "y": ["type": "number", "description": "New Y position in screen coordinates"] as [String: Any],
                    "width": ["type": "number", "description": "New window width"] as [String: Any],
                    "height": ["type": "number", "description": "New window height"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/window/position", bodyBuilder: passArgs
        ),
        // 29. screenmuse_hide_others
        ToolDef(
            name: "screenmuse_hide_others",
            description: "Hide all windows except the specified application. Useful for recording clean demos.",
            inputSchema: [
                "type": "object",
                "required": ["app"] as [Any],
                "properties": [
                    "app": ["type": "string", "description": "Application name to keep visible (all others will be hidden)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/window/hide-others", bodyBuilder: passArgs
        ),
        // 30. screenmuse_delete_recording
        ToolDef(
            name: "screenmuse_delete_recording",
            description: "Delete a specific recording file from disk.",
            inputSchema: [
                "type": "object",
                "required": ["filename"] as [Any],
                "properties": [
                    "filename": ["type": "string", "description": "Filename of the recording to delete (not full path — basename only)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "DELETE", httpPath: "/recording",
            bodyBuilder: { _ in nil }
        ),
        // 31. screenmuse_frames
        ToolDef(
            name: "screenmuse_frames",
            description: "Extract multiple frames from a video at regular intervals. Returns base64-encoded JPEG images.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "Video path, or \"last\" to use the most recent recording"] as [String: Any],
                    "count": ["type": "number", "description": "Number of frames to extract (default: 10)"] as [String: Any],
                    "format": ["type": "string", "enum": ["jpeg", "png"], "description": "Image format (default: jpeg)"] as [String: Any],
                    "scale": ["type": "number", "description": "Max width in pixels (default: 1280)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/frames", bodyBuilder: passArgs
        ),
        // 32. screenmuse_frame
        ToolDef(
            name: "screenmuse_frame",
            description: "Extract a single frame at a specific timestamp.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "Video path, or \"last\" for the most recent recording"] as [String: Any],
                    "time": ["type": "number", "description": "Timestamp in seconds (default: 0 = first frame)"] as [String: Any],
                    "format": ["type": "string", "enum": ["jpeg", "png"], "description": "Image format (default: jpeg)"] as [String: Any],
                    "scale": ["type": "number", "description": "Max width in pixels (default: 1280)"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/frame", bodyBuilder: passArgs
        ),
        // 33. screenmuse_validate
        ToolDef(
            name: "screenmuse_validate",
            description: "Validate a video file — check if it has real content (not a black/empty recording). Returns quality score and recommendations.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "description": "Video path, or \"last\" for the most recent recording"] as [String: Any]
                ] as [String: Any]
            ],
            httpMethod: "POST", httpPath: "/validate", bodyBuilder: passArgs
        ),
    ]
}

// MARK: - Configuration

/// Resolve the ScreenMuse base URL from environment or default.
private func resolveBaseURL() -> String {
    ProcessInfo.processInfo.environment["SCREENMUSE_URL"] ?? "http://localhost:7823"
}

/// Resolve the API key: SCREENMUSE_API_KEY env > ~/.screenmuse/api_key file > nil.
private func resolveAPIKey() -> String? {
    if ProcessInfo.processInfo.environment["SCREENMUSE_NO_AUTH"] == "1" { return nil }
    if let envKey = ProcessInfo.processInfo.environment["SCREENMUSE_API_KEY"], !envKey.isEmpty {
        return envKey
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let keyFile = home.appendingPathComponent(".screenmuse/api_key")
    if let data = try? Data(contentsOf: keyFile),
       let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !key.isEmpty {
        return key
    }
    return nil
}

// MARK: - HTTP Client

/// Make an HTTP request to the ScreenMuse API and return the response as a JSON value.
private func callScreenMuse(
    baseURL: String,
    apiKey: String?,
    method: String,
    path: String,
    body: Any?,
    queryItems: [URLQueryItem]? = nil
) async throws -> JSON {
    var components = URLComponents(string: "\(baseURL)\(path)")!
    if let queryItems, !queryItems.isEmpty {
        components.queryItems = queryItems
    }
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey {
        request.setValue(apiKey, forHTTPHeaderField: "X-ScreenMuse-Key")
    }
    if let body {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    let (data, _) = try await URLSession.shared.data(for: request)
    if data.isEmpty {
        return .object([:])
    }
    let parsed = try JSONSerialization.jsonObject(with: data)
    return anyToJSON(parsed)
}

// MARK: - Stdio Transport (Content-Length framing)

/// Write a JSON-RPC message to stdout with Content-Length framing.
private func writeMessage(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    let header = "Content-Length: \(data.count)\r\n\r\n"
    FileHandle.standardOutput.write(Data(header.utf8))
    FileHandle.standardOutput.write(data)
}

// MARK: - Tool Schema Serialization

/// Serialize a tool list for the tools/list response. Uses JSONSerialization to handle
/// the [String: Any] inputSchema dictionaries.
private func serializeToolsList(_ tools: [ToolDef]) -> [[String: Any]] {
    tools.map { tool in
        [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": tool.inputSchema
        ] as [String: Any]
    }
}

// MARK: - Message Handler

private func handleMessage(
    _ msg: MCPRequest,
    tools: [ToolDef],
    toolsByName: [String: ToolDef],
    baseURL: String,
    apiKey: String?
) async {
    let id: Any
    switch msg.id {
    case .int(let i): id = i
    case .string(let s): id = s
    case .double(let d): id = d
    case .null, .none: id = NSNull()
    default: id = NSNull()
    }

    guard let method = msg.method else { return }

    switch method {
    case "initialize":
        writeMessage([
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]] as [String: Any],
                "serverInfo": ["name": "screenmuse", "version": "1.0.0"] as [String: Any]
            ] as [String: Any]
        ] as [String: Any])

    case "tools/list":
        writeMessage([
            "jsonrpc": "2.0",
            "id": id,
            "result": ["tools": serializeToolsList(tools)] as [String: Any]
        ] as [String: Any])

    case "tools/call":
        guard let params = msg.params,
              let toolName = params["name"]?.stringValue else {
            writeMessage([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32602, "message": "Missing tool name in params"] as [String: Any]
            ] as [String: Any])
            return
        }
        let args = params["arguments"]

        guard let tool = toolsByName[toolName] else {
            writeMessage([
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "content": [["type": "text", "text": "Unknown tool: \(toolName)"] as [String: Any]],
                    "isError": true
                ] as [String: Any]
            ] as [String: Any])
            return
        }

        do {
            let body = tool.bodyBuilder(args)

            // Special handling for delete_recording: filename goes as query param
            var queryItems: [URLQueryItem]? = nil
            if toolName == "screenmuse_delete_recording" {
                if let filename = args?["filename"]?.stringValue {
                    queryItems = [URLQueryItem(name: "filename", value: filename)]
                }
            }

            let result = try await callScreenMuse(
                baseURL: baseURL,
                apiKey: apiKey,
                method: tool.httpMethod,
                path: tool.httpPath,
                body: body,
                queryItems: queryItems
            )
            // Encode the result back to a JSON string for the text content
            let resultData = try JSONSerialization.data(
                withJSONObject: jsonToAny(result),
                options: [.prettyPrinted, .sortedKeys]
            )
            let resultText = String(data: resultData, encoding: .utf8) ?? "{}"
            writeMessage([
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "content": [["type": "text", "text": resultText] as [String: Any]]
                ] as [String: Any]
            ] as [String: Any])
        } catch {
            let errorText: String
            if (error as? URLError)?.code == .cannotConnectToHost ||
               (error as? URLError)?.code == .networkConnectionLost ||
               error.localizedDescription.contains("Connection refused") {
                errorText = "ScreenMuse is not running. Launch ScreenMuse.app on your Mac, then try again.\n(Expected at \(baseURL))"
            } else {
                errorText = "Error: \(error.localizedDescription)"
            }
            writeMessage([
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "content": [["type": "text", "text": errorText] as [String: Any]],
                    "isError": true
                ] as [String: Any]
            ] as [String: Any])
        }

    case "ping":
        writeMessage([
            "jsonrpc": "2.0",
            "id": id,
            "result": [:] as [String: Any]
        ] as [String: Any])

    case "notifications/initialized":
        // No-op, no response needed
        break

    default:
        // Unknown method — respond with error if the message has an id
        if msg.id != nil {
            writeMessage([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "Method not found: \(method)"] as [String: Any]
            ] as [String: Any])
        }
    }
}

// MARK: - Main Entry Point

@main
struct ScreenMuseMCP {
    static func main() async {
        // Disable stdout buffering for immediate writes
        setbuf(stdout, nil)

        let baseURL = resolveBaseURL()
        let apiKey = resolveAPIKey()
        let tools = buildTools()
        var toolsByName: [String: ToolDef] = [:]
        for tool in tools {
            toolsByName[tool.name] = tool
        }

        // Read Content-Length framed messages from stdin synchronously.
        // Stdin reading must be synchronous; HTTP calls within handlers are async.
        let stdinHandle = FileHandle.standardInput
        var buffer = Data()

        while true {
            // Read available data from stdin
            let chunk = stdinHandle.availableData
            if chunk.isEmpty {
                // EOF — stdin closed
                break
            }
            buffer.append(chunk)

            // Parse as many complete messages as possible
            while true {
                // Look for the header/body separator: \r\n\r\n
                guard let separatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    break
                }

                let headerData = buffer[buffer.startIndex..<separatorRange.lowerBound]
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    // Skip malformed header
                    buffer = Data(buffer[separatorRange.upperBound...])
                    continue
                }

                // Extract Content-Length
                var contentLength: Int? = nil
                for line in headerString.components(separatedBy: "\r\n") {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2,
                       parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                }

                guard let length = contentLength else {
                    // No Content-Length found, skip this header block
                    buffer = Data(buffer[separatorRange.upperBound...])
                    continue
                }

                let bodyStart = separatorRange.upperBound
                let bodyEnd = buffer.index(bodyStart, offsetBy: length)

                // Not enough data yet for the full body
                if buffer.endIndex < bodyEnd {
                    break
                }

                let bodyData = buffer[bodyStart..<bodyEnd]
                buffer = Data(buffer[bodyEnd...])

                // Parse and handle the message
                guard let msg = try? JSONDecoder().decode(MCPRequest.self, from: bodyData) else {
                    continue
                }

                await handleMessage(
                    msg,
                    tools: tools,
                    toolsByName: toolsByName,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
            }
        }
    }
}
