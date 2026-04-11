import Foundation

/// Orchestrates a single browser-recording session.
///
/// The recorder spawns a Node.js subprocess (see `RunnerScript.swift`)
/// that launches a headful Chromium window. It parses the runner's
/// line-based control protocol on stdout, surfaces a `ReadyEvent` once
/// the browser window is visible, then waits for the runner to exit.
///
/// `BrowserRecorder` itself knows nothing about `RecordingManager` or
/// the `ScreenMuseServer` — it just exposes two awaitable events:
///   `waitForReady()` → returns window metadata so the caller can kick
///   off screen capture against that window.
///   `signalGoAndWaitForCompletion()` → tells the runner to start running
///   its user script, then waits for the runner to exit cleanly.
///
/// This split keeps the HTTP handler linear:
///
///     let ready = try await recorder.waitForReady()
///     try await coordinator.startRecording(name:…, windowTitle: ready.title, …)
///     let outcome = try await recorder.signalGoAndWaitForCompletion()
///     let videoURL = await coordinator.stopAndGetVideo()
///
public final class BrowserRecorder: @unchecked Sendable {

    // MARK: - Types

    public enum RecorderError: Error, LocalizedError {
        case runnerNotInstalled
        case runnerLaunchFailed(String)
        case readyTimeout(Double)
        case runnerFatal(String)
        case runnerExitedWithoutReady
        case navigationFailed(String)
        case scriptFailed(String)
        case runnerExited(Int32)

        public var errorDescription: String? {
            switch self {
            case .runnerNotInstalled:
                return "Node runner not installed — call POST /browser/install first"
            case .runnerLaunchFailed(let msg):
                return "could not launch node runner: \(msg)"
            case .readyTimeout(let secs):
                return "browser did not become ready within \(secs)s (page load too slow or runner crashed silently)"
            case .runnerFatal(let msg):
                return "runner reported fatal error: \(msg)"
            case .runnerExitedWithoutReady:
                return "runner exited before it signaled READY — page did not load"
            case .navigationFailed(let msg):
                return "navigation failed: \(msg)"
            case .scriptFailed(let msg):
                return "user script failed: \(msg)"
            case .runnerExited(let code):
                return "runner exited with code \(code)"
            }
        }
    }

    /// Emitted by the runner once Chromium is visible and the page has loaded.
    public struct ReadyEvent: Sendable {
        public let title: String
        public let pid: Int
        public let url: String
        public let navError: String?
    }

    /// Outcome of a completed browser run.
    public struct Outcome: Sendable {
        public let exitCode: Int32
        public let scriptError: String?
        public let navError: String?
        public let elapsedMs: Int
    }

    /// Request config passed to the runner as a JSON string on argv[2].
    ///
    /// v2 fields (cookies, storageState, userAgent, waitFor, extraArgs,
    /// localeHint, timezoneHint) are all optional and backward-compatible
    /// with the v1 runner. The Node runner checks the embedded version
    /// stamp so a stale install won't silently drop new fields.
    public struct Config: Sendable {
        public let url: String
        public let script: String?
        public let durationMs: Int
        public let width: Int
        public let height: Int
        public let navTimeoutMs: Int

        // v2
        public let cookies: [Cookie]
        public let storageStatePath: String?
        public let userAgent: String?
        public let waitFor: WaitCondition
        public let extraArgs: [String]
        public let localeHint: String?
        public let timezoneHint: String?

        /// Page-load gate that the runner must reach before signaling READY.
        /// Maps 1:1 onto Playwright's page.goto waitUntil options.
        public enum WaitCondition: String, Sendable, Codable {
            case load
            case domcontentloaded
            case networkidle
            case commit
        }

        /// A single cookie entry seeded into the Playwright context
        /// before navigation. Mirrors the shape Playwright expects.
        public struct Cookie: Sendable, Codable {
            public let name: String
            public let value: String
            public let domain: String?
            public let path: String?
            public let expires: Double?
            public let httpOnly: Bool?
            public let secure: Bool?
            public let sameSite: String?

            public init(
                name: String,
                value: String,
                domain: String? = nil,
                path: String? = nil,
                expires: Double? = nil,
                httpOnly: Bool? = nil,
                secure: Bool? = nil,
                sameSite: String? = nil
            ) {
                self.name = name
                self.value = value
                self.domain = domain
                self.path = path
                self.expires = expires
                self.httpOnly = httpOnly
                self.secure = secure
                self.sameSite = sameSite
            }

            func asDictionary() -> [String: Any] {
                var dict: [String: Any] = ["name": name, "value": value]
                if let domain { dict["domain"] = domain }
                if let path { dict["path"] = path }
                if let expires { dict["expires"] = expires }
                if let httpOnly { dict["httpOnly"] = httpOnly }
                if let secure { dict["secure"] = secure }
                if let sameSite { dict["sameSite"] = sameSite }
                return dict
            }
        }

        public init(
            url: String,
            script: String? = nil,
            durationMs: Int,
            width: Int = 1280,
            height: Int = 720,
            navTimeoutMs: Int = 30_000,
            cookies: [Cookie] = [],
            storageStatePath: String? = nil,
            userAgent: String? = nil,
            waitFor: WaitCondition = .load,
            extraArgs: [String] = [],
            localeHint: String? = nil,
            timezoneHint: String? = nil
        ) {
            self.url = url
            self.script = script
            self.durationMs = durationMs
            self.width = width
            self.height = height
            self.navTimeoutMs = navTimeoutMs
            self.cookies = cookies
            self.storageStatePath = storageStatePath
            self.userAgent = userAgent
            self.waitFor = waitFor
            self.extraArgs = extraArgs
            self.localeHint = localeHint
            self.timezoneHint = timezoneHint
        }

        func asJSON() throws -> String {
            var dict: [String: Any] = [
                "url": url,
                "duration_ms": durationMs,
                "width": width,
                "height": height,
                "nav_timeout_ms": navTimeoutMs,
                "wait_for": waitFor.rawValue
            ]
            if let s = script { dict["script"] = s }
            if !cookies.isEmpty {
                dict["cookies"] = cookies.map { $0.asDictionary() }
            }
            if let path = storageStatePath { dict["storage_state_path"] = path }
            if let ua = userAgent { dict["user_agent"] = ua }
            if !extraArgs.isEmpty { dict["extra_args"] = extraArgs }
            if let locale = localeHint { dict["locale"] = locale }
            if let tz = timezoneHint { dict["timezone_id"] = tz }
            let data = try JSONSerialization.data(withJSONObject: dict)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    // MARK: - State

    private let installer: NodeRunnerInstaller
    private let config: Config
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stdinPipe: Pipe?
    private var stderrPipe: Pipe?

    // Ready signal buffers
    private let readyBox = EventBox<ReadyEvent>()
    private let outcomeBox = EventBox<Outcome>()
    private var stdoutBuffer = ""
    private let bufferLock = NSLock()

    // MARK: - Init

    public init(installer: NodeRunnerInstaller = NodeRunnerInstaller(), config: Config) {
        self.installer = installer
        self.config = config
    }

    // MARK: - Lifecycle

    /// Spawn the node runner. Must be called before `waitForReady`.
    public func launch() throws {
        let status = installer.status()
        guard status.isReady else { throw RecorderError.runnerNotInstalled }
        guard let nodePath = status.nodePath else { throw RecorderError.runnerNotInstalled }

        let runnerFile = installer.runnerDirectory
            .appendingPathComponent(RunnerScript.filename)

        let jsonConfig: String
        do {
            jsonConfig = try config.asJSON()
        } catch {
            throw RecorderError.runnerLaunchFailed("config encoding failed: \(error.localizedDescription)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [runnerFile.path, jsonConfig]
        proc.currentDirectoryURL = installer.runnerDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = stdin

        // Stream stdout line-by-line so we can catch SM:READY without
        // draining the whole pipe (which would block until the process exits).
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty { return }
            if let chunk = String(data: data, encoding: .utf8) {
                self.consumeStdout(chunk)
            }
        }
        // Drain stderr so Chromium log noise doesn't fill the pipe buffer and
        // block the child process. We do not currently surface it anywhere.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        // Completion: parse DONE event, resolve outcome.
        proc.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            // Drain any trailing bytes before closing.
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let trailing = stdout.fileHandleForReading.availableData
            if !trailing.isEmpty, let chunk = String(data: trailing, encoding: .utf8) {
                self.consumeStdout(chunk)
            }
            self.resolveTermination(exitCode: terminated.terminationStatus)
        }

        do {
            try proc.run()
        } catch {
            throw RecorderError.runnerLaunchFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.stdinPipe = stdin
    }

    /// Await the runner's SM:READY event. Throws on timeout or fatal runner error.
    public func waitForReady(timeout: TimeInterval = 45) async throws -> ReadyEvent {
        do {
            return try await readyBox.wait(timeout: timeout)
        } catch EventBox<ReadyEvent>.TimeoutError.timedOut {
            terminateRunner()
            throw RecorderError.readyTimeout(timeout)
        }
    }

    /// Write "GO\n" to the runner's stdin and await process exit.
    /// Call this *after* the caller has started screen recording.
    public func signalGoAndWaitForCompletion(timeout: TimeInterval = 600) async throws -> Outcome {
        if let stdin = stdinPipe {
            let goLine = "GO\n".data(using: .utf8) ?? Data()
            stdin.fileHandleForWriting.write(goLine)
        }
        do {
            return try await outcomeBox.wait(timeout: timeout)
        } catch EventBox<Outcome>.TimeoutError.timedOut {
            terminateRunner()
            throw RecorderError.runnerExited(-1)
        }
    }

    /// Force-terminate the runner. Safe to call from any state.
    public func terminateRunner() {
        process?.terminate()
    }

    // MARK: - Stdout parsing

    /// Consume bytes from stdout, split into lines, dispatch SM: events.
    private func consumeStdout(_ chunk: String) {
        bufferLock.lock()
        stdoutBuffer += chunk
        var lines: [String] = []
        while let newlineIdx = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[stdoutBuffer.startIndex..<newlineIdx])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIdx)
            lines.append(line)
        }
        bufferLock.unlock()

        for line in lines {
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        // Runner prefixes everything with SM: — anything else is noise from
        // Playwright or Chromium that we ignore.
        guard line.hasPrefix("SM:") else { return }
        let body = String(line.dropFirst(3))
        guard let firstColon = body.firstIndex(of: ":") else { return }
        let tag = String(body[body.startIndex..<firstColon])
        let payload = String(body[body.index(after: firstColon)...])

        switch tag {
        case "READY":
            if let data = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let event = ReadyEvent(
                    title: obj["title"] as? String ?? "",
                    pid: obj["pid"] as? Int ?? 0,
                    url: obj["url"] as? String ?? "",
                    navError: obj["nav_error"] as? String
                )
                readyBox.resolve(event)
            } else {
                readyBox.fail(RecorderError.runnerFatal("malformed READY payload: \(payload)"))
            }
        case "FATAL":
            readyBox.fail(RecorderError.runnerFatal(payload))
            outcomeBox.fail(RecorderError.runnerFatal(payload))
        case "NAV_ERROR":
            // Don't fail — navigation errors are reported in the READY event
            // via `nav_error`. The runner still proceeds so agents can record
            // the error page. Log-only here.
            break
        case "SCRIPT_OK", "SCRIPT_ERROR", "DONE":
            // DONE is handled in terminationHandler; individual script events
            // are just informational.
            break
        default:
            break
        }
    }

    private func resolveTermination(exitCode: Int32) {
        // Parse the most recent DONE line out of the buffer tail if present,
        // so the outcome can report script/nav errors accurately.
        bufferLock.lock()
        let tail = stdoutBuffer
        bufferLock.unlock()

        var scriptError: String? = nil
        var navError: String? = nil
        var elapsedMs: Int = 0
        // Search any residual buffer for a DONE line.
        for line in tail.components(separatedBy: "\n") where line.hasPrefix("SM:DONE:") {
            let payload = String(line.dropFirst("SM:DONE:".count))
            if let data = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                scriptError = obj["script_error"] as? String
                navError = obj["nav_error"] as? String
                elapsedMs = obj["elapsed_ms"] as? Int ?? 0
            }
        }

        let outcome = Outcome(
            exitCode: exitCode,
            scriptError: scriptError,
            navError: navError,
            elapsedMs: elapsedMs
        )
        outcomeBox.resolve(outcome)
        // If READY never fired, propagate a structured error to anyone waiting.
        readyBox.fail(RecorderError.runnerExitedWithoutReady)
    }
}

// MARK: - EventBox

/// One-shot awaitable box. Multiple callers can `wait()`; the first
/// `resolve(_:)` or `fail(_:)` releases them all. Subsequent resolve/fail
/// calls are no-ops — the box locks in the first result.
///
/// Timeout implementation resolves the box globally with `TimeoutError.timedOut`
/// if nothing has resolved it by then, which is the correct semantics for
/// one-shot use (one waiter per box). That avoids leaking a CheckedContinuation
/// on timeout, which is a runtime error in Swift 6 and a subtle hang in 5.
final class EventBox<Value>: @unchecked Sendable {
    enum TimeoutError: Error { case timedOut }

    private let lock = NSLock()
    private var value: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    func resolve(_ v: Value) {
        lock.lock()
        if value != nil { lock.unlock(); return }
        value = .success(v)
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for c in pending { c.resume(returning: v) }
    }

    func fail(_ e: Error) {
        lock.lock()
        if value != nil { lock.unlock(); return }
        value = .failure(e)
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for c in pending { c.resume(throwing: e) }
    }

    func wait(timeout: TimeInterval) async throws -> Value {
        // Arm a cancel-on-resolve timeout. If the box resolves naturally,
        // `timeoutTask.cancel()` in the defer throws CancellationError
        // inside the sleep and the `try?` below swallows it — so we never
        // spuriously fail a box that already succeeded.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.fail(TimeoutError.timedOut)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let v = value {
                lock.unlock()
                cont.resume(with: v)
                return
            }
            waiters.append(cont)
            lock.unlock()
        }
    }
}
