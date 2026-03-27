// ScreenMuse CLI — command-line interface for the ScreenMuse agent API
// Talks to a running ScreenMuse instance on localhost:7823
//
// Usage:
//   screenmuse start [--name <name>] [--window <title>] [--quality low|medium|high|max]
//   screenmuse stop [--json]
//   screenmuse record --duration <seconds> [--name <name>] [--json]
//   screenmuse status [--json]
//   screenmuse screenshot [--output <path>]
//   screenmuse chapter --name <name>
//   screenmuse highlight
//   screenmuse windows [--json]
//   screenmuse health
//   screenmuse version

import Foundation

// MARK: - HTTP Client

struct ScreenMuseClient {
    let baseURL: String
    let apiKey: String?

    init(port: Int = 7823, apiKey: String? = nil) {
        self.baseURL = "http://127.0.0.1:\(port)"
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["SCREENMUSE_API_KEY"]
    }

    func get(_ path: String) async throws -> [String: Any] {
        let url = URL(string: baseURL + path)!
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "GET"
        if let key = apiKey { req.setValue(key, forHTTPHeaderField: "X-ScreenMuse-Key") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return try parseResponse(data: data, response: resp as! HTTPURLResponse)
    }

    func post(_ path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        let url = URL(string: baseURL + path)!
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey { req.setValue(key, forHTTPHeaderField: "X-ScreenMuse-Key") }
        if !body.isEmpty { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return try parseResponse(data: data, response: resp as! HTTPURLResponse)
    }

    func delete(_ path: String) async throws -> [String: Any] {
        let url = URL(string: baseURL + path)!
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "DELETE"
        if let key = apiKey { req.setValue(key, forHTTPHeaderField: "X-ScreenMuse-Key") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return try parseResponse(data: data, response: resp as! HTTPURLResponse)
    }

    private func parseResponse(data: Data, response: HTTPURLResponse) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.invalidResponse("Server returned non-JSON response (HTTP \(response.statusCode))")
        }
        if response.statusCode >= 400 {
            let msg = json["error"] as? String ?? json["message"] as? String ?? "HTTP \(response.statusCode)"
            throw CLIError.apiError(msg)
        }
        return json
    }
}

// MARK: - Errors

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case apiError(String)
    case invalidResponse(String)
    case connectionRefused

    var description: String {
        switch self {
        case .usage(let msg):            return "Usage error: \(msg)"
        case .apiError(let msg):         return "API error: \(msg)"
        case .invalidResponse(let msg):  return "Response error: \(msg)"
        case .connectionRefused:         return "Cannot connect to ScreenMuse. Is it running?"
        }
    }
}

// MARK: - Output helpers

func printJSON(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s)s" }
    return "\(s / 60)m \(s % 60)s"
}

func formatSize(_ mb: Double) -> String {
    if mb < 1.0 { return String(format: "%.0f KB", mb * 1024) }
    return String(format: "%.1f MB", mb)
}

// MARK: - Argument parsing helpers

struct Args {
    let positional: [String]
    let flags: [String: String]
    let boolFlags: Set<String>

    init(_ args: [String]) {
        var pos: [String] = []
        var flags: [String: String] = [:]
        var bools: Set<String> = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count && !args[i+1].hasPrefix("--") {
                    flags[key] = args[i+1]
                    i += 2
                } else {
                    bools.insert(key)
                    i += 1
                }
            } else {
                pos.append(a)
                i += 1
            }
        }
        self.positional = pos
        self.flags = flags
        self.boolFlags = bools
    }

    subscript(_ key: String) -> String? { flags[key] }
    func has(_ key: String) -> Bool { boolFlags.contains(key) || flags[key] != nil }
    func bool(_ key: String) -> Bool { boolFlags.contains(key) }
}

// MARK: - Commands

func cmdStart(args: Args, client: ScreenMuseClient) async throws {
    var body: [String: Any] = [:]
    if let name = args["name"] { body["name"] = name }
    if let window = args["window"] { body["window_title"] = window }
    if let quality = args["quality"] { body["quality"] = quality }

    let resp = try await client.post("/start", body: body)
    let name = resp["session_name"] as? String ?? "unnamed"
    let id = resp["session_id"] as? String ?? "?"
    print("Recording started: \(name) (\(id))")
}

func cmdStop(args: Args, client: ScreenMuseClient) async throws {
    let resp = try await client.post("/stop")
    if args.bool("json") {
        printJSON(resp)
        return
    }
    let path = resp["video_path"] as? String ?? "unknown"
    let elapsed = resp["elapsed"] as? Double ?? 0
    let sizeMB = resp["size_mb"] as? Double
    let fps = resp["fps"] as? Double
    let res = resp["resolution"] as? String

    var parts = ["✓ Stopped after \(formatDuration(elapsed))"]
    if let r = res, let f = fps { parts.append("\(r) @ \(Int(f))fps") }
    if let s = sizeMB { parts.append(formatSize(s)) }
    print(parts.joined(separator: " · "))
    print(path)
}

func cmdRecord(args: Args, client: ScreenMuseClient) async throws {
    guard let durStr = args["duration"], let duration = Double(durStr) else {
        throw CLIError.usage("--duration <seconds> is required")
    }
    guard duration > 0 && duration <= 3600 else {
        throw CLIError.usage("--duration must be between 1 and 3600 seconds")
    }

    var startBody: [String: Any] = [:]
    if let name = args["name"] { startBody["name"] = name }
    if let window = args["window"] { startBody["window_title"] = window }
    if let quality = args["quality"] { startBody["quality"] = quality }

    let startResp = try await client.post("/start", body: startBody)
    let name = startResp["session_name"] as? String ?? "recording"
    print("Recording: \(name) (\(Int(duration))s)...")

    // Sleep for duration
    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

    let stopResp = try await client.post("/stop")
    if args.bool("json") {
        printJSON(stopResp)
        return
    }
    let path = stopResp["video_path"] as? String ?? "unknown"
    let elapsed = stopResp["elapsed"] as? Double ?? 0
    let sizeMB = stopResp["size_mb"] as? Double

    var summary = "✓ \(formatDuration(elapsed))"
    if let s = sizeMB { summary += " · \(formatSize(s))" }
    print(summary)
    print(path)
}

func cmdStatus(args: Args, client: ScreenMuseClient) async throws {
    let resp = try await client.get("/status")
    if args.bool("json") {
        printJSON(resp)
        return
    }
    let recording = resp["recording"] as? Bool ?? false
    if recording {
        let name = resp["session_name"] as? String ?? "unnamed"
        let elapsed = resp["elapsed"] as? Double ?? 0
        let paused = resp["paused"] as? Bool ?? false
        let state = paused ? "paused" : "recording"
        print("● \(state): \(name) (\(formatDuration(elapsed)))")
        if let chapters = resp["chapter_count"] as? Int, chapters > 0 {
            print("  Chapters: \(chapters)")
        }
    } else {
        print("○ Not recording")
    }
}

func cmdScreenshot(args: Args, client: ScreenMuseClient) async throws {
    var body: [String: Any] = [:]
    if let output = args["output"] { body["output_path"] = output }

    let resp = try await client.post("/screenshot", body: body)
    let path = resp["path"] as? String ?? resp["screenshot_path"] as? String ?? "unknown"
    print(path)
}

func cmdChapter(args: Args, client: ScreenMuseClient) async throws {
    guard let name = args["name"] else {
        throw CLIError.usage("--name <chapter name> is required")
    }
    _ = try await client.post("/chapter", body: ["name": name])
    print("✓ Chapter: \(name)")
}

func cmdHighlight(args: Args, client: ScreenMuseClient) async throws {
    _ = try await client.post("/highlight")
    print("✓ Next click will be highlighted")
}

func cmdWindows(args: Args, client: ScreenMuseClient) async throws {
    let resp = try await client.get("/windows")
    if args.bool("json") {
        printJSON(resp)
        return
    }
    guard let windows = resp["windows"] as? [[String: Any]] else {
        print("No windows found")
        return
    }
    if windows.isEmpty {
        print("No capturable windows")
        return
    }
    print("Capturable windows:")
    for w in windows {
        let title = w["title"] as? String ?? "(untitled)"
        let app = w["app"] as? String ?? ""
        let pid = w["pid"] as? Int
        var line = "  \(title)"
        if !app.isEmpty { line += " — \(app)" }
        if let p = pid { line += " [pid \(p)]" }
        print(line)
    }
}

func cmdHealth(args: Args, client: ScreenMuseClient) async throws {
    let resp = try await client.get("/health")
    let ok = resp["ok"] as? Bool ?? false
    let version = resp["version"] as? String ?? "?"
    if ok {
        print("✓ ScreenMuse \(version) — healthy")
    } else {
        print("✗ Unhealthy response")
        Foundation.exit(1)
    }
}

func cmdVersion(args: Args, client: ScreenMuseClient) async throws {
    let resp = try await client.get("/version")
    let version = resp["version"] as? String ?? "?"
    print("ScreenMuse \(version)")
}

func cmdExport(args: Args, client: ScreenMuseClient) async throws {
    var body: [String: Any] = [:]
    if let input = args["input"]   { body["input_path"] = input }
    if let output = args["output"] { body["output_path"] = output }
    if let format = args["format"] { body["format"] = format }
    if let start = args["start"], let s = Double(start) { body["start_time"] = s }
    if let end = args["end"], let e = Double(end)       { body["end_time"] = e }

    print("Exporting...")
    let resp = try await client.post("/export", body: body)
    if args.bool("json") {
        printJSON(resp)
        return
    }
    let path = resp["output_path"] as? String ?? resp["path"] as? String ?? "unknown"
    print("✓ Exported: \(path)")
}

func cmdTrim(args: Args, client: ScreenMuseClient) async throws {
    guard let startStr = args["start"], let start = Double(startStr) else {
        throw CLIError.usage("--start <seconds> is required")
    }
    guard let endStr = args["end"], let end = Double(endStr) else {
        throw CLIError.usage("--end <seconds> is required")
    }
    var body: [String: Any] = ["start_time": start, "end_time": end]
    if let input = args["input"]   { body["input_path"] = input }
    if let output = args["output"] { body["output_path"] = output }

    print("Trimming...")
    let resp = try await client.post("/trim", body: body)
    if args.bool("json") {
        printJSON(resp)
        return
    }
    let path = resp["output_path"] as? String ?? resp["path"] as? String ?? "unknown"
    print("✓ Trimmed: \(path)")
}

func printHelp() {
    print("""
    screenmuse — control ScreenMuse from the command line

    USAGE
      screenmuse <command> [options]

    COMMANDS
      start      Start a new recording
      stop       Stop recording and print the video path
      record     Record for a fixed duration (start + wait + stop)
      status     Show current recording state
      screenshot Take a screenshot
      chapter    Add a chapter marker
      highlight  Flag the next click for auto-zoom effect
      windows    List windows available for capture
      export     Export the last recording (GIF, MP4, etc.)
      trim       Trim a video to a time range
      health     Check if ScreenMuse is running
      version    Print ScreenMuse version

    OPTIONS
      --port <n>       API port (default: 7823, or $SCREENMUSE_PORT)
      --api-key <key>  API key (or $SCREENMUSE_API_KEY)
      --json           Output raw JSON

    EXAMPLES
      screenmuse record --name "demo" --duration 30
      screenmuse start --name "walkthrough" --quality high
      screenmuse chapter --name "Installation"
      screenmuse stop
      screenmuse screenshot --output ~/Desktop/shot.png
      screenmuse windows
      screenmuse export --format gif --output ~/Desktop/demo.gif
      screenmuse trim --start 5 --end 45 --output ~/Desktop/trimmed.mp4
    """)
}

// MARK: - Entry point

@main
struct ScreenMuseCLI {
    static func main() async {
        let allArgs = Array(CommandLine.arguments.dropFirst()) // drop binary name
        let rawArgs = Args(allArgs)

        guard let command = rawArgs.positional.first else {
            printHelp()
            return
        }

        // Build client from global options
        let portStr = rawArgs["port"] ?? ProcessInfo.processInfo.environment["SCREENMUSE_PORT"] ?? "7823"
        let port = Int(portStr) ?? 7823
        let apiKey = rawArgs["api-key"]
        let client = ScreenMuseClient(port: port, apiKey: apiKey)

        // Strip the command from positional so subcommands see clean args
        let subArgs = Args(Array(allArgs.dropFirst()))

        do {
            switch command {
            case "start":       try await cmdStart(args: subArgs, client: client)
            case "stop":        try await cmdStop(args: subArgs, client: client)
            case "record":      try await cmdRecord(args: subArgs, client: client)
            case "status":      try await cmdStatus(args: subArgs, client: client)
            case "screenshot":  try await cmdScreenshot(args: subArgs, client: client)
            case "chapter":     try await cmdChapter(args: subArgs, client: client)
            case "highlight":   try await cmdHighlight(args: subArgs, client: client)
            case "windows":     try await cmdWindows(args: subArgs, client: client)
            case "export":      try await cmdExport(args: subArgs, client: client)
            case "trim":        try await cmdTrim(args: subArgs, client: client)
            case "health":      try await cmdHealth(args: subArgs, client: client)
            case "version":     try await cmdVersion(args: subArgs, client: client)
            case "help", "--help", "-h":
                printHelp()
            default:
                fputs("Unknown command: \(command)\n", stderr)
                fputs("Run 'screenmuse help' for usage.\n", stderr)
                Foundation.exit(1)
            }
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            fputs("Error: Cannot connect to ScreenMuse on port \(port). Is it running?\n", stderr)
            Foundation.exit(1)
        } catch let error as CLIError {
            fputs("Error: \(error.description)\n", stderr)
            Foundation.exit(1)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}
