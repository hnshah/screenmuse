# ScreenMuse

**AI Agent Recorder - Capture What AI Sees & Does**

ScreenMuse is the first screen recorder purpose-built for AI agents. When your AI agent runs a Playwright script, fixes a bug, or automates a workflow - ScreenMuse captures video proof of what happened.

**Built for:**
- 🤖 **AI coding agents** - Record PRs, demonstrate fixes
- 🎭 **Playwright & browser automation** - Video on test failure
- 🔄 **Agentic workflows** - Prove task completion
- 👀 **Computer-use models** - Observe agent behavior

**Not built for:**
- ❌ Manual screen recording (use Loom)
- ❌ Video editing (use ScreenFlow)
- ❌ Live streaming (use OBS)

---

## Why ScreenMuse?

**The Problem:**

Your AI agent just spent 10 minutes automating a task. It says "Done!" 

But... did it work? What did it actually do? Can you share proof?

**The Solution:**

```bash
# Before agent runs
curl -X POST http://localhost:7823/start -d '{"name": "agent-task"}'

# Agent does its thing (Playwright, CLI tools, whatever)
# ...

# After agent finishes
curl -X POST http://localhost:7823/stop
# → Returns video path: /Users/you/Movies/ScreenMuse/agent-task.mp4
```

Now you have a **timestamped video** of exactly what the agent did.

---

## Quick Start

```bash
git clone https://github.com/hnshah/screenmuse
cd screenmuse
./scripts/dev-run.sh
```

Grant Screen Recording permission when prompted, then relaunch.

> **Use `dev-run.sh` or Xcode, not `swift build`.** Ad-hoc signed binaries get a new code signature hash on every rebuild. macOS TCC identifies apps by hash, so screen recording permission needs re-granting after each `swift build`. The script uses xcodebuild for a consistent signature. If permissions get stuck: `./scripts/reset-permissions.sh`

---

## Core Features

### 🎯 API-First Design
- **40+ HTTP endpoints** on `localhost:7823`
- **OpenAPI spec** at `/openapi`
- **Zero UI** - control everything via HTTP
- **Designed for code**, not humans

### 🤖 Agent-Aware
- **Activity detection** - knows when agent is idle
- **Click tracking** - cursor events with timestamps
- **Keystroke overlay** - shows what agent typed
- **Chapter markers** - structure long recordings
- **Highlight mode** - auto-zoom on important moments

### 📤 Export Pipeline
- **GIF** (custom encoder, 10fps default)
- **WebP** (smaller than GIF, better quality)
- **Trim** (frame-accurate or fast stream copy)
- **Speed ramp** (auto-speed idle sections)
- **Crop, thumbnail, concatenate**

### 👁️ Vision/OCR
- **On-device OCR** (Apple Vision)
- **Fast mode** (real-time) + **Accurate mode** (quality)
- **No API key** required

### 🪟 Window Management
- **Focus, position, hide-others** (native macOS)
- **Multi-window PiP** (record 2 windows simultaneously)
- **Works where Playwright can't** (Accessibility API)

### 📡 Real-Time Streaming
- **SSE frame stream** (JPEG/PNG)
- **Configurable FPS/scale**
- **Multiple clients**

---

## Example: Playwright Integration

The `screenmuse-playwright` package makes recording Playwright runs **zero-config**:

```bash
cd packages/screenmuse-playwright
npm install
```

```js
const { ScreenMuse } = require('screenmuse-playwright');

const sm = new ScreenMuse();

// Wrap any async function - automatic recording
const result = await sm.record(async (page) => {
  await page.goto('https://example.com');
  await page.click('button');
  // ScreenMuse is capturing everything
});

console.log(result.video_path);  // → .../recording.mp4
console.log(result.gif_path);    // → .../recording.gif (if enabled)
```

**Playwright Test fixture** for automatic video on failure:

```js
test('my test', async ({ page, screenMuse }) => {
  await page.goto('https://example.com');
  await expect(page.locator('h1')).toBeVisible();
  // If test fails → video automatically saved
});
```

See [`packages/screenmuse-playwright/`](packages/screenmuse-playwright/) for full docs and examples.

---

## Example: AI Coding Agent

Record a coding agent's work:

```python
import subprocess, requests

# Start recording
requests.post("http://localhost:7823/start", json={"name": "fix-bug-123"})

# Mark chapter for each step
requests.post("http://localhost:7823/chapter", json={"name": "Reading code"})

# Agent does its work
subprocess.run(["aider", "--yes", "Fix the authentication bug"])

requests.post("http://localhost:7823/chapter", json={"name": "Running tests"})
subprocess.run(["pytest", "tests/test_auth.py"])

# Stop and get video
response = requests.post("http://localhost:7823/stop").json()
print(f"Recording saved: {response['video_path']}")

# Export as GIF for sharing
requests.post("http://localhost:7823/export", json={
    "format": "gif",
    "fps": 10,
    "scale": 800
})
```

Now you can **attach the video to your PR** showing exactly what the agent did.

---

## Example: Computer-Use Model

Track what a computer-use AI model sees and does:

```python
# Agent uses computer-use API (Anthropic, OpenAI, etc.)
import anthropic, requests

client = anthropic.Anthropic()

# Start recording
requests.post("http://localhost:7823/start", json={"name": "computer-use-session"})

messages = [{"role": "user", "content": "Go to example.com and click the sign-up button"}]

while True:
    response = client.messages.create(
        model="claude-3-5-sonnet-20241022",
        messages=messages,
        tools=[...computer_use_tools...],
        max_tokens=4096
    )
    
    # Agent takes actions (mouse, keyboard, etc.)
    for block in response.content:
        if block.type == "tool_use":
            # Mark significant moments
            requests.post("http://localhost:7823/chapter", 
                         json={"name": f"Tool: {block.name}"})
    
    if response.stop_reason == "end_turn":
        break

# Stop and get recording
result = requests.post("http://localhost:7823/stop").json()
print(f"Session recorded: {result['video_path']}")
```

**Result:** Complete video documentation of the agent's session.

---

## Architecture

**Native macOS, zero dependencies:**

- **ScreenCaptureKit** - screen capture (requires macOS 14+)
- **AVFoundation** - video encoding
- **Metal** - GPU-accelerated effects (click ripples, zoom)
- **Vision** - on-device OCR
- **Swift 6** - modern concurrency (actors, async/await)

**11,980 lines of Swift** - all in-tree, no external frameworks.

```
Sources/
├── ScreenMuseCore/
│   ├── AgentAPI/        # HTTP server (40+ endpoints)
│   ├── Recording/       # ScreenCaptureKit integration
│   ├── Effects/         # Click ripples, zoom, keystroke overlay
│   ├── Export/          # GIF, WebP, trim, speedramp
│   ├── Capture/         # Screenshot manager
│   ├── Streaming/       # SSE frame stream
│   ├── System/          # Window management, clipboard
│   ├── Timeline/        # Chapter markers, event log
│   └── Permissions/     # TCC permission management
├── ScreenMuseApp/       # macOS app (menu bar + viewer)
└── ScreenMuseCLI/       # Command-line tool
```

---

## API Reference

**Full OpenAPI spec:**
```bash
curl http://localhost:7823/openapi > screenmuse-api.json
```

Load into Postman, Cursor, Claude Desktop, or any OpenAPI-compatible tool.

### Quick Reference

**Recording:**
- `POST /start` - Start recording (name, region, audio, webhook)
- `POST /stop` - Stop and finalize video
- `POST /pause` / `POST /resume` - Pause/resume
- `POST /chapter` - Mark a named chapter
- `POST /highlight` - Flag next click for zoom
- `POST /note` - Drop timestamped note
- `POST /screenshot` - Capture a frame (no recording)

**Export:**
- `POST /export` - GIF or WebP (fps, scale, quality, range)
- `POST /trim` - Trim to time range
- `POST /speedramp` - Auto-speed idle sections
- `POST /crop` - Crop rectangular region
- `POST /thumbnail` - Extract frame at timecode
- `POST /concat` - Combine recordings

**Multi-Window:**
- `POST /start/pip` - Record 2 windows (PiP or side-by-side)

**Window Management:**
- `POST /window/focus` - Bring app to front
- `POST /window/position` - Set size and position (requires Accessibility)
- `POST /window/hide-others` - Hide all other apps

**System:**
- `GET /system/clipboard` - Read clipboard
- `GET /system/active-window` - Which window has focus
- `GET /system/running-apps` - List running apps

**Vision/OCR:**
- `POST /ocr` - On-device OCR (fast or accurate mode)

**Streaming:**
- `GET /stream` - SSE frame stream (JPEG/PNG)
- `GET /stream/status` - Active client count

**Metadata:**
- `GET /status` - Recording status
- `GET /version` - Version info
- `GET /openapi` - Full API spec

---

## Use Cases

### 1. **AI Coding Agents**
Record the agent's IDE session - file edits, terminal commands, browser tests.

**Attach video to PR:** "Here's what the agent did to fix the bug."

### 2. **Playwright/Selenium Tests**
Automatic video recording on test failure.

**Debug test flakes:** See exactly what happened before the failure.

### 3. **Agentic Workflows**
Record multi-step autonomous tasks.

**Audit trail:** Video proof of what the agent accomplished.

### 4. **Computer-Use Models**
Document AI's interaction with desktop apps.

**Safety monitoring:** Visual log of agent actions.

### 5. **RPA (Robotic Process Automation)**
Capture automated business workflows.

**Compliance:** Video evidence of process execution.

### 6. **API Demos**
Programmatically generate demo videos.

**Marketing automation:** Consistent, repeatable demos.

---

## Comparison: ScreenMuse vs. Traditional Recorders

| Feature | ScreenMuse | Loom | ScreenFlow | QuickTime |
|---------|-----------|------|------------|-----------|
| **API Control** | ✅ 40+ endpoints | ❌ | ❌ | ❌ |
| **Zero UI** | ✅ | ❌ | ❌ | ❌ |
| **Agent-Aware** | ✅ Activity detection | ❌ | ❌ | ❌ |
| **Programmatic Export** | ✅ GIF, WebP, trim | ❌ | ⚠️ Manual | ❌ |
| **Real-Time Streaming** | ✅ SSE | ❌ | ❌ | ❌ |
| **Multi-Window PiP** | ✅ | ❌ | ⚠️ Manual | ❌ |
| **On-Device OCR** | ✅ Vision | ❌ | ❌ | ❌ |
| **Chapter Markers** | ✅ API | ⚠️ Manual | ⚠️ Manual | ❌ |
| **Dependencies** | ✅ Zero | ? | ? | ✅ Zero |
| **Open Source** | ✅ | ❌ | ❌ | ❌ |

**ScreenMuse = Loom's recording + Playwright's automation + Apple's Vision**

---

## Pairing with Other Tools

### ScreenMuse + Peekaboo
- **Peekaboo:** Screenshot + OCR (what's on screen?)
- **ScreenMuse:** Record what happens next

```bash
# Peekaboo reads → ScreenMuse records response
peekaboo image --mode screen --analyze "Is login form visible?"
curl -X POST http://localhost:7823/start -d '{"name": "login-attempt"}'
# ... agent fills form ...
curl -X POST http://localhost:7823/stop
```

### ScreenMuse + Anthropic Computer Use
- **Anthropic:** AI that controls the computer
- **ScreenMuse:** Records what it did

Perfect for **safety monitoring** and **debugging** computer-use agents.

### ScreenMuse + MCP (Model Context Protocol)
- **MCP Server:** Expose ScreenMuse to Claude Desktop
- **Claude:** Control recording via tool calls

See `docs/MCP.md` for setup.

---

## Requirements

- **macOS 14 (Sonoma)** or later
- **Screen Recording permission** (System Settings → Privacy & Security)
- **Accessibility permission** (optional, for window positioning)
- **Swift 6** (included with Xcode 16+)

**No external dependencies.**

---

## Installation

### Option 1: Run from Source
```bash
git clone https://github.com/hnshah/screenmuse
cd screenmuse
./scripts/dev-run.sh
```

### Option 2: Build CLI
```bash
swift build -c release
.build/release/screenmuse --help
```

### Option 3: Xcode
```bash
open Package.swift
# Build and run ScreenMuseApp target
```

---

## Configuration

**Default settings:**
- **Port:** 7823
- **Output:** `~/Movies/ScreenMuse/`
- **Quality:** Medium (10 Mbps)
- **Format:** H.264 MP4

**Environment variables:**
```bash
export SCREENMUSE_PORT=7823
export SCREENMUSE_OUTPUT_DIR=~/Desktop/recordings
export SCREENMUSE_QUALITY=high
```

Or configure via `~/.screenmuse/config.json`:
```json
{
  "port": 7823,
  "output_dir": "~/Movies/ScreenMuse",
  "default_quality": "medium",
  "auto_start": false
}
```

---

## Development

```bash
# Run tests
swift test

# Build release
swift build -c release

# Run linter (if installed)
swiftlint

# Reset permissions (if stuck)
./scripts/reset-permissions.sh
```

**CI/CD:** GitHub Actions on every push (Build + Test)

---

## FAQ

**Q: Why not just use OBS or Loom?**  
A: Those are built for humans. ScreenMuse is built for **code**. 40+ API endpoints, zero UI, agent-aware features.

**Q: Can I use this for YouTube videos?**  
A: You *could*, but there are better tools (ScreenFlow, Camtasia). ScreenMuse is optimized for **programmatic recording**, not manual editing.

**Q: Does it work on Windows/Linux?**  
A: Not yet. Currently macOS-only (requires ScreenCaptureKit). Cross-platform support in the roadmap.

**Q: How big are the video files?**  
A: **~5-10 MB/minute** at medium quality (10 Mbps). Configurable via quality setting.

**Q: Can I record without the menu bar app?**  
A: Yes! Use the CLI (`screenmuse`) or control via HTTP API directly.

**Q: Is there a cloud/SaaS version?**  
A: No. ScreenMuse is **local-first** by design. Your recordings never leave your machine unless you explicitly upload them.

**Q: Can I contribute?**  
A: Yes! See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Credits

Built by [@hnshah](https://github.com/hnshah) with contributions from the open-source community.

**Powered by:**
- Apple ScreenCaptureKit
- AVFoundation
- Metal
- Vision Framework
- Swift 6

---

## Links

- **GitHub:** https://github.com/hnshah/screenmuse
- **Issues:** https://github.com/hnshah/screenmuse/issues
- **Discussions:** https://github.com/hnshah/screenmuse/discussions
- **Twitter:** [@hnshah](https://twitter.com/hnshah)

---

**ScreenMuse** - Because AI agents need screen recorders too. 🎬🤖
