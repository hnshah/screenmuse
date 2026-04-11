import Foundation

/// User configuration loaded from `~/.screenmuse.json`.
///
/// Priority order for values like `apiKey` and `port`:
///   programmatic > environment variable > config file > built-in default
///
/// `load()` never throws — returns defaults if the file is missing or malformed.
///
/// v2 adds optional nested blocks for per-feature defaults:
///   narration / browser / publish / metrics / disk
///
/// All v2 blocks are optional, so v1 flat config files continue to load
/// unchanged.  Handlers merge their per-request overrides on top of
/// `ScreenMuseConfig.load()` at dispatch time.
public struct ScreenMuseConfig: Codable, Sendable {
    public var port: Int
    public var apiKey: String?
    public var defaultQuality: String
    public var outputDirectory: String?
    public var logLevel: String
    public var webhookURL: String?

    // v2 — per-feature defaults. All nilable so v1 files still parse.
    public var narration: NarrationDefaults?
    public var browser: BrowserDefaults?
    public var publish: PublishDefaults?
    public var metrics: MetricsDefaults?
    public var disk: DiskDefaults?

    public static let configPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".screenmuse.json")
    }()

    public init(
        port: Int = 7823,
        apiKey: String? = nil,
        defaultQuality: String = "medium",
        outputDirectory: String? = nil,
        logLevel: String = "info",
        webhookURL: String? = nil,
        narration: NarrationDefaults? = nil,
        browser: BrowserDefaults? = nil,
        publish: PublishDefaults? = nil,
        metrics: MetricsDefaults? = nil,
        disk: DiskDefaults? = nil
    ) {
        self.port = port
        self.apiKey = apiKey
        self.defaultQuality = defaultQuality
        self.outputDirectory = outputDirectory
        self.logLevel = logLevel
        self.webhookURL = webhookURL
        self.narration = narration
        self.browser = browser
        self.publish = publish
        self.metrics = metrics
        self.disk = disk
    }

    // MARK: - Nested defaults

    /// Defaults merged into every `POST /narrate` call when the request
    /// omits a field. Handler precedence: request body > env var > this block.
    public struct NarrationDefaults: Codable, Sendable {
        public var provider: String?       // "ollama" / "anthropic"
        public var model: String?          // e.g. "llava:7b"
        public var apiKey: String?         // fallback for ANTHROPIC_API_KEY
        public var endpoint: String?       // custom Ollama / Anthropic URL
        public var style: String?          // technical / casual / tutorial
        public var maxChapters: Int?
        public var frameCount: Int?
        public var language: String?

        public init(
            provider: String? = nil,
            model: String? = nil,
            apiKey: String? = nil,
            endpoint: String? = nil,
            style: String? = nil,
            maxChapters: Int? = nil,
            frameCount: Int? = nil,
            language: String? = nil
        ) {
            self.provider = provider
            self.model = model
            self.apiKey = apiKey
            self.endpoint = endpoint
            self.style = style
            self.maxChapters = maxChapters
            self.frameCount = frameCount
            self.language = language
        }
    }

    /// Defaults for `POST /browser` — saves agents from repeating common
    /// params like viewport size and navigation gate on every call.
    public struct BrowserDefaults: Codable, Sendable {
        public var width: Int?
        public var height: Int?
        public var quality: String?
        public var waitFor: String?        // load / domcontentloaded / networkidle / commit
        public var userAgent: String?
        public var locale: String?
        public var timezoneId: String?

        public init(
            width: Int? = nil,
            height: Int? = nil,
            quality: String? = nil,
            waitFor: String? = nil,
            userAgent: String? = nil,
            locale: String? = nil,
            timezoneId: String? = nil
        ) {
            self.width = width
            self.height = height
            self.quality = quality
            self.waitFor = waitFor
            self.userAgent = userAgent
            self.locale = locale
            self.timezoneId = timezoneId
        }
    }

    /// Defaults for `POST /publish`. Slack webhook URL + S3 presigned URL
    /// template are the two fields agents want to set once and forget.
    ///
    /// Explicit CodingKeys because `convertFromSnakeCase` turns
    /// `slack_webhook_url` into `slackWebhookUrl` (lowercase `url`),
    /// but we want the Swift property named `slackWebhookURL` to match
    /// the convention used elsewhere in the codebase.
    public struct PublishDefaults: Codable, Sendable {
        public var defaultDestination: String?   // "slack" / "http_put" / "webhook"
        public var slackWebhookURL: String?
        public var webhookURL: String?
        public var s3BucketURL: String?          // e.g. https://bucket.s3.us-east-1.amazonaws.com

        enum CodingKeys: String, CodingKey {
            case defaultDestination = "default_destination"
            case slackWebhookURL = "slack_webhook_url"
            case webhookURL = "webhook_url"
            case s3BucketURL = "s3_bucket_url"
        }

        public init(
            defaultDestination: String? = nil,
            slackWebhookURL: String? = nil,
            webhookURL: String? = nil,
            s3BucketURL: String? = nil
        ) {
            self.defaultDestination = defaultDestination
            self.slackWebhookURL = slackWebhookURL
            self.webhookURL = webhookURL
            self.s3BucketURL = s3BucketURL
        }
    }

    /// Toggles for `/metrics`. Currently only the enable flag — room
    /// for future controls like scrape_interval or custom labels.
    public struct MetricsDefaults: Codable, Sendable {
        public var enabled: Bool?

        public init(enabled: Bool? = nil) {
            self.enabled = enabled
        }
    }

    /// Disk-space guard thresholds. `minFreeGB` overrides
    /// `DiskSpaceGuard.defaultMinFreeBytes` at server boot.
    ///
    /// Explicit CodingKeys because `min_free_gb` converts to `minFreeGb`
    /// under the default snake-case strategy, but we want `minFreeGB`
    /// (uppercase acronym) as the Swift name.
    public struct DiskDefaults: Codable, Sendable {
        public var minFreeGB: Double?

        enum CodingKeys: String, CodingKey {
            case minFreeGB = "min_free_gb"
        }

        public init(minFreeGB: Double? = nil) {
            self.minFreeGB = minFreeGB
        }

        /// Byte-level view of the configured threshold, for plumbing
        /// directly into `DiskSpaceGuard(minFreeBytes:)`.
        public var minFreeBytes: Int64? {
            minFreeGB.map { Int64($0 * 1024 * 1024 * 1024) }
        }
    }

    // MARK: - IO

    /// Load config from `~/.screenmuse.json`, returning defaults if the file
    /// is missing or cannot be decoded.
    public static func load() -> ScreenMuseConfig {
        let url = configPath
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ScreenMuseConfig()
        }
        do {
            let data = try Data(contentsOf: url)
            return try decode(from: data)
        } catch {
            // Log to stderr so both CLI and server see the warning without
            // depending on ScreenMuseLogger (avoids circular init order).
            fputs("Warning: could not parse ~/.screenmuse.json — using defaults (\(error.localizedDescription))\n", stderr)
            return ScreenMuseConfig()
        }
    }

    /// Decode a config from raw JSON data. Extracted from `load()` so
    /// tests can exercise the v1/v2 compat matrix without touching the
    /// filesystem.
    public static func decode(from data: Data) throws -> ScreenMuseConfig {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ScreenMuseConfig.self, from: data)
    }

    /// Write the current config to `~/.screenmuse.json`.
    public func save() throws {
        let data = try encode()
        try data.write(to: Self.configPath, options: .atomic)
    }

    /// Encode this config as JSON bytes. Extracted so tests can assert
    /// on the exact snake_case output without touching the filesystem.
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Resolve `~` and `~user` prefixes in `outputDirectory` to an absolute path.
    public var resolvedOutputDirectory: String? {
        guard let dir = outputDirectory else { return nil }
        return (dir as NSString).expandingTildeInPath
    }
}
