# ScreenMuse Agent API Reference

ScreenMuse exposes a local HTTP server on **port 7823** so AI agents can programmatically control screen recordings. This is the core differentiator: agents record themselves, mark chapters, highlight important clicks, and retrieve the finished video — all through simple HTTP calls.

## Why Port 7823?

The server binds to `localhost:7823` by default. The port was chosen to avoid conflicts with common development servers. Only local connections are accepted.

## Endpoints

### POST /start

Start a new recording session.

**Request body:**
```json
{"name": "my-demo-recording"}
```

**Response:**
```json
{"session_id": "uuid", "status": "recording", "name": "my-demo-recording"}
```

**curl example:**
```bash
curl -X POST http://localhost:7823/start \
  -H "Content-Type: application/json" \
  -d '{"name": "feature-walkthrough"}'
```

### POST /stop

Stop the current recording and get the video path.

**Response:**
```json
{
  "video_path": "/Users/you/Movies/ScreenMuse/recording.mp4",
  "metadata": {
    "session_id": "uuid",
    "name": "feature-walkthrough",
    "elapsed": 45.2,
    "chapters": [
      {"name": "Login flow", "time": 5.1},
      {"name": "Dashboard", "time": 18.3}
    ]
  }
}
```

**curl example:**
```bash
curl -X POST http://localhost:7823/stop
```

### POST /chapter

Mark a chapter at the current timestamp. Chapters appear in the video timeline.

**Request body:**
```json
{"name": "Chapter name"}
```

**Response:**
```json
{"ok": true, "time": 12.5}
```

**curl example:**
```bash
curl -X POST http://localhost:7823/chapter \
  -H "Content-Type: application/json" \
  -d '{"name": "Login flow"}'
```

### POST /highlight

Flag the next click as important. ScreenMuse will apply auto-zoom and enhanced click effects to the next mouse click.

**Response:**
```json
{"ok": true}
```

**curl example:**
```bash
curl -X POST http://localhost:7823/highlight
```

### GET /status

Get current recording status.

**Response:**
```json
{
  "recording": true,
  "elapsed": 12.3,
  "session_id": "uuid",
  "chapters": [
    {"name": "Intro", "time": 2.1}
  ]
}
```

**curl example:**
```bash
curl http://localhost:7823/status
```

## Python Quickstart

```bash
pip install -e clients/python
```

```python
from screenmuse import ScreenMuse

sm = ScreenMuse()
sm.start("my-demo")
sm.mark_chapter("Setup")
sm.highlight_next_click()
# ... do things ...
result = sm.stop()
print(result["video_path"])
```

## Node.js / TypeScript Quickstart

```bash
cd clients/node && npm install && npm run build
```

```typescript
import { ScreenMuse } from "screenmuse";

const sm = new ScreenMuse();
await sm.start("my-demo");
await sm.markChapter("Setup");
await sm.highlightNextClick();
// ... do things ...
const result = await sm.stop();
console.log(result.video_path);
```

## OpenClaw Integration

Use ScreenMuse from an OpenClaw skill to record agent workflows:

```python
from screenmuse import ScreenMuse

sm = ScreenMuse()

# Start recording before the agent runs
sm.start("openclaw-skill-demo")
sm.mark_chapter("Starting task")

# ... agent does its work ...
sm.highlight_next_click()  # highlight the important action
# ... agent clicks the button ...

sm.mark_chapter("Task complete")
result = sm.stop()

# result["video_path"] has the recording
# result["metadata"]["chapters"] has the timeline
```

This gives you a video with chapters, highlighted clicks, and auto-zoom — ready to share as a demo or attach to a PR.
