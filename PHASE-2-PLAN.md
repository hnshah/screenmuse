# Phase 2: Professional Demo Recording

**Goal:** Create polished demo videos in <5 minutes, end-to-end

---

## Architecture: 3-Stage Pipeline

```
Script (JSON) → Recording → Auto-Edit → Polished Video
```

---

## Stage 1: Script Format

### Demo Script JSON Structure

```json
{
  "name": "ScreenMuse Demo",
  "scenes": [
    {
      "name": "Introduction",
      "duration": 5,
      "narration": "ScreenMuse is a screen recorder built for AI agents",
      "actions": [
        {"type": "focus_window", "app": "Chrome"},
        {"type": "navigate", "url": "https://github.com/hnshah/screenmuse"},
        {"type": "highlight", "element": "README"}
      ]
    },
    {
      "name": "API Example",
      "duration": 10,
      "narration": "Start recording with a simple HTTP call",
      "actions": [
        {"type": "focus_window", "app": "Terminal"},
        {"type": "type_text", "text": "curl -X POST http://localhost:7823/start"},
        {"type": "highlight"},
        {"type": "wait", "seconds": 2}
      ]
    }
  ],
  "settings": {
    "auto_zoom": true,
    "remove_pauses": true,
    "add_transitions": true,
    "voiceover": "auto"
  }
}
```

---

## Stage 2: Script Executor

### New Endpoint: `POST /demo/record`

**Request:**
```json
{
  "script": { /* script JSON */ },
  "output_name": "screenmuse-demo"
}
```

**What it does:**
1. Validates script
2. Starts recording
3. For each scene:
   - Creates chapter marker
   - Executes actions in sequence
   - Highlights on command
   - Waits for narration timing
4. Stops recording
5. Returns video path

**Response:**
```json
{
  "video_path": "/path/to/screenmuse-demo.mp4",
  "duration": 35.2,
  "scenes_completed": 2,
  "chapters": [
    {"name": "Introduction", "time": 0},
    {"name": "API Example", "time": 5.1}
  ]
}
```

---

## Stage 3: Auto-Editor

### New Endpoint: `POST /edit/auto`

**Request:**
```json
{
  "source": "last",  // or video path
  "remove_pauses": true,
  "pause_threshold_seconds": 3.0,
  "speed_up_idle": 2.0,
  "add_transitions": true,
  "transition_type": "fade"
}
```

**What it does:**
1. Analyzes video for:
   - Long pauses (>3s with no mouse/keyboard activity)
   - Repeated actions (undo detection)
   - Idle time
2. Edits:
   - Cuts dead air
   - Speeds up idle sections
   - Adds fade transitions between chapters
3. Exports edited version

**Response:**
```json
{
  "original_path": "/path/to/raw.mp4",
  "edited_path": "/path/to/raw-edited.mp4",
  "original_duration": 45.2,
  "edited_duration": 28.5,
  "compression_ratio": 1.58,
  "edits_applied": {
    "pauses_removed": 3,
    "idle_sections_sped_up": 5,
    "transitions_added": 2
  }
}
```

---

## Implementation Order

### Chunk 1: Basic Script Executor (20 min)
- Parse script JSON
- Execute simple actions:
  - `focus_window`
  - `wait`
  - `chapter`
  - `highlight`
- Record with auto-chapters

### Chunk 2: Window Actions (15 min)
- `type_text` (keyboard simulation)
- `click` (mouse simulation)
- `navigate` (URL opening)
- `screenshot` (capture frames)

### Chunk 3: Pause Detection (15 min)
- Analyze video for idle time
- Detect frames with no changes
- Build edit decision list (EDL)

### Chunk 4: Auto-Editor (20 min)
- Cut segments from video
- Speed up sections
- Add transitions
- Re-export

### Chunk 5: One-Command Demo (10 min)
- `POST /demo/create`
- Takes script → returns polished video
- Combines executor + editor

**Total: ~80 minutes for core prototype**

---

## Phase 2.5: Smart Enhancements (Later)

- AI script generator (Claude API)
- Smart zoom (element detection + auto-pan)
- Voiceover (TTS integration)
- Background music
- Captions

---

## Success Criteria

**Prototype works when:**
```bash
# 1. Create script
cat > demo-script.json << EOF
{
  "name": "Quick Demo",
  "scenes": [
    {
      "name": "Open Terminal",
      "actions": [
        {"type": "focus_window", "app": "Terminal"},
        {"type": "wait", "seconds": 1},
        {"type": "type_text", "text": "echo 'Hello World'"},
        {"type": "highlight"}
      ]
    }
  ]
}
EOF

# 2. Record
curl -X POST http://localhost:7823/demo/record \
  -H "Content-Type: application/json" \
  -d @demo-script.json

# 3. Auto-edit
curl -X POST http://localhost:7823/edit/auto \
  -d '{"source":"last","remove_pauses":true}'

# 4. Watch polished video
open $(curl -s http://localhost:7823/status | jq -r '.last_video')
```

**If that works → Phase 2 complete!** 🎉

---

## Ready to Build?

Starting with **Chunk 1: Basic Script Executor**

Let's go! 🚀
