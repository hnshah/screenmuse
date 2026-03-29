import Foundation

/// User configuration loaded from `~/.screenmuse.json`.
///
/// Priority order for values like `apiKey` and `port`:
///   programmatic > environment variable > config file > built-in default
///
/// `load()` never throws — returns defaults if the file is missing or malformed.
public struct ScreenMuseConfig: Codable, Sendable {
    public var port: Int
    public var apiKey: String?
    public var defaultQuality: String
    public var outputDirectory: String?
    public var logLevel: String
    public var webhookURL: String?

    public static let configPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".screenmuse.json")
    }()

    public init(
        port: Int = 7823,
        apiKey: String? = nil,
        defaultQuality: String = "medium",
        outputDirectory: String? = nil,
        logLevel: String = "info",
        webhookURL: String? = nil
    ) {
        self.port = port
        self.apiKey = apiKey
        self.defaultQuality = defaultQuality
        self.outputDirectory = outputDirectory
        self.logLevel = logLevel
        self.webhookURL = webhookURL
    }

    /// Load config from `~/.screenmuse.json`, returning defaults if the file
    /// is missing or cannot be decoded.
    public static func load() -> ScreenMuseConfig {
        let url = configPath
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ScreenMuseConfig()
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ScreenMuseConfig.self, from: data)
        } catch {
            // Log to stderr so both CLI and server see the warning without
            // depending on ScreenMuseLogger (avoids circular init order).
            fputs("Warning: could not parse ~/.screenmuse.json — using defaults (\(error.localizedDescription))\n", stderr)
            return ScreenMuseConfig()
        }
    }

    /// Write the current config to `~/.screenmuse.json`.
    public func save() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.configPath, options: .atomic)
    }

    /// Resolve `~` and `~user` prefixes in `outputDirectory` to an absolute path.
    public var resolvedOutputDirectory: String? {
        guard let dir = outputDirectory else { return nil }
        return (dir as NSString).expandingTildeInPath
    }
}
