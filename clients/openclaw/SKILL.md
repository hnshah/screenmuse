# ScreenMuse Recording

Record your screen while running skills, crons, or demos. ScreenMuse is a macOS screen recorder controlled via a local HTTP API on port 7823.

## When to Use

- **Auto-record skill executions** — wrap any skill in `auto_record_skill.sh` to capture a video of the entire run.
- **Demos** — record yourself building a feature, writing a blog post, or running a workflow, then share the video.
- **Debugging** — record a reproduction of a bug so you can scrub through the timeline later.
- **QA** — record test runs with chapters marking each test phase; review failures visually.
- **Cron jobs** — record periodic tasks (backups, deploys, reports) so there's always a video trail.

## Prerequisites

ScreenMuse macOS app must be running on the machine. It binds to `localhost:7823`.

## Quick Start

### Shell — wrap any command

```bash
# Record a skill execution end-to-end
./clients/openclaw/auto_record_skill.sh "my-skill-name" python3 my_skill.py

# Record a cron job
./clients/openclaw/auto_record_skill.sh "nightly-backup" ./backup.sh
```

### Shell — use the helper directly

```bash
# Start recording
python3 clients/openclaw/screenmuse_helper.py start "my-session"

# Mark chapters as you go
python3 clients/openclaw/screenmuse_helper.py chapter "Step 1: Setup"
python3 clients/openclaw/screenmuse_helper.py chapter "Step 2: Deploy"

# Highlight the next click (auto-zoom + effect)
python3 clients/openclaw/screenmuse_helper.py highlight

# Check status
python3 clients/openclaw/screenmuse_helper.py status

# Stop and get the video path
python3 clients/openclaw/screenmuse_helper.py stop
```

All commands return JSON on stdout.

### Python — inline in a skill

```python
from screenmuse import ScreenMuse

sm = ScreenMuse()
sm.start("typeahead-blog-post")
sm.mark_chapter("Opening editor")

# ... do work ...

sm.highlight_next_click()
# ... click the important button ...

sm.mark_chapter("Published")
result = sm.stop()
print(result["video_path"])
```

Install the Python client: `pip install -e clients/python`

## Chapters and Highlights

**Chapters** mark named points in the recording timeline. Use them to label phases of your workflow:

```bash
python3 screenmuse_helper.py chapter "Login"
python3 screenmuse_helper.py chapter "Fill form"
python3 screenmuse_helper.py chapter "Submit"
```

Chapters appear in the video metadata and can be used to jump to specific moments.

**Highlights** flag the next mouse click as important. ScreenMuse applies auto-zoom and enhanced click effects:

```bash
python3 screenmuse_helper.py highlight
# next click will be zoomed and highlighted
```

## API Endpoints

| Method | Path | Body | Description |
|--------|------|------|-------------|
| POST | /start | `{"name": "..."}` | Start recording |
| POST | /stop | — | Stop recording, get video path |
| POST | /chapter | `{"name": "..."}` | Mark a chapter |
| POST | /highlight | — | Highlight next click |
| GET | /status | — | Get recording status |

All endpoints are on `http://localhost:7823`.

## From a Cron

```bash
# crontab entry — record a nightly report generation
0 2 * * * /path/to/auto_record_skill.sh "nightly-report" /path/to/generate_report.sh
```

The video is saved to `~/Movies/ScreenMuse/` with the session name in the filename.
