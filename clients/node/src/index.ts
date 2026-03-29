import * as fs from "fs";
import * as os from "os";
import * as path from "path";

// ── Types matching actual API responses ───────────────────────────────────────

export interface RecordingStatus {
  recording: boolean;
  elapsed: number;
  session_id: string;
  chapters: Array<{ name: string; time: number }>;
  last_video: string;
  sessions_active: number;
  sessions_total: number;
  // Note: paused is NOT returned by the server; removed to match actual response
}

/** Actual /stop response from enrichedStopResponse() */
export interface RecordingResult {
  /** Full path to the recorded MP4 */
  path: string;
  /** Alias for path (backward compat) */
  video_path: string;
  /** Recording duration in seconds */
  duration: number;
  /** File size in bytes */
  size: number;
  /** File size in megabytes (2 decimal places) */
  size_mb: number;
  session_id: string;
  chapters: Array<{ name: string; time: number }>;
  notes: Array<{ text: string; time: number }>;
  /** Present when resolution is available */
  resolution?: { width: number; height: number };
  /** Frames per second */
  fps?: number;
  /** Window that was being recorded */
  window?: { app?: string; pid?: number; title?: string };
  /** Path to GIF export, if /export was called */
  gif_path?: string;
}

/** Matches GIFExporter.ExportResult.asDictionary() */
export interface ExportResult {
  path: string;
  format: "gif" | "webp";
  width: number;
  height: number;
  /** Number of frames in the exported animation */
  frames: number;
  fps: number;
  /** Duration of the exported clip in seconds */
  duration: number;
  /** File size in bytes */
  size: number;
  /** File size in megabytes (2 decimal places) */
  size_mb: number;
}

/** Matches VideoTrimmer.TrimResult.asDictionary() */
export interface TrimResult {
  path: string;
  /** Duration of the source video before trimming (seconds, 1 decimal place) */
  original_duration: number;
  /** Duration of the trimmed output (seconds, 1 decimal place) */
  trimmed_duration: number;
  /** Start time used for the trim (seconds) */
  start: number;
  /** End time used for the trim (seconds) */
  end: number;
  /** File size in bytes */
  size: number;
  /** File size in megabytes (2 decimal places) */
  size_mb: number;
}

export interface StartResult {
  session_id: string;
  status: "recording";
  name: string;
  quality: string;
  window_title?: string;
  window_pid?: number;
}

export interface HealthResult {
  ok: boolean;
  version: string;
  listener: "ready" | "setup" | "waiting" | "failed" | "cancelled" | "nil" | "unknown";
  port: number;
  /** Number of currently open connections to the server */
  active_connections: number;
  /** Permission status for macOS capabilities */
  permissions: {
    screen_recording: boolean;
  };
  /** Present when a non-fatal issue is detected (e.g. missing permissions, high connection count) */
  warning?: string;
}

// ── Client ────────────────────────────────────────────────────────────────────

export interface ScreenMuseOptions {
  host?: string;
  port?: number;
  /**
   * API key for X-ScreenMuse-Key header.
   * Defaults to:
   *   1. SCREENMUSE_API_KEY env var
   *   2. ~/.screenmuse/api_key file
   *   3. undefined (requests will get 401 if server has auth enabled)
   */
  apiKey?: string;
}

export class ScreenMuse {
  private baseUrl: string;
  private apiKey: string | undefined;

  constructor(options: ScreenMuseOptions = {}) {
    const host = options.host ?? "localhost";
    const port = options.port ?? 7823;
    this.baseUrl = `http://${host}:${port}`;
    this.apiKey = options.apiKey ?? loadApiKey();
  }

  private headers(extra?: Record<string, string>): Record<string, string> {
    const h: Record<string, string> = { "Content-Type": "application/json" };
    if (this.apiKey) h["X-ScreenMuse-Key"] = this.apiKey;
    return { ...h, ...extra };
  }

  private async request<T>(
    method: string,
    endpoint: string,
    body?: Record<string, unknown>
  ): Promise<T> {
    const r = await fetch(`${this.baseUrl}${endpoint}`, {
      method,
      headers: this.headers(),
      body: body ? JSON.stringify(body) : undefined,
    });
    const json = await r.json() as T & { error?: string };
    if (!r.ok) {
      throw new Error(
        `ScreenMuse API error ${r.status} on ${method} ${endpoint}: ${
          json.error ?? r.statusText
        }`
      );
    }
    return json;
  }

  // ── Health ──────────────────────────────────────────────────────────────────

  async health(): Promise<HealthResult> {
    // /health requires no auth
    const r = await fetch(`${this.baseUrl}/health`);
    return r.json();
  }

  // ── Recording ───────────────────────────────────────────────────────────────

  async start(options: {
    name?: string;
    windowTitle?: string;
    windowPid?: number;
    quality?: "low" | "medium" | "high" | "max";
    region?: { x?: number; y?: number; width: number; height: number };
    audioSource?: "system" | "none";
    webhook?: string;
  } = {}): Promise<StartResult> {
    const body: Record<string, unknown> = {};
    if (options.name) body.name = options.name;
    if (options.windowTitle) body.window_title = options.windowTitle;
    if (options.windowPid) body.window_pid = options.windowPid;
    if (options.quality) body.quality = options.quality;
    if (options.region) body.region = options.region;
    if (options.audioSource) body.audio_source = options.audioSource;
    if (options.webhook) body.webhook = options.webhook;
    return this.request("POST", "/start", body);
  }

  async stop(): Promise<RecordingResult> {
    return this.request("POST", "/stop");
  }

  /** Returns { status: "paused", elapsed } — actual server response shape */
  async pause(): Promise<{ status: "paused"; elapsed: number }> {
    return this.request("POST", "/pause");
  }

  /** Returns { status: "recording", elapsed } — actual server response shape */
  async resume(): Promise<{ status: "recording"; elapsed: number }> {
    return this.request("POST", "/resume");
  }

  async status(): Promise<RecordingStatus> {
    return this.request("GET", "/status");
  }

  async markChapter(name: string): Promise<void> {
    await this.request("POST", "/chapter", { name });
  }

  async addNote(text: string): Promise<void> {
    await this.request("POST", "/note", { text });
  }

  async highlightNextClick(): Promise<void> {
    await this.request("POST", "/highlight");
  }

  async screenshot(outputPath?: string): Promise<{ path: string; width: number; height: number; size: number }> {
    const body: Record<string, unknown> = {};
    // Server reads body["path"] — not "output_path"
    if (outputPath) body.path = outputPath;
    return this.request("POST", "/screenshot", body);
  }

  // ── Export ──────────────────────────────────────────────────────────────────

  async export(options: {
    format: "gif" | "webp";
    source?: string;
    fps?: number;
    scale?: number;
    quality?: number;
    start?: number;
    end?: number;
    output?: string;
  }): Promise<ExportResult> {
    return this.request("POST", "/export", options as Record<string, unknown>);
  }

  async trim(options: {
    start: number;
    end: number;
    source?: string;
    output?: string;
    fastCopy?: boolean;
  }): Promise<TrimResult> {
    const body: Record<string, unknown> = {
      start: options.start,
      end: options.end,
    };
    if (options.source) body.source = options.source;
    if (options.output) body.output = options.output;
    if (options.fastCopy !== undefined) body.fast_copy = options.fastCopy;
    return this.request("POST", "/trim", body);
  }

  // ── Convenience: record + export in one call ────────────────────────────────

  /** Start recording, call fn(), stop, optionally export GIF. Returns the stop result. */
  async record(
    fn: () => Promise<void>,
    options: {
      name?: string;
      gif?: boolean;
      gifScale?: number;
      quality?: "low" | "medium" | "high" | "max";
    } = {}
  ): Promise<RecordingResult & { gif_path?: string }> {
    await this.start({ name: options.name, quality: options.quality });
    try {
      await fn();
    } finally {
      // stop even if fn() throws
    }
    const result = await this.stop();
    if (options.gif) {
      const gif = await this.export({ format: "gif", scale: options.gifScale ?? 800 });
      return { ...result, gif_path: gif.path };
    }
    return result;
  }
}

// ── API key loader ─────────────────────────────────────────────────────────────

function loadApiKey(): string | undefined {
  // 1. Environment variable
  if (process.env.SCREENMUSE_API_KEY) return process.env.SCREENMUSE_API_KEY;
  if (process.env.SCREENMUSE_NO_AUTH === "1") return undefined;

  // 2. ~/.screenmuse/api_key file
  const keyFile = path.join(os.homedir(), ".screenmuse", "api_key");
  try {
    if (fs.existsSync(keyFile)) {
      const key = fs.readFileSync(keyFile, "utf8").trim();
      if (key) return key;
    }
  } catch {
    // ignore read errors
  }

  return undefined;
}

export default ScreenMuse;
