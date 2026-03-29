# Getting Started with ScreenMuse Video Production

**Now that we found the official repo, here's the proper setup.**

---

## Quick Setup (5 Minutes)

### 1. Clone ScreenMuse

```bash
git clone https://github.com/hnshah/screenmuse
cd screenmuse
```

### 2. Run Development Build

```bash
./scripts/dev-run.sh
```

**Why this and not `swift build`?**
- Ad-hoc signed binaries get new hash on every build
- macOS TCC identifies apps by hash → permission re-grant every time
- `dev-run.sh` uses xcodebuild for consistent signature

### 3. Grant Permissions

When prompted:
- ✅ Screen Recording (System Settings → Privacy & Security)
- ✅ Accessibility (optional, needed for window positioning)

**If permissions stuck:** `./scripts/reset-permissions.sh`

### 4. Verify API Running

```bash
curl http://localhost:7823/status
# Should return: {"recording": false, ...}
```

---

## Install Our Production System

### 1. Install Playwright

```bash
npm install -g playwright
npx playwright install chromium
```

### 2. Test Basic Recording

```bash
cd /Users/Vera/.openclaw/workspace/skills/screenmuse-video-production

node scripts/produce-video.js \
  --workflow=google-search \
  --query="stripe api documentation"
```

**Expected output:**
```
✅ Video: /Users/Vera/Movies/ScreenMuse/google-search-....mp4
✅ GIF: /Users/Vera/Movies/ScreenMuse/Exports/google-search-....gif
✅ Quality: HAS CONTENT (0.089 MB/s)
```

---

## Enhanced Integration (Using Chapter Markers)

**We discovered ScreenMuse has chapter markers!**

Update our workflows to use them:

```javascript
// Before each scene
await axios.post('http://localhost:7823/chapter', {
  name: 'Scene 1: Google homepage'
});
```

**Benefits:**
- Seekable video (jump to specific scenes)
- Better debugging (see exactly where things went wrong)
- Cleaner exports (trim by chapter)

---

## Alternative: Use Official Playwright Package

**ScreenMuse provides `screenmuse-playwright` NPM package:**

```bash
cd packages/screenmuse-playwright
npm install
```

**Usage:**
```javascript
const { ScreenMuse } = require('screenmuse-playwright');

const sm = new ScreenMuse();

const result = await sm.record(async (page) => {
  await page.goto('https://example.com');
  await page.click('button');
});

console.log(result.video_path);  // MP4
console.log(result.gif_path);    // GIF (if enabled)
```

**Pros:**
- Zero config (automatic browser detection)
- Auto-starts/stops ScreenMuse
- Handles errors gracefully

**Cons:**
- Less control (no custom shot lists)
- Doesn't use our deliberate production methodology

**Recommendation:** Use our system for deliberate videos, use theirs for quick test captures.

---

## Explore New Features

### 1. Multi-Window Recording

**Record browser + terminal side-by-side:**

```bash
POST /start/pip
{
  "name": "coding-session",
  "window1_pid": 12345,  # Browser
  "window2_pid": 67890,  # Terminal
  "layout": "side-by-side"  # or "pip"
}
```

**Use case:** Show code changes + test results simultaneously

---

### 2. On-Device OCR

**Extract text from recordings (no API key):**

```bash
POST /ocr
{
  "image_path": "/path/to/screenshot.png",
  "mode": "accurate"  # or "fast"
}
```

**Returns:**
```json
{
  "text": "Extracted text here",
  "confidence": 0.95,
  "regions": [...]
}
```

**Use case:** Validate agent saw correct content

---

### 3. Real-Time Streaming

**Stream frames to external viewer:**

```bash
GET /stream
# Returns SSE (Server-Sent Events) with JPEG/PNG frames
```

**Use case:** Monitor agent in real-time, detect issues early

---

### 4. Activity Detection

**ScreenMuse knows when agent is idle:**

```bash
POST /speedramp
{
  "video_path": "/path/to/video.mp4",
  "idle_threshold": 2.0  # seconds
}
```

**Auto-speeds idle sections:**
- Agent typing → normal speed
- Agent waiting for page load → 4x speed
- Agent active again → normal speed

**Use case:** 2-minute recording → 45-second video (no boring parts)

---

## OpenAPI Spec

**Get full API documentation:**

```bash
curl http://localhost:7823/openapi > screenmuse-api.json
```

**Load into:**
- Postman (API testing)
- Cursor (AI code completion knows all endpoints)
- Claude Desktop (via MCP server)

---

## MCP Server Integration

**Control ScreenMuse from Claude Desktop:**

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "screenmuse": {
      "command": "npx",
      "args": ["screenmuse-mcp"],
      "env": {
        "SCREENMUSE_API_KEY": "your-key-here"
      }
    }
  }
}
```

**Find API key:**
```bash
cat ~/.screenmuse/api_key
```

**Now Claude can:**
- Start/stop recordings
- Export GIFs
- Add chapter markers
- Run OCR
- All via natural language

---

## Configuration

**Default settings:**
- Port: `7823`
- Output: `~/Movies/ScreenMuse/`
- Quality: `medium` (10 Mbps)
- Format: H.264 MP4

**Customize via `~/.screenmuse/config.json`:**

```json
{
  "port": 7823,
  "output_dir": "~/Desktop/recordings",
  "default_quality": "high",
  "auto_start": false
}
```

**Or environment variables:**
```bash
export SCREENMUSE_PORT=7823
export SCREENMUSE_OUTPUT_DIR=~/Desktop/recordings
export SCREENMUSE_QUALITY=high
```

---

## Troubleshooting

### "HTTP API not responding"

**1. Check if running:**
```bash
ps aux | grep ScreenMuse
```

**2. Try restarting:**
```bash
killall ScreenMuseApp
cd ~/screenmuse
./scripts/dev-run.sh
```

**3. Check logs (if available):**
```bash
# Look for startup errors
# (Need to ask where logs are written)
```

---

### "Permission denied"

**1. Reset permissions:**
```bash
cd ~/screenmuse
./scripts/reset-permissions.sh
```

**2. Manually grant:**
- System Settings → Privacy & Security
- Screen Recording → ScreenMuse ✓
- Accessibility → ScreenMuse ✓ (if using window positioning)

---

### "Video is blank"

**1. Check MB/s:**
```javascript
const sizeMBPerSec = size_mb / duration;
// < 0.05 = blank, > 0.05 = has content
```

**2. Verify permissions granted**

**3. Try different window:**
```javascript
// List all windows
const windows = await axios.get('http://localhost:7823/windows');
console.log(windows.data);

// Try different PID
```

---

## Next Steps

### After Setup

1. ✅ Run first production: `node scripts/produce-video.js --workflow=google-search`
2. ✅ Verify quality validation works
3. ✅ Try chapter markers in workflows
4. ✅ Explore OCR for text validation
5. ✅ Test activity detection / speedramp

### Build More Workflows

- ✅ form-fill.js (signup/contact forms)
- ✅ product-hunt-browse.js (PH discovery)
- ✅ landing-page-scroll.js (full page tours)
- ✅ github-repo-explore.js (code navigation)

### Advanced Features

- ✅ Multi-window PiP (code + terminal)
- ✅ Real-time streaming (monitoring)
- ✅ Smart speedramp (remove idle time)
- ✅ OCR validation (confirm agent saw correct text)

---

**Official repo:** https://github.com/hnshah/screenmuse  
**Our system:** `/Users/Vera/.openclaw/workspace/skills/screenmuse-video-production/`

**Ready to create production-quality demo videos in 3 minutes.** 🎬
