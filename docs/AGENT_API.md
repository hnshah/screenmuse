# Agent API Reference

> **The live API reference is the OpenAPI spec served by ScreenMuse itself.**
>
> ```bash
> curl http://localhost:7823/openapi
> ```
>
> Load it into Postman, Claude, Cursor, or any OpenAPI-compatible tool for a full, always-up-to-date reference.

This document is kept for historical context. For the current endpoint list, use `/openapi` or see the [README](../README.md#api-reference).

## Quick Reference

ScreenMuse runs on **port 7823**. All endpoints accept and return JSON.

### Recording
- `POST /start` — start recording (`name`, `region`, `audio_source`, `webhook`)
- `POST /stop` — stop and finalize
- `POST /pause` / `POST /resume`
- `POST /chapter` — mark a named chapter
- `POST /highlight` — flag next click for auto-zoom + enhanced effect
- `POST /screenshot` — capture without recording
- `POST /note` — timestamped note to usage log

### Export & Edit
- `POST /export` — GIF or WebP (`format`, `fps`, `scale`, `quality`, `start`, `end`)
- `POST /trim` — stream-copy trim (`start`, `end`, `reencode`)
- `POST /speedramp` — auto-speed idle pauses
- `POST /crop` — crop rectangular region
- `POST /thumbnail` — extract frame at timecode
- `POST /concat` — combine recordings

### Multi-Window
- `POST /start/pip` — two windows, PiP or side-by-side layout

### Window Management
- `POST /window/focus` — bring app to front
- `POST /window/position` — set size and position
- `POST /window/hide-others` — clear desktop

### System State
- `GET /system/clipboard`
- `GET /system/active-window`
- `GET /system/running-apps`

### Vision
- `POST /ocr` — Apple Vision OCR (screen or image file)

### Streaming
- `GET /stream` — SSE real-time frames
- `GET /stream/status`

### Files
- `GET /recordings` — list all
- `DELETE /recording` — delete by filename
- `POST /upload/icloud`

### Info & Debug
- `GET /status` — recording state, elapsed, chapters
- `GET /version` — version, build, all endpoint names
- `GET /timeline` — chapters, highlights, notes as JSON
- `GET /debug` — save dir, recent files, server state
- `GET /logs` — log entries (`level=`, `category=`, `limit=`)
- `GET /report` — session summary for bug reports
- `GET /openapi` — OpenAPI spec (JSON)

### Scripting
- `POST /script` — run shell command
- `POST /script/batch` — run list of commands
