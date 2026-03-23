# ScreenMuse OpenClaw Integration

Record any OpenClaw skill, cron, or demo with ScreenMuse — the screen recorder built for AI agents.

## Prerequisites

- macOS 14+ with ScreenMuse app running (binds to `localhost:7823`)
- Python 3.8+

## Installation

The helper script (`screenmuse_helper.py`) uses only stdlib — no pip install needed.

For the full Python client with `requests`:

```bash
pip install -e clients/python
```

## Usage

### 1. Shell Wrapper (auto_record_skill.sh)

Wrap any command to record it end-to-end:

```bash
# Record a skill execution
./auto_record_skill.sh "typeahead-blog-post" python3 my_skill.py

# Record a build
./auto_record_skill.sh "nightly-build" make build

# Record a deploy
./auto_record_skill.sh "staging-deploy" ./deploy.sh staging
```

The wrapper:
1. Starts a ScreenMuse recording named after the skill
2. Runs your command
3. Marks a chapter with the result (success/failure)
4. Stops recording and prints the video path

### 2. Python Inline

Use the full client inside your skill code:

```python
from screenmuse import ScreenMuse

sm = ScreenMuse()
sm.start("my-skill")

sm.mark_chapter("Phase 1: Setup")
# ... do setup work ...

sm.mark_chapter("Phase 2: Execute")
sm.highlight_next_click()
# ... click the important button ...

sm.mark_chapter("Done")
result = sm.stop()
print(result["video_path"])
```

Or use the context manager:

```python
from screenmuse import ScreenMuse

with ScreenMuse() as sm:
    sm.start("my-skill")
    sm.mark_chapter("Working")
    # ... recording stops automatically on exit ...
```

### 3. Shell Helper (screenmuse_helper.py)

Call from any shell script or OpenClaw skill:

```bash
# Start
python3 screenmuse_helper.py start "session-name"

# Chapters
python3 screenmuse_helper.py chapter "Step 1"
python3 screenmuse_helper.py chapter "Step 2"

# Highlight next click
python3 screenmuse_helper.py highlight

# Check status
python3 screenmuse_helper.py status

# Stop and get video
python3 screenmuse_helper.py stop
```

All commands return JSON:

```json
{"session_id": "abc-123", "status": "recording", "name": "session-name"}
```

## Examples

### Recording a Typeahead blog post skill

```bash
#!/bin/bash
# typeahead_skill.sh — Write and publish a blog post, recorded on video.

HELPER="$(dirname "$0")/screenmuse_helper.py"

python3 "$HELPER" start "typeahead-blog-post"
python3 "$HELPER" chapter "Opening editor"

# Open the editor
osascript -e 'tell application "TextEdit" to activate'
sleep 2

python3 "$HELPER" chapter "Writing post"
# ... agent types the post ...
sleep 5

python3 "$HELPER" highlight
python3 "$HELPER" chapter "Publishing"
# ... agent clicks publish ...
sleep 2

RESULT=$(python3 "$HELPER" stop)
echo "Video: $(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('video_path',''))")"
```

### Recording a cron job

```bash
# crontab -e
# Record the nightly backup every day at 2 AM:
0 2 * * * /path/to/clients/openclaw/auto_record_skill.sh "nightly-backup" /path/to/backup.sh
```

## API Reference

| Endpoint | Method | Body | Description |
|----------|--------|------|-------------|
| `/start` | POST | `{"name": "..."}` | Start recording |
| `/stop` | POST | — | Stop and get video path |
| `/chapter` | POST | `{"name": "..."}` | Mark a chapter |
| `/highlight` | POST | — | Highlight next click |
| `/status` | GET | — | Recording status |

All on `http://localhost:7823`. Full docs: [docs/AGENT_API.md](../../docs/AGENT_API.md)

## Notes

- ScreenMuse must be running on the Mac before any recording commands work.
- Videos are saved to `~/Movies/ScreenMuse/`.
- The helper uses only Python stdlib (`urllib`) — no dependencies.
- The full Python client (`clients/python/`) requires `requests`.
