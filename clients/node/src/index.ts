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

export interface OcrResult {
  text: string;
  words?: Array<{
    text: string;
    confidence: number;
    bounds: { x: number; y: number; width: number; height: number };
  }>;
  source?: string;
}

export interface SpeedRampResult {
  path: string;
  duration: number;
  size: number;
  size_mb: number;
  segments_applied: number;
}

export interface ConcatResult {
  path: string;
  duration: number;
  size: number;
  size_mb: number;
  segments: number;
}

export interface CropResult {
  path: string;
  width: number;
  height: number;
  size: number;
  size_mb: number;
}

export interface AnnotateResult {
  path: string;
  annotations_applied: number;
  size: number;
  size_mb: number;
}

export interface ThumbnailResult {
  path: string;
  width: number;
  height: number;
  size: number;
  time: number;
}

export interface FramesResult {
  paths: string[];
  count: number;
  fps: number;
  duration: number;
}

export interface FrameResult {
  path: string;
  width: number;
  height: number;
  time: number;
}

export interface WindowInfo {
  app: string;
  title: string;
  pid: number;
  bounds?: { x: number; y: number; width: number; height: number };
  isActive?: boolean;
}

export interface ActiveWindowResult {
  app: string;
  title: string;
  pid: number;
  bounds?: { x: number; y: number; width: number; height: number };
}

export interface ClipboardResult {
  text: string;
  type: string;
}

export interface RunningApp {
  name: string;
  pid: number;
  bundleId?: string;
  isActive?: boolean;
}

export interface TimelineResult {
  elapsed: number;
  chapters: Array<{ name: string; time: number }>;
  notes: Array<{ text: string; time: number }>;
  highlights: Array<{ time: number }>;
}

export interface RecordingInfo {
  filename: string;
  path: string;
  size: number;
  duration?: number;
  created_at?: string;
}

export interface SessionInfo {
  id: string;
  name: string;
  isRecording: boolean;
  videoPath?: string;
  chapters: Array<{ name: string; time: number }>;
}

export interface VersionResult {
  version: string;
  build?: string;
}

export interface ValidateResult {
  ok: boolean;
  path: string;
  duration: number;
  resolution?: { width: number; height: number };
  fps?: number;
  size: number;
  size_mb: number;
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

  async ocr(options: { source?: string } = {}): Promise<OcrResult> {
    const body: Record<string, unknown> = {};
    if (options.source) body.source = options.source;
    return this.request("POST", "/ocr", body);
  }

  async speedramp(options: {
    segments: Array<{ start: number; end: number; speed: number }>;
    source?: string;
    output?: string;
  }): Promise<SpeedRampResult> {
    const body: Record<string, unknown> = { segments: options.segments };
    if (options.source) body.source = options.source;
    if (options.output) body.output = options.output;
    return this.request("POST", "/speedramp", body);
  }

  async concat(options: {
    sources: string[];
    output?: string;
    crossfade?: number;
  }): Promise<ConcatResult> {
    const body: Record<string, unknown> = { sources: options.sources };
    if (options.output) body.output = options.output;
    if (options.crossfade !== undefined) body.crossfade = options.crossfade;
    return this.request("POST", "/concat", body);
  }

  async crop(options: {
    x: number;
    y: number;
    width: number;
    height: number;
    source?: string;
    output?: string;
  }): Promise<CropResult> {
    const body: Record<string, unknown> = {
      x: options.x,
      y: options.y,
      width: options.width,
      height: options.height,
    };
    if (options.source) body.source = options.source;
    if (options.output) body.output = options.output;
    return this.request("POST", "/crop", body);
  }

  async annotate(options: {
    texts: Array<{
      text: string;
      time: number;
      x?: number;
      y?: number;
      duration?: number;
      color?: string;
      fontSize?: number;
    }>;
    source?: string;
    output?: string;
  }): Promise<AnnotateResult> {
    const body: Record<string, unknown> = { texts: options.texts };
    if (options.source) body.source = options.source;
    if (options.output) body.output = options.output;
    return this.request("POST", "/annotate", body);
  }

  async thumbnail(options: {
    time?: number;
    source?: string;
    output?: string;
  } = {}): Promise<ThumbnailResult> {
    const body: Record<string, unknown> = {};
    if (options.time !== undefined) body.time = options.time;
    if (options.source) body.source = options.source;
    if (options.output) body.output = options.output;
    return this.request("POST", "/thumbnail", body);
  }

  async frames(options: {
    source?: string;
    fps?: number;
    output_dir?: string;
    format?: "png" | "jpg";
    max?: number;
  } = {}): Promise<FramesResult> {
    const body: Record<string, unknown> = {};
    if (options.source) body.source = options.source;
    if (options.fps !== undefined) body.fps = options.fps;
    if (options.output_dir) body.output_dir = options.output_dir;
    if (options.format) body.format = options.format;
    if (options.max !== undefined) body.max = options.max;
    return this.request("POST", "/frames", body);
  }

  async frame(options: { source?: string; output?: string } = {}): Promise<FrameResult> {
    const body: Record<string, unknown> = {};
    if (options.source) body.source = options.source;
    if (options.output) body.output = options.output;
    return this.request("POST", "/frame", body);
  }

  async validate(filePath: string): Promise<ValidateResult> {
    return this.request("POST", "/validate", { path: filePath });
  }

  // ── System & windows ────────────────────────────────────────────────────────

  async windows(): Promise<WindowInfo[]> {
    return this.request("GET", "/windows");
  }

  async focusWindow(options: { app?: string; pid?: number; title?: string }): Promise<{ ok: boolean; app?: string }> {
    const body: Record<string, unknown> = {};
    if (options.app) body.app = options.app;
    if (options.pid !== undefined) body.pid = options.pid;
    if (options.title) body.title = options.title;
    return this.request("POST", "/window/focus", body);
  }

  async positionWindow(options: {
    app?: string;
    pid?: number;
    x?: number;
    y?: number;
    width?: number;
    height?: number;
  }): Promise<{ ok: boolean }> {
    const body: Record<string, unknown> = {};
    if (options.app) body.app = options.app;
    if (options.pid !== undefined) body.pid = options.pid;
    if (options.x !== undefined) body.x = options.x;
    if (options.y !== undefined) body.y = options.y;
    if (options.width !== undefined) body.width = options.width;
    if (options.height !== undefined) body.height = options.height;
    return this.request("POST", "/window/position", body);
  }

  async hideOthers(options: { app?: string; pid?: number }): Promise<{ ok: boolean; hidden: number }> {
    const body: Record<string, unknown> = {};
    if (options.app) body.app = options.app;
    if (options.pid !== undefined) body.pid = options.pid;
    return this.request("POST", "/window/hide-others", body);
  }

  async activeWindow(): Promise<ActiveWindowResult> {
    return this.request("GET", "/system/active-window");
  }

  async clipboard(): Promise<ClipboardResult> {
    return this.request("GET", "/system/clipboard");
  }

  async runningApps(): Promise<RunningApp[]> {
    return this.request("GET", "/system/running-apps");
  }

  // ── Timeline & sessions ─────────────────────────────────────────────────────

  async timeline(): Promise<TimelineResult> {
    return this.request("GET", "/timeline");
  }

  async recordings(): Promise<RecordingInfo[]> {
    return this.request("GET", "/recordings");
  }

  /** @param filename Basename only (e.g. "demo.mp4"), not a full path. */
  async deleteRecording(filename: string): Promise<{ ok: boolean; filename: string }> {
    return this.request("DELETE", "/recording", { filename });
  }

  async sessions(): Promise<SessionInfo[]> {
    return this.request("GET", "/sessions");
  }

  async getSession(sessionId: string): Promise<SessionInfo> {
    return this.request("GET", `/session/${sessionId}`);
  }

  async deleteSession(sessionId: string): Promise<{ ok: boolean }> {
    return this.request("DELETE", `/session/${sessionId}`);
  }

  async version(): Promise<VersionResult> {
    return this.request("GET", "/version");
  }

  // ── Scripting ─────────────────────────────────────────────────────────────────

  /**
   * Run a sequence of recording commands as a batch script.
   * Valid actions: start, stop, chapter, highlight, note, screenshot, sleep.
   * @example
   * await sm.script([
   *   { action: "start", name: "demo" },
   *   { sleep: 3 },
   *   { action: "chapter", name: "Key moment" },
   *   { action: "stop" },
   * ]);
   */
  async script(commands: Array<Record<string, unknown>>): Promise<{
    ok: boolean;
    steps_run: number;
    steps: Array<{ action?: string; ok: boolean; error?: string }>;
    error?: string;
  }> {
    return this.request("POST", "/script", { commands });
  }

  /**
   * Run multiple named scripts in sequence.
   * @param scripts Array of { name, commands[] } objects.
   * @param continueOnError If true, continue past failures.
   */
  async scriptBatch(
    scripts: Array<{ name?: string; commands: Array<Record<string, unknown>> }>,
    continueOnError = false
  ): Promise<{
    ok: boolean;
    scripts_run: number;
    scripts: Array<{ name: string; ok: boolean; steps_run: number; steps: unknown[] }>;
  }> {
    const body: Record<string, unknown> = { scripts };
    if (continueOnError) body.continue_on_error = true;
    return this.request("POST", "/script/batch", body);
  }

  // ── System info ─────────────────────────────────────────────────────────────

  /** Get a session report with summary statistics. */
  async report(): Promise<Record<string, unknown>> {
    return this.request("GET", "/report");
  }

  /** Get debug info about the server state (save_directory, active_connections, etc.). */
  async debug(): Promise<Record<string, unknown>> {
    return this.request("GET", "/debug");
  }

  /** Get recent server log entries. Returns { entries, count }. */
  async logs(): Promise<{ entries: Array<{ level: string; message: string; timestamp: string }>; count: number }> {
    return this.request("GET", "/logs");
  }

  // ── Jobs ────────────────────────────────────────────────────────────────────

  /** List all background async jobs and their status. */
  async jobs(): Promise<{ jobs: Array<{ id: string; status: string; progress?: number }>; count: number }> {
    return this.request("GET", "/jobs");
  }

  /** Get status and result for a specific background job by ID. */
  async getJob(jobId: string): Promise<{ id: string; status: string; progress?: number; result?: unknown; error?: string }> {
    return this.request("GET", `/job/${jobId}`);
  }

  // ── Streaming ────────────────────────────────────────────────────────────────

  /** Get SSE stream status (active_clients, total_frames_sent). */
  async streamStatus(): Promise<{ active_clients: number; total_frames_sent: number }> {
    return this.request("GET", "/stream/status");
  }

  // ── PiP ─────────────────────────────────────────────────────────────────────

  /** Start Picture-in-Picture mode. @param source Video path or "last". */
  async startPip(source?: string): Promise<{ ok: boolean; source?: string }> {
    return this.request("POST", "/start/pip", source ? { source } : {});
  }

  // ── Upload ───────────────────────────────────────────────────────────────────

  /**
   * Upload a recording to iCloud Drive.
   * @param source Video path or "last" for the most recent recording.
   * @param folder iCloud folder name (default: "ScreenMuse").
   */
  async uploadIcloud(source = "last", folder?: string): Promise<{ ok: boolean; path?: string; icloud_path?: string }> {
    const body: Record<string, unknown> = { source };
    if (folder) body.folder = folder;
    return this.request("POST", "/upload/icloud", body);
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

  // ── Publish ────────────────────────────────────────────────────────────────

  /**
   * Publish a recording to an external destination.
   *
   * Three built-in destinations:
   *   - `slack`    — POST a notification to an incoming-webhook URL
   *   - `http_put` (aliases: `s3`, `r2`, `gcs`) — PUT file bytes to a
   *                 presigned upload URL (caller signs the URL, we upload)
   *   - `webhook`  — POST a JSON metadata envelope to any URL
   */
  async publish(options: {
    url: string;
    destination?: "slack" | "http_put" | "s3" | "r2" | "gcs" | "webhook";
    source?: string;
    headers?: Record<string, string>;
    metadata?: Record<string, string | number | boolean>;
    apiToken?: string;
    filename?: string;
    timeout?: number;
    async?: boolean;
  }): Promise<PublishResult> {
    const body: Record<string, unknown> = {
      url: options.url,
      destination: options.destination ?? "webhook",
    };
    if (options.source !== undefined) body.source = options.source;
    if (options.headers !== undefined) body.headers = options.headers;
    if (options.metadata !== undefined) body.metadata = options.metadata;
    if (options.apiToken !== undefined) body.api_token = options.apiToken;
    if (options.filename !== undefined) body.filename = options.filename;
    if (options.timeout !== undefined) body.timeout = options.timeout;
    if (options.async) body.async = true;
    return this.request("POST", "/publish", body);
  }

  // ── AI Narration ───────────────────────────────────────────────────────────

  /**
   * Generate AI narration + chapter suggestions for an existing recording.
   *
   * Defaults to local Ollama (requires `ollama serve` running at
   * http://localhost:11434) so agent loops are zero-cost and fully offline.
   * Switch `provider: "anthropic"` to use Claude instead.
   */
  async narrate(options: {
    source?: string;
    provider?: "ollama" | "anthropic";
    model?: string;
    frameCount?: number;
    maxChapters?: number;
    style?: "technical" | "casual" | "tutorial";
    language?: string;
    temperature?: number;
    apiKey?: string;
    endpoint?: string;
    save?: boolean;
    async?: boolean;
  } = {}): Promise<NarrationResult> {
    const body: Record<string, unknown> = {};
    if (options.source !== undefined) body.source = options.source;
    if (options.provider !== undefined) body.provider = options.provider;
    if (options.model !== undefined) body.model = options.model;
    if (options.frameCount !== undefined) body.frame_count = options.frameCount;
    if (options.maxChapters !== undefined) body.max_chapters = options.maxChapters;
    if (options.style !== undefined) body.style = options.style;
    if (options.language !== undefined) body.language = options.language;
    if (options.temperature !== undefined) body.temperature = options.temperature;
    if (options.apiKey !== undefined) body.api_key = options.apiKey;
    if (options.endpoint !== undefined) body.endpoint = options.endpoint;
    if (options.save !== undefined) body.save = options.save;
    if (options.async) body.async = true;
    return this.request("POST", "/narrate", body);
  }

  // ── Browser (Playwright) ───────────────────────────────────────────────────

  /**
   * Record a Chromium window driven by Playwright.
   *
   * Spawns a Node subprocess (installed via `browserInstall()`) that launches
   * a headful Chromium window at the given URL, optionally runs a user
   * script in page context, and records the window with the standard
   * ScreenMuse capture pipeline.
   *
   * Returns the enriched stop response plus a `browser` block with the
   * final URL, window title, PID, exit code, and any script/nav errors.
   *
   * Throws if POST /browser/install has not been called yet.
   */
  async browser(options: {
    url: string;
    durationSeconds: number;
    script?: string;
    width?: number;
    height?: number;
    name?: string;
    quality?: "low" | "medium" | "high" | "max";
    async?: boolean;
  }): Promise<RecordingResult & { browser: BrowserResult }> {
    const body: Record<string, unknown> = {
      url: options.url,
      duration_seconds: options.durationSeconds,
    };
    if (options.script !== undefined) body.script = options.script;
    if (options.width !== undefined) body.width = options.width;
    if (options.height !== undefined) body.height = options.height;
    if (options.name !== undefined) body.name = options.name;
    if (options.quality !== undefined) body.quality = options.quality;
    if (options.async) body.async = true;
    return this.request("POST", "/browser", body);
  }

  /**
   * Install the Playwright runner (Node + Chromium) on first use.
   * Idempotent. The first call downloads ~130MB and can take a couple
   * of minutes on a cold cache — defaults to async so you can poll
   * GET /job/{id} while it runs.
   */
  async browserInstall(options: { async?: boolean } = { async: true }): Promise<BrowserInstallResult | JobResult> {
    const body: Record<string, unknown> = {};
    if (options.async !== false) body.async = true;
    return this.request("POST", "/browser/install", body);
  }

  /**
   * Inspect the Playwright runner install without triggering one.
   */
  async browserStatus(): Promise<BrowserInstallResult> {
    return this.request("GET", "/browser/status");
  }
}

// ── Browser result types ─────────────────────────────────────────────────────

export interface BrowserResult {
  url_requested: string;
  url_final: string;
  title: string;
  pid: number;
  duration_ms: number;
  exit_code: number;
  elapsed_ms: number;
  nav_error?: string;
  script_error?: string;
}

export interface BrowserInstallResult {
  runner_directory: string;
  runner_script_exists: boolean;
  runner_script_version: string;
  playwright_installed: boolean;
  node_path: string;
  npm_path: string;
  ready: boolean;
}

export interface JobResult {
  job_id: string;
  status: "pending" | "running" | "completed" | "failed";
  poll: string;
}

// ── Publish result types ────────────────────────────────────────────────────

export interface PublishResult {
  destination: "slack" | "http_put" | "webhook" | string;
  url: string;
  status_code: number;
  response_body: string;
  bytes_sent: number;
  source: string;
  request_id?: number;
}

// ── Narration result types ──────────────────────────────────────────────────

export interface NarrationEntry {
  time: number;
  text: string;
}

export interface ChapterSuggestion {
  time: number;
  name: string;
}

export interface NarrationResult {
  narration: NarrationEntry[];
  suggested_chapters: ChapterSuggestion[];
  provider: "ollama" | "anthropic" | string;
  model: string;
  frames_used: number;
  source: string;
  narration_file?: string;
  request_id?: number;
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
