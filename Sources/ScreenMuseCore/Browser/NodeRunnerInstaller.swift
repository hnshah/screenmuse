import Foundation

/// Manages the on-disk Node.js runner that drives Chromium for the
/// `POST /browser` endpoint.
///
/// The runner lives under `~/.screenmuse/playwright-runner/` so it stays
/// completely outside the Swift binary — ScreenMuse itself remains
/// zero-external-dependency. The runner directory is created and populated
/// on-demand via `install()`.
///
/// The installer is intentionally synchronous and blocking — it is invoked
/// from long-running HTTP handlers that already dispatch work via Task.detached,
/// and the first install (npm + chromium download) can take several minutes
/// on a cold cache.
public struct NodeRunnerInstaller: Sendable {

    public enum InstallError: Error, LocalizedError {
        case nodeNotFound
        case npmNotFound
        case runnerDirectoryCreationFailed(String)
        case writeFailed(String)
        case npmInstallFailed(Int32, String)
        case playwrightInstallFailed(Int32, String)
        case unknown(String)

        public var errorDescription: String? {
            switch self {
            case .nodeNotFound:
                return "node not found on PATH — install Node.js 18+ from https://nodejs.org"
            case .npmNotFound:
                return "npm not found on PATH — reinstall Node.js or add npm to PATH"
            case .runnerDirectoryCreationFailed(let msg):
                return "could not create runner directory: \(msg)"
            case .writeFailed(let msg):
                return "could not write runner file: \(msg)"
            case .npmInstallFailed(let code, let tail):
                return "npm install exited \(code): \(tail)"
            case .playwrightInstallFailed(let code, let tail):
                return "npx playwright install chromium exited \(code): \(tail)"
            case .unknown(let msg):
                return "runner install failed: \(msg)"
            }
        }
    }

    /// Report returned by `install()` and `status()`.
    public struct Status: Sendable {
        public let runnerDirectory: URL
        public let runnerScriptExists: Bool
        public let runnerScriptVersion: String?
        public let playwrightInstalled: Bool
        public let nodePath: String?
        public let npmPath: String?

        public var isReady: Bool {
            runnerScriptExists
                && playwrightInstalled
                && runnerScriptVersion == RunnerScript.version
                && nodePath != nil
        }

        public func asDictionary() -> [String: Any] {
            [
                "runner_directory": runnerDirectory.path,
                "runner_script_exists": runnerScriptExists,
                "runner_script_version": runnerScriptVersion ?? "",
                "playwright_installed": playwrightInstalled,
                "node_path": nodePath ?? "",
                "npm_path": npmPath ?? "",
                "ready": isReady
            ]
        }
    }

    // MARK: - Configuration

    /// Directory containing the runner files. Defaults to
    /// `~/.screenmuse/playwright-runner/`.
    public let runnerDirectory: URL

    public init(runnerDirectory: URL? = nil) {
        self.runnerDirectory = runnerDirectory ?? Self.defaultRunnerDirectory
    }

    public static let defaultRunnerDirectory: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".screenmuse/playwright-runner", isDirectory: true)
    }()

    // MARK: - Status

    /// Inspect the runner directory without performing any installs.
    /// Safe to call from any thread — pure filesystem + PATH lookup.
    public func status() -> Status {
        let fm = FileManager.default
        let runnerFile = runnerDirectory.appendingPathComponent(RunnerScript.filename)
        let runnerExists = fm.fileExists(atPath: runnerFile.path)

        // Read the version header out of the installed runner so a stale
        // install (older ScreenMuse version) can be detected and refreshed.
        var installedVersion: String? = nil
        if runnerExists,
           let contents = try? String(contentsOf: runnerFile, encoding: .utf8) {
            installedVersion = Self.extractVersion(from: contents)
        }

        let playwrightDir = runnerDirectory
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("playwright", isDirectory: true)
        let playwrightInstalled = fm.fileExists(atPath: playwrightDir.path)

        return Status(
            runnerDirectory: runnerDirectory,
            runnerScriptExists: runnerExists,
            runnerScriptVersion: installedVersion,
            playwrightInstalled: playwrightInstalled,
            nodePath: Self.findOnPath("node"),
            npmPath: Self.findOnPath("npm")
        )
    }

    // MARK: - Install

    /// Install the runner idempotently. Writes the runner script + package.json,
    /// runs `npm install`, then `npx playwright install chromium`. Returns the
    /// post-install status. Skips steps that are already satisfied.
    ///
    /// - Parameter log: optional line-level progress sink — one string per step.
    public func install(log: ((String) -> Void)? = nil) throws -> Status {
        try ensureNodeAvailable()
        try ensureDirectoryExists()
        try writeRunnerFiles(log: log)

        // `npm install` is a no-op if node_modules already has playwright and
        // the package-lock matches — we still invoke it so upgrades pick up.
        if !status().playwrightInstalled {
            log?("npm install playwright (first run — this can take a couple of minutes)…")
            try runNPMInstall(log: log)
        } else {
            log?("playwright already installed — skipping npm install")
        }

        // Chromium download is managed by playwright's own installer binary.
        // It is idempotent: re-running downloads nothing if the browser is present.
        log?("npx playwright install chromium (idempotent)…")
        try runPlaywrightInstall(log: log)

        return status()
    }

    // MARK: - Internals (file layout)

    private func ensureNodeAvailable() throws {
        guard Self.findOnPath("node") != nil else { throw InstallError.nodeNotFound }
        guard Self.findOnPath("npm") != nil  else { throw InstallError.npmNotFound }
    }

    private func ensureDirectoryExists() throws {
        do {
            try FileManager.default.createDirectory(
                at: runnerDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw InstallError.runnerDirectoryCreationFailed(error.localizedDescription)
        }
    }

    private func writeRunnerFiles(log: ((String) -> Void)?) throws {
        let runnerFile = runnerDirectory.appendingPathComponent(RunnerScript.filename)
        let packageFile = runnerDirectory.appendingPathComponent("package.json")

        // Overwrite the runner every install — the version stamp in the file
        // header tells us whether a refresh is needed, and writes are cheap.
        do {
            try RunnerScript.rendered().write(to: runnerFile, atomically: true, encoding: .utf8)
            log?("wrote \(runnerFile.path)")
        } catch {
            throw InstallError.writeFailed("runner.js: \(error.localizedDescription)")
        }

        // Only write package.json on first install — editing it after `npm install`
        // would trigger spurious reinstalls.
        if !FileManager.default.fileExists(atPath: packageFile.path) {
            do {
                try RunnerScript.packageJSON.write(to: packageFile, atomically: true, encoding: .utf8)
                log?("wrote \(packageFile.path)")
            } catch {
                throw InstallError.writeFailed("package.json: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Internals (subprocess)

    private func runNPMInstall(log: ((String) -> Void)?) throws {
        guard let npm = Self.findOnPath("npm") else { throw InstallError.npmNotFound }
        let (code, tail) = Self.runCommand(
            executable: npm,
            arguments: ["install", "--omit=dev", "--no-audit", "--no-fund"],
            workingDirectory: runnerDirectory,
            log: log
        )
        guard code == 0 else { throw InstallError.npmInstallFailed(code, tail) }
    }

    private func runPlaywrightInstall(log: ((String) -> Void)?) throws {
        guard let npx = Self.findOnPath("npx") ?? Self.findOnPath("npm") else {
            throw InstallError.npmNotFound
        }
        // Prefer `npx playwright install chromium`, fall back to a direct node
        // invocation of the bundled cli.js if npx is not present on the PATH.
        let args: [String]
        let executable: String
        if npx.hasSuffix("npx") {
            executable = npx
            args = ["playwright", "install", "chromium"]
        } else {
            // npm-only fallback: `npm exec playwright install chromium`
            executable = npx
            args = ["exec", "--", "playwright", "install", "chromium"]
        }
        let (code, tail) = Self.runCommand(
            executable: executable,
            arguments: args,
            workingDirectory: runnerDirectory,
            log: log
        )
        guard code == 0 else { throw InstallError.playwrightInstallFailed(code, tail) }
    }

    // MARK: - Static helpers

    /// Locate a binary on PATH. Falls back to a short list of common macOS
    /// install locations (Homebrew Intel + Apple Silicon, NVM, fnm, volta).
    static func findOnPath(_ name: String) -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let pathString = env["PATH"] ?? ""
        var candidates: [String] = pathString
            .split(separator: ":")
            .map { String($0) + "/" + name }

        // Common fallbacks for GUI-launched apps that inherit a minimal PATH.
        let extras = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "\(env["HOME"] ?? "")/.nvm/versions/node/current/bin/\(name)",
            "\(env["HOME"] ?? "")/.volta/bin/\(name)",
            "\(env["HOME"] ?? "")/.fnm/current/bin/\(name)"
        ]
        candidates.append(contentsOf: extras)

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Run a subprocess and capture the last 4 KB of combined output.
    /// Returns (exit status, tail). The tail is kept small so errors
    /// surface in log lines and HTTP responses without dumping megabytes.
    static func runCommand(
        executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        log: ((String) -> Void)? = nil
    ) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let wd = workingDirectory {
            process.currentDirectoryURL = wd
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "failed to spawn \(executable): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let fullOutput = String(data: data, encoding: .utf8) ?? ""
        let tail = fullOutput.count > 4096
            ? String(fullOutput.suffix(4096))
            : fullOutput
        log?("[\(executable)] exited \(process.terminationStatus)")
        return (process.terminationStatus, tail)
    }

    /// Extract the version stamp that `RunnerScript.rendered()` writes into
    /// the runner header. Returns nil if the stamp is missing or malformed.
    static func extractVersion(from source: String) -> String? {
        // Header line contains: `(generated by NodeRunnerInstaller, version N).`
        guard let marker = source.range(of: "version ") else { return nil }
        let tail = source[marker.upperBound...]
        let end = tail.firstIndex(where: { $0 == ")" || $0 == " " || $0 == "." || $0 == "\n" })
            ?? tail.endIndex
        let token = tail[..<end].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
