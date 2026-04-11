# Changelog

All notable changes to ScreenMuse are documented here.

## [Unreleased] — 2026-04-11 Sprint 4

### Added
- **`GET /metrics`** — Prometheus-format exposition endpoint. Counts HTTP requests by `(method, route, status)`, emits gauges for `screenmuse_active_recordings`, `screenmuse_active_connections`, `screenmuse_jobs_{pending,running,completed,failed}`, `screenmuse_disk_free_bytes`, `screenmuse_uptime_seconds`, and a constant `screenmuse_info{version="…"} 1` gauge. Paths with ephemeral IDs (`/job/abc123`, `/session/xyz`) are canonicalized to `/job/:id` and `/session/:id` to bound label cardinality.
- **`MetricsRegistry` actor** — thread-safe counter store with Prometheus text rendering, stable sort order, and label escaping per exposition-format spec.
- **`DiskSpaceGuard`** — pre-flight check that refuses `/start`, `/record`, and `/browser` when free disk space falls below `defaultMinFreeBytes` (2 GB). Returns a structured 507 Insufficient Storage response with `code: DISK_SPACE_LOW`, `free_bytes`, `required_bytes`, and a `suggestion`. Uses `.volumeAvailableCapacityForImportantUsage` (the number Finder shows) so reclaimable/purgeable storage counts. Can be swapped out per test via `ScreenMuseServer.diskSpaceGuard`.
- **`DiskSpaceGuardTests`** — 12 tests covering the pure decision machine, error body shape, `freeBytes` filesystem integration, and the `formatBytes` pretty-printer.
- **`MetricsRegistryTests`** — 14 tests for canonicalization, label escaping, gauge formatting, counter aggregation, and Prometheus rendering (including stable sort order).
- **`ResilienceTests`** — 8 integration tests on a dedicated port 7826: `/metrics` exposition shape, `Content-Type: text/plain` header, disk-space-guard refusal on `/start` / `/record` / `/browser`, 50× concurrent unknown-route flood returns all 404s, and 20× concurrent `/status` requests produce an accurate total counter.
- OpenAPI `/metrics` entry + drift test.

### Changed
- `ScreenMuseServer.sendResponse()` now records `(method, route, status)` into `MetricsRegistry` as a fire-and-forget Task, so the hot path stays non-blocking but every response increments a counter.
- `handleStart`, `handleRecord`, and `handleBrowser` each call `diskSpaceGuardCheck()` before mutating state, returning 507 cleanly on low disk.

### Added
- **`POST /narrate`** — AI narration + chapter suggestions for an existing recording. Extracts N frames evenly across the video (skipping first/last 1% to avoid fades), JPEG-encodes them, and calls a vision LLM. Two built-in providers:
  - **Ollama** (default) — local, zero-cost, zero-config. Uses `llava:7b` by default. Resolves `$OLLAMA_HOST` or `http://localhost:11434`. Works offline; nothing leaves the machine.
  - **Claude** (Anthropic) — `claude-sonnet-4-6` default. Reads `ANTHROPIC_API_KEY` env var or per-request `api_key` field.
  - Pluggable via `NarrationProvider` protocol — custom providers can be registered.
- **Strict JSON schema prompt** with fence-stripping + embedded-JSON extraction so providers that wrap their reply in prose still parse cleanly.
- Writes `{stem}.narration.json` beside the source video by default, so the artifact becomes part of the recording's folder.
- **Narration result is part of the JobQueue**: pass `async: true` to run via `/job/{id}` and poll for completion.
- **`NarrationTests`** — 22 tests covering provider factory, prompt parsing (raw + fenced + embedded), URL resolution (default/env/override), error propagation, and Codable round-trip.
- **Python client**: `client.narrate(source, provider, model, frame_count, …)` on `ScreenMuseClient`.
- **Node/TS client**: `client.narrate({source, provider, model, frameCount, …})` plus `NarrationResult`, `NarrationEntry`, and `ChapterSuggestion` types.
- OpenAPI spec entry for `/narrate`. `OpenAPISpecDriftTests` updated.

- **`POST /browser`** — headless Playwright recording. Spawns a Node subprocess that launches a headful Chromium window at the requested URL, optionally runs a user script in page context (`page`, `context`, `browser` in scope), and records the window through the standard ScreenMuse capture pipeline. Returns the enriched stop response plus a `browser` block with `url_requested`, `url_final`, `title`, `pid`, `exit_code`, and any `script_error`/`nav_error`. Honors `duration_seconds` (1–600), `width`, `height`, `name`, `quality`, and `async`.
- **`POST /browser/install`** — idempotent installer that writes `~/.screenmuse/playwright-runner/` and runs `npm install` + `npx playwright install chromium`. First install downloads ~130MB. Supports `async=true` for job-queue execution.
- **`GET /browser/status`** — inspects the runner install without triggering anything: `runner_directory`, `runner_script_exists`, `runner_script_version`, `playwright_installed`, `node_path`, `npm_path`, `ready`.
- **`Browser/`** subdirectory in `ScreenMuseCore`: `RunnerScript.swift` (embedded Node source), `NodeRunnerInstaller.swift` (filesystem + npm orchestration), `BrowserRecorder.swift` (subprocess lifecycle + SM: line-protocol parser + `EventBox` primitive).
- **`BrowserHandlerTests`** — 27 tests covering request validation, config JSON encoding, installer status, PATH lookup, runner script integrity, and the `EventBox` async primitive.
- **Python client**: `browser()`, `browser_install()`, `browser_status()` methods on `ScreenMuseClient`.
- **Node/TS client**: `browser()`, `browserInstall()`, `browserStatus()` plus `BrowserResult`, `BrowserInstallResult`, `JobResult` types.
- OpenAPI spec entries for `/browser`, `/browser/install`, `/browser/status`. `OpenAPISpecDriftTests` updated with the three new paths.

### Design notes
- The Swift binary remains **zero external dependencies**. Node + Playwright live entirely under `~/.screenmuse/playwright-runner/`, installed on-demand, so users who don't use `/browser` never download anything.
- Headless mode is explicitly rejected (`HEADLESS_NOT_SUPPORTED`) — browser recording requires a visible Chromium window for macOS-level screen capture to see it. Playwright's internal video recording would defeat the purpose of using ScreenMuse.
- The Node runner speaks a minimal line-based protocol on stdout (`SM:READY`, `SM:SCRIPT_OK`, `SM:DONE`, etc.) so Swift can coordinate the recording lifecycle with the browser lifecycle. Swift writes `GO\n` to the runner's stdin after starting the recording, so the user script never runs against an unrecorded frame.

## [Unreleased] — 2026-04-04 Sprint 3

### Added
- **Request ID in every response** — `sendResponse()` now automatically injects `"request_id"` into every JSON response body. No callsite changes — threaded through the single choke point. Enables distributed tracing for agent workflows.
- **`POST /qa`** — HTTP API for QA analysis. Pass `original` + `processed` video paths, get back the full `QAReport` JSON (5 quality checks, confidence score, before/after metrics). Optional `save` param (default true) saves `qa-report.json` beside processed video.
- **`POST /diff`** — Structural diff between any two video files. Returns metadata for both + delta (duration, file size, bitrate, resolution changed, fps changed, codec changed).
- **Baseline QA for no-effects recordings** — When recording without effects (no before/after to compare), ffprobe validity check runs in background; surfaces error if output is corrupted.
- **`RecordingsPaginationTests`** — 22 tests covering limit/offset/sort/hasMore logic, edge cases, and full-pagination consistency (paging through all 23 items in 5-item pages).
- **Codable types** for `/qa` (`QARequest`) and `/diff` (`DiffRequest`, `DiffResponse`).
- **OpenAPI spec** updated with `/qa` and `/diff` endpoint definitions.

## [Unreleased] — 2026-04-04 Sprint 2 (QA Engine)

### Added
- `GET /recordings` now supports pagination: `?limit=N&offset=N&sort=asc|desc`. Response includes `total`, `count`, `limit`, `offset`, `has_more` fields. Backward-compatible (no params = return all).
- **Python client**: 10 new methods for full API coverage — `script()`, `script_batch()`, `report()`, `debug()`, `logs()`, `jobs()`, `get_job()`, `stream_status()`, `start_pip()`, `upload_icloud()`. All with docstrings.
- **TypeScript/Node.js client**: Same 10 new methods with full JSDoc type annotations.
- **Codable types** in `APITypes.swift` for `TrimRequest`, `SpeedRampRequest`, `ChapterRequest`, `HighlightResponse`, `NoteRequest`.
- **`ScreenMuseConfigTests`** — 18 new tests for config file round-trip, defaults, tilde expansion.
- **HTTP route tests** for `POST /record` and `POST /script/batch` dispatch table coverage.

### Verified (no changes needed)
- 65KB body limit: already fixed via `accumulateBody()` + `receiveNextChunk()` streaming pattern with 4MB cap.
- Port configurability: fully implemented via `SCREENMUSE_PORT` env, `~/.screenmuse/config.json`, and `--port` CLI flag.
- Config file support: `ScreenMuseConfig` at `~/.screenmuse.json` supports all 6 fields.
- OpenAPI spec audit: 47/47 paths in spec match router dispatch table — zero drift.
- Demo tape: `docs/demo.tape` and `docs/CONTRIBUTING-DEMO.md` already exist.

### Research
- Landscape: Screenpipe (main competitor) runs as MCP server with passive capture. Mux (Jan 2026) added AI narration. Community building screenshot+narration MCP tools for monitoring diffs and auto-documentation.
- New backlog items added: `POST /browser` (headless Playwright), `POST /narrate` (AI narration), `POST /diff` (change detection), `POST /publish` (multi-destination), continuous capture mode.

## [1.6.0] — 2026-03-25

### Added
- `POST /validate` — run quality checks on a recording (duration, frame count, no black frames, text-at-time OCR)
- `POST /frames` — extract multiple frames from a video at given timestamps (PNG or JPG)
- `screenmuse-playwright`: smart PID fallback via `/windows` when `browser.process().pid` returns null on macOS
- `screenmuse-playwright`: public `findBrowserWindow()` helper for manual browser window discovery
- OCR debug mode — pass `"debug": true` to `/ocr` for image size, upscale info, block count, and avg confidence

### Fixed
- `/stop` now returns enriched response: path, duration, size, size_mb, resolution, fps, chapters, notes, session_id, window info — never returns undefined
- OCR auto-upscale: images < 1000px wide are upscaled to 1440px before Vision API for better accuracy on small frames/GIFs

### Changed
- `screenmuse-playwright` README rewritten with installation, troubleshooting (multiple Chrome windows, GitHub virtual scrolling, PID null, window not found), Playwright Test fixture integration, and full API reference

## [1.5.5] — 2026-03-24

### Fixed
- OCR endpoint: strip control characters from Vision results before JSON serialization (prevents 500 on scans with null bytes)
- Smoke test threshold raised to 40 — was failing on fast machines
- Export test added to CI smoke suite

## [1.5.4] — 2026-03-24

### Fixed
- `ThumbnailExtractor`: CFString cast crash on certain video codecs

## [1.5.3] — 2026-03-24

### Fixed
- OpenAPI spec moved to JSON string literal — bracket escaping issue caused malformed spec on some endpoints

## [1.5.2] — 2026-03-24

### Fixed
- `/ocr` endpoint: bracket mismatch in response builder
- `capturedNotes` compiler warning resolved

## [1.5.1] — 2026-03-24

### Fixed
- `/script` endpoint: async autoclosure errors under Swift 6 strict concurrency
- Unused variable warnings cleaned up

## [1.5.0] — 2026-03-24

### Added
- `packages/screenmuse-playwright` — npm package for recording Playwright automation sessions. Zero boilerplate: `sm.record(async () => { ... })` wraps focus, window position, hide-others, start, and stop. Works as a Playwright Test fixture or standalone helper.
- `examples/playwright-demo/` — runnable demo showing how to record a browser automation session end-to-end

## [1.4.0] — 2026-03-24

### Added
- `POST /note` — drop a timestamped note into the usage log mid-recording (e.g. "audio dropped here")
- `POST /script` and `POST /script/batch` — run shell commands mid-session; batch runs a list in order
- `GET /annotate` — retrieve all notes from the current session
- MCP server (`mcp-server/`) — exposes ScreenMuse tools to Claude Desktop and Cursor via the Model Context Protocol

## [1.3.0] — 2026-03-24

### Added
- `POST /ocr` — on-device OCR via Apple Vision (no API key, macOS 14+). Read text from screen or an image file. Supports `fast` and `accurate` modes.
- `POST /thumbnail` — extract a single frame from the last recording at a given timecode
- `POST /crop` — crop a rectangular region from the last recording
- `GET /openapi` — machine-readable OpenAPI spec (JSON). Use with Postman, Claude, Cursor, or any OpenAPI-compatible tool.

## [1.2.0] — 2026-03-24

### Added
- Region recording — pass `region: {x, y, width, height}` to `POST /start` to record a specific area of the screen
- Webhooks — pass `webhook: "https://..."` to `POST /start` to get a POST callback with video path when recording stops
- `GET /timeline` — structured JSON of all chapters, highlights, and notes (live or after stop)
- `POST /concat` — combine two or more recordings into one. Use `"last"` to reference the most recent file.

## [1.1.0] — 2026-03-24

### Added
- `GET /stream` — SSE endpoint for real-time frame streaming (JPEG or PNG, configurable fps and scale). Stays open until client disconnects.
- `GET /stream/status` — shows active SSE client count

## [1.0.3] — 2026-03-24

### Fixed
- Smoke test threshold now matches actual endpoint count
- `/version` `endpoint_count` reflects true count (self-computing from endpoint array)

## [1.0.2] — 2026-03-24

### Fixed
- 4 build errors from Vera's v1.0.1 bug report (actor isolation, type mismatches)

## [1.0.1] — 2026-03-24

### Fixed
- Eliminated all `viewModel` references in `ScreenMuseServer` — server is now fully decoupled from SwiftUI

## [1.0.0] — 2026-03-24

### Added
- Multi-window / Picture-in-Picture recording — `POST /start/pip` records two windows simultaneously in PiP or side-by-side layout
- App-specific audio — pass `audio_source: "Google Chrome"` to record only one app's audio
- `GET /recordings` — list all recordings with file size and date metadata
- `DELETE /recording` — delete a recording by filename
- `POST /upload/icloud` — upload last (or any) recording to iCloud Drive → ScreenMuse folder

## [0.10.0] — 2026-03-24

### Added
- Multi-window PiP, app-specific audio, recordings management (pre-1.0 final batch)

## [0.9.0] — 2026-03-24

### Added
- `POST /upload/icloud` — iCloud Drive upload

## [0.8.0] — 2026-03-24

### Added
- `POST /frame` — recording-context-aware frame capture (captures from live stream when recording, otherwise takes a screenshot)

## [0.7.0] — 2026-03-24

### Added
- `POST /trim` — fast stream-copy trim (no re-encode, near instant). Pass `reencode: true` for frame-accurate trim.
- `POST /speedramp` — auto-speed idle pauses using cursor and keyboard event data. Configurable idle speed multiplier and threshold.

## [0.6.0] — 2026-03-24

### Added
- `POST /export` — animated GIF and WebP export via AVAssetImageGenerator + CGImageDestination. Configurable fps, scale, quality. Supports trim-on-export.

## [0.5.0] — 2026-03-24

### Added
- `POST /window/focus` — bring any app to the front by name (NSRunningApplication.activate, no permission required)
- `POST /window/position` — set window size and position via AXUIElement (requires Accessibility permission)
- `POST /window/hide-others` — hide all other apps for a clean recording desktop
- `GET /system/clipboard` — read current clipboard contents
- `GET /system/active-window` — which window has focus
- `GET /system/running-apps` — list of running applications
- Playwright integration example (`examples/playwright-demo/`)

## [0.4.0] — 2026-03-24

### Added
- `POST /note` (early version) — timestamped notes to usage log
- `GET /version` — version, build info, and full endpoint list
- Native macOS notification when video is ready (with file size)
- Finder reveal — finished video auto-selected in Finder on stop
- `ScreenMuseLogger` — structured logging with os.Logger, file sink, and ring buffer
- `GET /logs` — queryable log endpoint (filter by level, category, limit)
- `GET /report` — formatted session report for bug reports

### Fixed
- Moov atom corruption on stop-while-paused (stopCapture called on already-stopped stream)
- UserNotifications crash on ad-hoc signed binary (no bundle ID — graceful no-op now)

## [0.3.0] — 2026-03-24

### Added
- `POST /pause` and `POST /resume` — pause/resume recording mid-session
- OpenClaw skill installed at `clients/openclaw/SKILL.md`

## [0.2.0] — 2026-03-23

### Added
- Window capture — target a specific app window instead of full screen
- Quality presets (high / medium / low)
- `GET /windows` — list all on-screen windows
- Structured error responses

## [0.1.0] — 2026-03-23

### Added
- Agent API HTTP server on port 7823
- `POST /start`, `POST /stop`, `POST /chapter`, `POST /highlight`, `POST /screenshot`
- `GET /status`, `GET /debug`
- Click effects: ripple, glow, particleBurst, ring, sonar — composited onto video via Metal/Core Image
- Auto-zoom camera (spring easing, follows clicks)
- Cursor animation with motion blur and trail
- Keystroke overlay for tutorials
- Full-screen and region recording via ScreenCaptureKit (macOS 14+)
- H.264 video + AAC audio encoding via AVFoundation
- Python and Node.js client libraries (`clients/python`, `clients/node`)
