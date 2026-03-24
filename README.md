# ScreenMuse

**The screen recorder built for AI agents.**

ScreenMuse is a native macOS screen recorder that AI agents can control via a local HTTP API. Record demos, mark chapters, highlight important clicks, and get back polished videos — all programmatically.

## Quick Start

```python
from screenmuse import ScreenMuse

sm = ScreenMuse()
sm.start("my-feature-demo")
sm.mark_chapter("Login flow")
sm.highlight_next_click()
# ... agent does its work ...
result = sm.stop()
print(result["video_path"])  # → /Users/you/Movies/ScreenMuse/recording.mp4
```

## Features

| Feature | Status | Description |
|---------|--------|-------------|
| Agent API | v0.1.0 | HTTP server on port 7823 — start/stop/chapter/highlight |
| Click Effects | v0.1.0 | Ripple, glow, particle burst, ring, and sonar presets |
| Cursor Tracking | v0.1.0 | Records cursor position and clicks for post-processing |
| Auto-Zoom | v0.1.0 | Camera follows clicks with spring easing |
| Screen Capture | v0.1.0 | Full screen, window, and region via ScreenCaptureKit |
| Recording | v0.1.0 | MP4 with system audio and microphone |
| Structured Logging | v0.4.0 | File + Console.app + ring buffer; GET /logs, GET /report |
| Annotations | v0.4.0 | POST /note — timestamped notes into usage log mid-session |
| Notifications | v0.4.0 | Native macOS alert when video is ready (with file size) |
| Finder Reveal | v0.4.0 | Finished video auto-selected in Finder on stop |

## Install

**Requirements:** macOS 14.0 (Sonoma) or later, Xcode 15.0+

```bash
git clone https://github.com/hnshah/screenmuse
cd screenmuse
./scripts/dev-run.sh
```

Or open `Package.swift` in Xcode and press Cmd+R.

On first launch, macOS will prompt for screen recording permission. Grant it, then relaunch.

> **Note on `swift build`:** Using `swift build` directly produces an ad-hoc signed binary whose code signature hash changes on every rebuild. macOS TCC (Screen Recording permission) identifies apps by signature hash, so permissions must be re-granted after each rebuild. Use `./scripts/dev-run.sh` (xcodebuild) or Xcode to avoid this — it produces a consistently-signed app that TCC recognizes between builds.
>
> If permissions get stuck: `./scripts/reset-permissions.sh`

## Click Effects

| Preset | Description |
|--------|-------------|
| `ripple` | Expanding rings from click point with spring easing |
| `glow` | Soft radial glow that fades out |
| `particleBurst` | Particles explode outward from click |
| `ring` | Single expanding ring |
| `sonar` | Pulsing sonar-style rings |

Effects are composited onto the recorded video during export using Metal-accelerated Core Image.

## Agent API

ScreenMuse runs a local HTTP server on **port 7823** for programmatic control:

```bash
# Start recording
curl -X POST http://localhost:7823/start -H "Content-Type: application/json" -d '{"name": "demo"}'

# Mark a chapter
curl -X POST http://localhost:7823/chapter -H "Content-Type: application/json" -d '{"name": "Setup"}'

# Highlight next click (auto-zoom + enhanced effect)
curl -X POST http://localhost:7823/highlight

# Check status
curl http://localhost:7823/status

# Take a screenshot (macOS 14+, no recording required)
curl -X POST http://localhost:7823/screenshot

# Stop and get video
curl -X POST http://localhost:7823/stop

# Drop a note into the log exactly when something feels off
curl -X POST http://localhost:7823/note -H "Content-Type: application/json" -d '{"text": "audio dropped here"}'

# ── Export ──

# Export last recording as GIF (default: 10fps, 800px wide)
curl -X POST http://localhost:7823/export

# GIF with custom settings
curl -X POST http://localhost:7823/export -H "Content-Type: application/json" \
  -d '{"format":"gif","fps":10,"scale":800,"quality":"high"}'

# WebP (~30% smaller than GIF at same quality)
curl -X POST http://localhost:7823/export -H "Content-Type: application/json" \
  -d '{"format":"webp","fps":12,"scale":1000}'

# Trim + export in one call
curl -X POST http://localhost:7823/export -H "Content-Type: application/json" \
  -d '{"format":"gif","start":2.5,"end":30.0}'

# Export a specific file
curl -X POST http://localhost:7823/export -H "Content-Type: application/json" \
  -d '{"source":"/Users/you/Movies/ScreenMuse/recording.mp4","format":"gif"}'

# ── Window Management (native macOS — Playwright can't do this) ──

# Bring an app to the front before recording
curl -X POST http://localhost:7823/window/focus -H "Content-Type: application/json" \
  -d '{"app": "Notes"}'

# Set window size and position
curl -X POST http://localhost:7823/window/position -H "Content-Type: application/json" \
  -d '{"app": "Google Chrome", "x": 0, "y": 0, "width": 1440, "height": 900}'

# Hide all other apps — clean desktop for recording
curl -X POST http://localhost:7823/window/hide-others -H "Content-Type: application/json" \
  -d '{"app": "Notes"}'

# ── System State ──

# Read clipboard
curl http://localhost:7823/system/clipboard

# Which window has focus?
curl http://localhost:7823/system/active-window

# What apps are running?
curl http://localhost:7823/system/running-apps

# Check version + all endpoints
curl http://localhost:7823/version
```

**Clients:** [Python](clients/python) | [Node.js/TypeScript](clients/node)

Full API reference: [docs/AGENT_API.md](docs/AGENT_API.md)

## Debugging & Logs

ScreenMuse has structured logging built in. Two log files and three API endpoints.

### Files (auto-created on launch)

| File | What's in it |
|------|-------------|
| `~/Movies/ScreenMuse/Logs/screenmuse-YYYY-MM-DD.log` | Full debug log — every event, frame counts, errors |
| `~/Movies/ScreenMuse/Logs/screenmuse-usage-YYYY-MM-DD.log` | Clean usage log — one line per action (launch, record start/stop, chapters, errors) |

### API Endpoints

```bash
# ★ REPORT — clean session summary, perfect for bug reports
curl http://localhost:7823/report | python3 -c "import sys,json; print(json.load(sys.stdin)['report'])"

# Full debug log (last 200 entries)
curl http://localhost:7823/logs | python3 -m json.tool

# Errors and warnings only
curl "http://localhost:7823/logs?level=warning"

# Filter by subsystem: server / recording / effects / capture / permissions / lifecycle
curl "http://localhost:7823/logs?category=recording"

# System state snapshot
curl http://localhost:7823/debug
```

**Console.app** — filter for real-time streaming:
```
subsystem == "ai.screenmuse"
```

### When reporting a bug

Run these three commands and paste the output:

```bash
curl http://localhost:7823/report | python3 -c "import sys,json; print(json.load(sys.stdin)['report'])"
curl "http://localhost:7823/logs?level=warning"
curl http://localhost:7823/debug
```

Or attach `~/Movies/ScreenMuse/Logs/screenmuse-usage-YYYY-MM-DD.log` — it reads like a plain English timeline of everything you did.

## Roadmap

- Timeline editor with trim and speed controls
- On-device transcription via Whisper (Core ML)
- Edit by transcript: delete words to cut video
- Filler word removal (um, uh, like)
- MP4, GIF, WebP export
- Shareable links via Cloudflare R2
- Webcam overlay and background customization

## Tech Stack

- Swift 6.0 + SwiftUI
- ScreenCaptureKit (Apple native screen capture, macOS 14+)
- AVFoundation (H.264 video encoding, AAC audio)
- Network.framework (agent API HTTP server)
- Core Image + Metal (click effects compositing)
