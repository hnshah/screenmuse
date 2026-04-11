# Agent workflow patterns

Runnable examples showing how to stitch ScreenMuse's Sprint 4+5 endpoints
together for common AI-agent use cases.

## Prerequisites

1. ScreenMuse daemon running — `./scripts/dev-run.sh` in a separate terminal.
2. Python client — `pip install -e clients/python` from the repo root.
3. Optional but expected for full workflows:
   - **Playwright runner** — auto-installed on first `browser()` call, or
     pre-install with `client.browser_install()`.
   - **Ollama** — `brew install ollama && ollama serve && ollama pull llava:7b`
     if you want zero-cost local narration.

## Examples

### 1. End-to-end Claude Code workflow

`claude_code_workflow.py` — full record → narrate → publish loop.

```bash
python examples/agent-workflows/claude_code_workflow.py \
    --target https://github.com/anthropics/claude-code \
    --duration 15 \
    --slack-webhook https://hooks.slack.com/services/T.../B.../...
```

## Pattern catalog

### Pattern A — "Record this page and give me a narrated video"

```python
from screenmuse import ScreenMuseClient

sm = ScreenMuseClient()

# Assume the runner is already installed
record = sm.browser(
    url="https://example.com",
    duration_seconds=10,
    wait_for="networkidle",     # wait for lazy-loaded content
)

narration = sm.narrate(
    source=record["path"],
    provider="ollama",           # local, free, offline
    frame_count=6,
    subtitles=["srt"],
)

print(narration["narration_file"])           # {stem}.narration.json
print(narration["subtitle_files"]["srt"])    # {stem}.srt
```

### Pattern B — "Record an authenticated flow with saved Playwright state"

ScreenMuse reuses Playwright's storage state JSON format, so you can
save a logged-in session once (`npx playwright save storage_state.json`)
and reference it on every subsequent recording:

```python
sm.browser(
    url="https://app.example.com/dashboard",
    duration_seconds=20,
    storage_state_path="/Users/me/.screenmuse/storage_state.json",
    wait_for="networkidle",
    script="""
        await page.click('text=Billing');
        await page.waitForTimeout(2000);
    """,
)
```

### Pattern C — "Record, then upload to S3 and post to Slack"

Pair `http_put` for the file upload with `slack` for the notification.
`http_put` works with any S3-compatible presigned URL — caller generates
the signature on their side.

```python
# Step 1: record
record = sm.browser(url="https://example.com", duration_seconds=8)

# Step 2: upload to S3 via presigned PUT
s3_url = generate_presigned_put_url_somehow()      # caller signs
sm.publish(
    source=record["path"],
    destination="http_put",
    url=s3_url,
    headers={"Content-Type": "video/mp4"},
)

# Step 3: notify Slack with the S3 URL for context
sm.publish(
    source=record["path"],
    destination="slack",
    url=os.environ["SLACK_WEBHOOK_URL"],
    metadata={"video_url": s3_url.split("?")[0]},  # strip query signature
)
```

### Pattern D — "Scheduled monitoring of a competitor's landing page"

```python
# Recording + narration + auto-apply chapters at interesting transitions
record = sm.browser(
    url="https://competitor.example.com",
    duration_seconds=30,
    wait_for="networkidle",
    script="""
        // scroll through the whole page so we capture the full layout
        for (let y = 0; y < 4000; y += 400) {
            await page.evaluate((y) => window.scrollTo(0, y), y);
            await page.waitForTimeout(1500);
        }
    """,
)

narration = sm.narrate(
    source=record["path"],
    provider="ollama",
    frame_count=12,
    apply_chapters=False,        # no session to apply to — just inspect
)

# Check for specific phrases in the narration to flag changes
flagged = [e for e in narration["narration"] if "pricing" in e["text"].lower()]
if flagged:
    sm.publish(
        destination="webhook",
        url="https://ops.example.com/alerts",
        source=record["path"],
        metadata={"reason": "pricing section changed", "matches": str(len(flagged))},
    )
```

### Pattern E — "Scrape /metrics into Prometheus"

```yaml
# prometheus.yml snippet
scrape_configs:
  - job_name: screenmuse
    scrape_interval: 30s
    static_configs:
      - targets: ["127.0.0.1:7823"]
    metrics_path: /metrics
```

Useful PromQL queries:

```promql
# p95 latency per endpoint
histogram_quantile(0.95,
  sum by (route, le) (
    rate(screenmuse_http_request_duration_seconds_bucket[5m])
  )
)

# Error rate
sum by (route) (
  rate(screenmuse_http_requests_total{status=~"5.."}[5m])
) /
sum by (route) (
  rate(screenmuse_http_requests_total[5m])
)

# Job queue depth
screenmuse_jobs_running + screenmuse_jobs_pending
```

## Troubleshooting

### "runner not installed"
```
POST /browser → 503 RUNNER_NOT_INSTALLED
```
Call `POST /browser/install` (or `client.browser_install(async_=True)`).
First install downloads Playwright + Chromium — takes a couple of minutes
on a cold cache.

### "provider unreachable"
```
POST /narrate → 503 PROVIDER_UNREACHABLE
```
Ollama not running. Start it:
```bash
brew install ollama
ollama serve                 # in a separate terminal
ollama pull llava:7b
```

### "disk space low"
```
POST /start → 507 DISK_SPACE_LOW
```
The disk-space guard refuses to start a recording when the output
volume has less than 2 GB free. Free up space, or override the
threshold in `~/.screenmuse.json`:
```json
{ "disk": { "min_free_gb": 0.5 } }
```
