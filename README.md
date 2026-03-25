# ScreenMuse

**The screen recorder built for AI agents.**

ScreenMuse is a native macOS screen recorder that AI agents control via a local HTTP API on port 7823. Record demos, mark chapters, highlight clicks, export GIFs — all programmatically. No UI required.

Built on ScreenCaptureKit, AVFoundation, and Metal. Requires macOS 14 (Sonoma)+.

## Quick Start

```bash
git clone https://github.com/hnshah/screenmuse
cd screenmuse
./scripts/dev-run.sh
```

On first launch, macOS will prompt for Screen Recording permission. Grant it, then relaunch.

> **Use `dev-run.sh` or Xcode, not `swift build`.** Ad-hoc signed binaries get a new code signature hash on every rebuild. macOS TCC identifies apps by hash, so screen recording permission needs re-granting after each `swift build`. The script uses xcodebuild for a consistent signature. If permissions get stuck: `./scripts/reset-permissions.sh`

## Basic Usage

```bash
# Start recording
curl -X POST http://localhost:7823/start -H "Content-Type: application/json" \
  -d '{"name": "my-demo"}'

# Mark a chapter
curl -X POST http://localhost:7823/chapter -H "Content-Type: application/json" \
  -d '{"name": "Step 1"}'

# Highlight the next click (auto-zoom + enhanced effect)
curl -X POST http://localhost:7823/highlight

# Stop and get video path
curl -X POST http://localhost:7823/stop

# Export as GIF
curl -X POST http://localhost:7823/export -H "Content-Type: application/json" \
  -d '{"format": "gif", "fps": 10, "scale": 800}'
```

## Playwright Integration

`screenmuse-playwright` is a zero-boilerplate npm package for recording browser automation sessions. It detects the browser window, sets it up for clean recording, and wraps your Playwright code:

```bash
# From the packages/screenmuse-playwright directory:
npm install
```

```js
const { ScreenMuse } = require('screenmuse-playwright');

const sm = new ScreenMuse();

// Record any async block — focus, position, hide-others, start, stop all handled
const result = await sm.record(async (page) => {
  await page.goto('https://example.com');
  await page.click('button');
});

console.log(result.video_path);    // → /Users/you/Movies/ScreenMuse/recording.mp4
console.log(result.gif_path);      // → /Users/you/Movies/ScreenMuse/recording.gif (if gif: true)
```

See [`packages/screenmuse-playwright/`](packages/screenmuse-playwright/) for full docs and examples, including a Playwright Test fixture for automatic video proof on test failure.

## Pairing with Peekaboo

ScreenMuse records. [Peekaboo](https://github.com/steipete/Peekaboo) screenshots and reads the screen via OCR. They're designed to pair: use Peekaboo to read UI state, use ScreenMuse to record what happens next.

```bash
# Peekaboo reads the screen → ScreenMuse records the response
peekaboo image --mode screen --analyze "What's on screen?"
curl -X POST http://localhost:7823/start -d '{"name": "response"}'
# ... agent acts on Peekaboo's output ...
curl -X POST http://localhost:7823/stop
```

Or use ScreenMuse's built-in OCR (`POST /ocr`) for lightweight text reads without a separate tool.

## API Reference

Full machine-readable spec (OpenAPI JSON) — load it into Postman, Claude, Cursor, or any OpenAPI tool:

```bash
curl http://localhost:7823/openapi
```

### Recording

| Endpoint | Description |
|----------|-------------|
| `POST /start` | Start recording. Options: `name`, `region`, `audio_source`, `webhook` |
| `POST /stop` | Stop and finalize video |
| `POST /pause` | Pause recording |
| `POST /resume` | Resume recording |
| `POST /chapter` | Mark a named chapter |
| `POST /highlight` | Flag next click for auto-zoom + enhanced effect |
| `POST /screenshot` | Capture a screenshot (no recording required) |
| `POST /note` | Drop a timestamped note into the usage log |

### Export & Edit

| Endpoint | Description |
|----------|-------------|
| `POST /export` | Export as GIF or WebP. Options: `format`, `fps`, `scale`, `quality`, `start`, `end`, `source` |
| `POST /trim` | Trim to time range (stream copy by default, `reencode: true` for frame accuracy) |
| `POST /speedramp` | Auto-speed idle pauses using cursor/keyboard event data |
| `POST /crop` | Crop a rectangular region from the last recording |
| `POST /thumbnail` | Extract a frame at a given timecode |
| `POST /concat` | Combine recordings. Use `"last"` to reference the most recent file. |

### Multi-Window

| Endpoint | Description |
|----------|-------------|
| `POST /start/pip` | Record two windows simultaneously in PiP or side-by-side layout |

### Window Management

These endpoints do what Playwright can't — native macOS window control:

| Endpoint | Description |
|----------|-------------|
| `POST /window/focus` | Bring an app to the front (no permission required) |
| `POST /window/position` | Set window size and position (requires Accessibility permission) |
| `POST /window/hide-others` | Hide all other apps for a clean desktop |

### System State

| Endpoint | Description |
|----------|-------------|
| `GET /system/clipboard` | Read clipboard contents |
| `GET /system/active-window` | Which window has focus |
| `GET /system/running-apps` | List running applications |

### Vision / OCR

| Endpoint | Description |
|----------|-------------|
| `POST /ocr` | On-device OCR via Apple Vision (no API key). Supports `fast` and `accurate` modes, screen or image file. |

### Streaming

| Endpoint | Description |
|----------|-------------|
| `GET /stream` | SSE real-time frame stream (JPEG/PNG, configurable fps and scale) |
| `GET /stream/status` | Active SSE client count |

### Files

| Endpoint | Description |
|----------|-------------|
| `GET /recordings` | List all recordings with size and date |
| `DELETE /recording` | Delete a recording by filename |
| `POST /upload/icloud` | Upload to iCloud Drive → ScreenMuse folder |

### Info & Debug

| Endpoint | Description |
|----------|-------------|
| `GET /status` | Recording state, elapsed time, chapters |
| `GET /version` | Version, build info, all endpoint names |
| `GET /timeline` | Structured JSON of chapters, highlights, notes |
| `GET /debug` | Save directory, recent files, server state |
| `GET /logs` | Recent log entries (filter: `level=`, `category=`, `limit=`) |
| `GET /report` | Clean session summary — paste this in bug reports |
| `GET /openapi` | OpenAPI spec (JSON) |

### Scripting

| Endpoint | Description |
|----------|-------------|
| `POST /script` | Run a shell command mid-session |
| `POST /script/batch` | Run a list of shell commands in order |

### MCP Server

ScreenMuse includes an MCP server (`mcp-server/`) for Claude Desktop and Cursor integration. See [`mcp-server/README.md`](mcp-server/README.md).

## Debugging & Logs

Two log files are created automatically on launch:

| File | Contents |
|------|----------|
| `~/Movies/ScreenMuse/Logs/screenmuse-YYYY-MM-DD.log` | Full debug log — every event, frame counts, errors |
| `~/Movies/ScreenMuse/Logs/screenmuse-usage-YYYY-MM-DD.log` | Clean usage log — one line per action |

Quick debug commands:

```bash
# Session summary — paste this in bug reports
curl http://localhost:7823/report | python3 -c "import sys,json; print(json.load(sys.stdin)['report'])"

# Errors and warnings only
curl "http://localhost:7823/logs?level=warning"

# Filter by subsystem
curl "http://localhost:7823/logs?category=recording"
```

Real-time stream in Console.app: filter for `subsystem == "ai.screenmuse"`.

## Tech Stack

- Swift 6 + ScreenCaptureKit (macOS 14+)
- AVFoundation (H.264/AAC encoding, trim, export, concat)
- Network.framework (HTTP agent API)
- Core Image + Metal (click effects compositing)
- Apple Vision (on-device OCR)

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
