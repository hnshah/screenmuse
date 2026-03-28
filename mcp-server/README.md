# ScreenMuse MCP Server

Connect ScreenMuse to Claude Desktop, Cursor, or any MCP-compatible AI agent.

## What it does

Exposes 26 ScreenMuse tools over the MCP protocol so AI agents can:
- Start/stop/pause recordings
- One-shot record for a fixed duration
- Add chapters, notes, and highlights
- OCR the screen (no API key)
- Export recordings as GIF/WebP
- Trim, crop, speed-ramp, and concatenate videos
- Annotate videos with text overlays
- Run scripted recording sequences (single or batch)
- Get system state (active window, clipboard, running apps)

## Pairing with Peekaboo

Peekaboo handles observation + GUI automation (screenshot -> analyze -> click/type).
ScreenMuse handles recording + export (capture -> trim -> share).

Run both for a complete agent toolkit:
```
Peekaboo: see the screen, click buttons, type text
ScreenMuse: record the session, export as GIF, share the proof
```

## Setup

### Prerequisites
1. ScreenMuse.app running on your Mac (starts the HTTP server on port 7823)
2. Node.js 18+

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "screenmuse": {
      "command": "node",
      "args": ["/path/to/screenmuse/mcp-server/screenmuse-mcp.js"]
    }
  }
}
```

### Cursor

Add to Cursor settings (Cmd+Shift+P -> "Open MCP Settings"):

```json
{
  "screenmuse": {
    "command": "node",
    "args": ["/path/to/screenmuse/mcp-server/screenmuse-mcp.js"]
  }
}
```

### Custom port

```json
{
  "screenmuse": {
    "command": "node",
    "args": ["/path/to/screenmuse/mcp-server/screenmuse-mcp.js"],
    "env": { "SCREENMUSE_URL": "http://localhost:7823" }
  }
}
```

### API Key Authentication

If ScreenMuse is running with authentication enabled, set the `SCREENMUSE_API_KEY` environment variable so the MCP server includes the `X-ScreenMuse-Key` header on every request:

```json
{
  "screenmuse": {
    "command": "node",
    "args": ["/path/to/screenmuse/mcp-server/screenmuse-mcp.js"],
    "env": { "SCREENMUSE_API_KEY": "your-api-key-here" }
  }
}
```

You can find your API key in `~/.screenmuse/api_key` (auto-generated on first launch) or set it via the `SCREENMUSE_API_KEY` env var on the server side.

## Available Tools

| Tool | Description |
|------|-------------|
| `screenmuse_start` | Start recording (window, region, quality, webhook) |
| `screenmuse_stop` | Stop and get video path |
| `screenmuse_pause` / `screenmuse_resume` | Pause/resume |
| `screenmuse_record` | One-shot: record for N seconds, return video |
| `screenmuse_chapter` | Add chapter marker |
| `screenmuse_note` | Add timestamped annotation |
| `screenmuse_highlight` | Flag next click for enhanced visual effect |
| `screenmuse_screenshot` | Full-screen screenshot |
| `screenmuse_ocr` | Read text from screen or image (Apple Vision, offline) |
| `screenmuse_export` | Export as GIF or WebP |
| `screenmuse_trim` | Trim to time range |
| `screenmuse_speedramp` | Speed up idle sections, keep active at normal speed |
| `screenmuse_concat` | Concatenate multiple videos |
| `screenmuse_crop` | Crop video to a region |
| `screenmuse_annotate` | Overlay text/shapes on video |
| `screenmuse_thumbnail` | Extract frame at timestamp |
| `screenmuse_script` | Run a sequence of recording commands |
| `screenmuse_script_batch` | Run multiple named scripts in sequence |
| `screenmuse_status` | Current recording state |
| `screenmuse_timeline` | Structured session timeline |
| `screenmuse_recordings` | List all recordings |
| `screenmuse_window_focus` | Bring app to front |
| `screenmuse_active_window` | Get focused window info |
| `screenmuse_clipboard` | Get clipboard contents |
| `screenmuse_running_apps` | List running applications |

## Example Agent Workflow

Claude Desktop with both Peekaboo + ScreenMuse:

```
Claude: "Record me navigating to the settings page and clicking Save"

1. screenmuse_start(name="settings-demo", quality="high")
2. peekaboo_screenshot() -> see current state
3. peekaboo_click("Settings") -> navigate
4. screenmuse_chapter(name="Opened Settings")
5. peekaboo_click("Save") -> complete action
6. screenmuse_chapter(name="Clicked Save")
7. screenmuse_stop() -> video saved
8. screenmuse_export(format="gif", fps=10) -> shareable GIF
```

## Example: Speed-ramp a demo video

```
1. screenmuse_record(duration_seconds=60, name="full-demo")
2. screenmuse_speedramp(idle_threshold_sec=3, idle_speed=6)
   -> Idle pauses sped up 6x, active work at normal speed
```

## Example: Batch script

```
screenmuse_script_batch({
  scripts: [
    { name: "record-setup", commands: [
      { action: "start", name: "setup-demo" },
      { sleep: 5 },
      { action: "chapter", name: "Config complete" },
      { action: "stop" }
    ]},
    { name: "export", commands: [
      { action: "start", name: "export-demo" },
      { sleep: 3 },
      { action: "stop" }
    ]}
  ]
})
```
