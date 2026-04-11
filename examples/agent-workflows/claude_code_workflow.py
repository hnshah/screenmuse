#!/usr/bin/env python3
"""
Claude Code / Cursor / Codex agent workflow example.

End-to-end flow that strings together every Sprint 4+5 endpoint:

    1.  GET  /browser/status         — check the Playwright runner
    2.  POST /browser/install        — install it if needed
    3.  POST /browser                — record a real Chromium session
    4.  POST /narrate                — generate timestamped narration
                                        + SRT subtitles via local Ollama
    5.  POST /publish                — push the video to a Slack webhook

Run it:

    python examples/agent-workflows/claude_code_workflow.py \\
        --target https://github.com/anthropics/claude-code \\
        --duration 15 \\
        --slack-webhook $SLACK_WEBHOOK_URL

Environment variables:

    SCREENMUSE_HOST        default 127.0.0.1
    SCREENMUSE_PORT        default 7823
    SCREENMUSE_API_KEY     auto-loaded from ~/.screenmuse/api_key
    OLLAMA_HOST            default http://localhost:11434
    ANTHROPIC_API_KEY      set to use Claude narration instead of Ollama
    SLACK_WEBHOOK_URL      pass via --slack-webhook or this env var

Requirements:

    pip install screenmuse

The ScreenMuse daemon must already be running — start it with
`./scripts/dev-run.sh` in a separate terminal.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

try:
    from screenmuse import ScreenMuseClient
except ImportError:
    sys.exit(
        "screenmuse client not installed. Run:\n"
        "    pip install -e clients/python\n"
        "from the repository root."
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="ScreenMuse agent workflow example")
    parser.add_argument(
        "--target",
        default="https://github.com/anthropics/claude-code",
        help="URL to record (default: claude-code repo)",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=12.0,
        help="Recording duration in seconds (default: 12)",
    )
    parser.add_argument(
        "--narrate",
        default="ollama",
        choices=("ollama", "anthropic", "none"),
        help="Narration provider. 'none' skips narration entirely.",
    )
    parser.add_argument(
        "--slack-webhook",
        default=os.environ.get("SLACK_WEBHOOK_URL"),
        help="Slack incoming webhook URL (or SLACK_WEBHOOK_URL env var)",
    )
    parser.add_argument(
        "--s3-put-url",
        default=os.environ.get("S3_PRESIGNED_PUT_URL"),
        help="Optional presigned S3/R2/GCS PUT URL to also upload the video",
    )
    parser.add_argument(
        "--host",
        default=os.environ.get("SCREENMUSE_HOST", "127.0.0.1"),
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("SCREENMUSE_PORT", "7823")),
    )
    return parser.parse_args()


def banner(title: str) -> None:
    line = "─" * (len(title) + 4)
    print(f"\n{line}")
    print(f"  {title}")
    print(f"{line}")


def ensure_runner_installed(client: ScreenMuseClient) -> None:
    """Step 1+2: probe the runner, install if missing."""
    banner("1. Probing Playwright runner")
    status = client.browser_status()
    print(f"  node_path:             {status.get('node_path') or '<missing>'}")
    print(f"  runner_script_exists:  {status.get('runner_script_exists')}")
    print(f"  playwright_installed:  {status.get('playwright_installed')}")
    print(f"  ready:                 {status.get('ready')}")

    if status.get("ready"):
        return

    banner("2. Installing Playwright runner (first-time setup)")
    print("  This downloads Playwright + Chromium (~130 MB).")
    print("  Dispatching as an async job — polling /job/{id} for progress.")
    install = client.browser_install(async_=True)
    job_id = install.get("job_id")
    if not job_id:
        raise RuntimeError(f"unexpected install response: {install}")

    while True:
        job = client._get(f"/job/{job_id}")
        state = job.get("status")
        print(f"  job {job_id}: {state}")
        if state in ("completed", "failed"):
            if state == "failed":
                raise RuntimeError(f"runner install failed: {job.get('error')}")
            break
        time.sleep(2)


def record_browser(
    client: ScreenMuseClient,
    target: str,
    duration: float,
) -> dict:
    """Step 3: record a Chromium session with deterministic navigation."""
    banner("3. Recording browser session")
    print(f"  url:       {target}")
    print(f"  duration:  {duration}s")
    print(f"  wait_for:  networkidle (so lazy-loaded content shows up)")

    result = client.browser(
        url=target,
        duration_seconds=duration,
        name=f"agent-demo-{int(time.time())}",
        quality="high",
        wait_for="networkidle",
        # Example: scroll the page halfway through to exercise an
        # interactive frame, so the narration has something to describe.
        script="""
            await page.waitForTimeout(3000);
            await page.evaluate(() => window.scrollBy(0, 600));
            await page.waitForTimeout(2000);
            await page.evaluate(() => window.scrollBy(0, -300));
        """,
    )
    browser = result.get("browser", {})
    print(f"  video:     {result.get('path')}")
    print(f"  title:     {browser.get('title')}")
    if browser.get("script_error"):
        print(f"  ⚠ script_error: {browser['script_error']}")
    if browser.get("nav_error"):
        print(f"  ⚠ nav_error: {browser['nav_error']}")
    return result


def narrate_recording(
    client: ScreenMuseClient,
    video_path: str,
    provider: str,
) -> dict | None:
    """Step 4: generate narration + SRT subtitles."""
    if provider == "none":
        return None
    banner(f"4. Generating narration ({provider})")
    try:
        narration = client.narrate(
            source=video_path,
            provider=provider,
            frame_count=6,
            max_chapters=4,
            subtitles=["srt", "vtt"],
            apply_chapters=False,  # we're not recording anymore
        )
    except Exception as exc:
        print(f"  narration failed: {exc}")
        print(
            "  if using 'ollama', make sure `ollama serve` is running and"
            " `ollama pull llava:7b` has been done at least once"
        )
        return None
    print(f"  entries:          {len(narration.get('narration', []))}")
    print(f"  chapter suggests: {len(narration.get('suggested_chapters', []))}")
    subs = narration.get("subtitle_files", {}) or {}
    if subs.get("srt"):
        print(f"  srt:              {subs['srt']}")
    if subs.get("vtt"):
        print(f"  vtt:              {subs['vtt']}")
    return narration


def publish_video(
    client: ScreenMuseClient,
    video_path: str,
    slack_webhook: str | None,
    s3_put_url: str | None,
    narration: dict | None,
) -> None:
    """Step 5: push the video to external destinations."""
    if not slack_webhook and not s3_put_url:
        print("\n  No publish targets configured — skipping step 5.")
        return

    # Build a metadata payload Slack can surface in the notification.
    metadata: dict = {}
    if narration and narration.get("narration"):
        first = narration["narration"][0]
        metadata["preview"] = first.get("text", "")[:140]
    if narration and narration.get("subtitle_files", {}).get("srt"):
        metadata["srt_path"] = narration["subtitle_files"]["srt"]

    if s3_put_url:
        banner("5a. Uploading to S3 (presigned PUT)")
        result = client.publish(
            source=video_path,
            destination="http_put",
            url=s3_put_url,
            headers={"Content-Type": "video/mp4"},
        )
        print(f"  status:    {result.get('status_code')}")
        print(f"  bytes:     {result.get('bytes_sent')}")
        # Slack payload can reference the uploaded video by URL
        metadata["video_url"] = s3_put_url.split("?")[0]

    if slack_webhook:
        banner("5b. Notifying Slack")
        result = client.publish(
            source=video_path,
            destination="slack",
            url=slack_webhook,
            metadata=metadata,
        )
        print(f"  status:    {result.get('status_code')}")


def main() -> int:
    args = parse_args()
    client = ScreenMuseClient(host=args.host, port=args.port)

    try:
        client.health()
    except Exception as exc:
        print(
            f"Could not reach ScreenMuse at {args.host}:{args.port}.\n"
            f"Start the daemon with `./scripts/dev-run.sh` first.\n"
            f"Error: {exc}"
        )
        return 1

    try:
        ensure_runner_installed(client)
        record = record_browser(client, args.target, args.duration)
        video_path = record.get("path")
        if not video_path:
            print("No video path in record response — aborting")
            return 2
        narration = narrate_recording(client, video_path, args.narrate)
        publish_video(client, video_path, args.slack_webhook, args.s3_put_url, narration)
    except Exception as exc:
        print(f"\nWorkflow failed: {exc}")
        return 3

    banner("done")
    print(f"  recording: {video_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
