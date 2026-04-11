"""Python client for the ScreenMuse agent API (port 7823)."""

import os
import requests
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional


def _load_api_key() -> Optional[str]:
    """Load API key from env var or ~/.screenmuse/api_key file."""
    if os.environ.get("SCREENMUSE_NO_AUTH") == "1":
        return None
    key = os.environ.get("SCREENMUSE_API_KEY")
    if key:
        return key
    key_file = Path.home() / ".screenmuse" / "api_key"
    try:
        text = key_file.read_text().strip()
        if text:
            return text
    except (OSError, IOError):
        pass
    return None


class ScreenMuse:
    """Python client for ScreenMuse agent API (port 7823).

    Args:
        host: Server hostname (default: localhost).
        port: Server port (default: 7823).
        api_key: API key for X-ScreenMuse-Key header. Loads from
            SCREENMUSE_API_KEY env var or ~/.screenmuse/api_key if not given.
        timeout: Request timeout in seconds (default: 30).

    Example::

        sm = ScreenMuse()
        sm.start("my-recording")
        # ... do things ...
        result = sm.stop()
        print(result["path"])
    """

    def __init__(
        self,
        host: str = "localhost",
        port: int = 7823,
        api_key: Optional[str] = None,
        timeout: int = 30,
    ):
        self.base_url = f"http://{host}:{port}"
        self.api_key = api_key if api_key is not None else _load_api_key()
        self.timeout = timeout

    # ── Internal helpers ─────────────────────────────────────────────────────

    def _headers(self) -> Dict[str, str]:
        h = {"Content-Type": "application/json"}
        if self.api_key:
            h["X-ScreenMuse-Key"] = self.api_key
        return h

    def _get(self, path: str, auth: bool = True) -> dict:
        """Make a GET request. Set auth=False for endpoints that skip auth (/health)."""
        h = self._headers() if auth else {"Content-Type": "application/json"}
        r = requests.get(f"{self.base_url}{path}", headers=h, timeout=self.timeout)
        r.raise_for_status()
        return r.json()

    def _post(self, path: str, body: Optional[Dict[str, Any]] = None) -> dict:
        """Make a POST request."""
        r = requests.post(
            f"{self.base_url}{path}",
            json=body or {},
            headers=self._headers(),
            timeout=self.timeout,
        )
        r.raise_for_status()
        return r.json()

    def _delete(self, path: str, body: Optional[Dict[str, Any]] = None) -> dict:
        """Make a DELETE request, optionally with a JSON body."""
        r = requests.delete(
            f"{self.base_url}{path}",
            json=body,
            headers=self._headers(),
            timeout=self.timeout,
        )
        r.raise_for_status()
        return r.json()

    # ── Health & Info ────────────────────────────────────────────────────────

    def health(self) -> dict:
        """Get server health. No auth required.

        Returns:
            {ok, version, listener, port, permissions, warning?}
        """
        return self._get("/health", auth=False)

    def version(self) -> dict:
        """Get server version info.

        Returns:
            {version, build?}
        """
        return self._get("/version")

    # ── Recording control ────────────────────────────────────────────────────

    def start(
        self,
        name: str = None,
        window_title: str = None,
        quality: str = None,
        region: dict = None,
        audio_source: str = None,
        webhook: str = None,
    ) -> dict:
        """Start a new recording session.

        Args:
            name: Recording label (auto-generated if omitted).
            window_title: Record a specific window by title.
            quality: "low", "medium", "high", or "max".
            region: {x, y, width, height} dict to record a screen region.
            audio_source: "system", "none", or app name.
            webhook: URL to POST to when recording stops.

        Returns:
            {session_id, status, name, quality, ...}
        """
        body: Dict[str, Any] = {}
        if name:
            body["name"] = name
        if window_title:
            body["window_title"] = window_title
        if quality:
            body["quality"] = quality
        if region:
            body["region"] = region
        if audio_source:
            body["audio_source"] = audio_source
        if webhook:
            body["webhook"] = webhook
        return self._post("/start", body)

    def stop(self) -> dict:
        """Stop recording and return video path + metadata.

        Returns:
            {path, video_path, duration, size, size_mb, session_id, chapters, notes, ...}
        """
        return self._post("/stop")

    def pause(self) -> dict:
        """Pause the current recording.

        Returns:
            {status: "paused", elapsed}
        """
        return self._post("/pause")

    def resume(self) -> dict:
        """Resume a paused recording.

        Returns:
            {status: "recording", elapsed}
        """
        return self._post("/resume")

    def status(self) -> dict:
        """Get current recording status.

        Returns:
            {recording, elapsed, session_id, chapters, last_video, sessions_active, ...}
        """
        return self._get("/status")

    def mark_chapter(self, name: str) -> None:
        """Mark a chapter at the current timestamp."""
        self._post("/chapter", {"name": name})

    def add_note(self, text: str) -> None:
        """Add a timestamped note to the current recording."""
        self._post("/note", {"text": text})

    def highlight_next_click(self) -> None:
        """Mark the next click as important (for auto-zoom)."""
        self._post("/highlight")

    def screenshot(self, path: str = None) -> dict:
        """Capture a full-screen screenshot.

        Args:
            path: Output file path (optional; server picks path if omitted).

        Returns:
            {path, width, height, size}
        """
        body: Dict[str, Any] = {}
        if path:
            body["path"] = path
        return self._post("/screenshot", body)

    # ── Export & editing ─────────────────────────────────────────────────────

    def export(
        self,
        format: str = "gif",
        source: str = None,
        fps: int = None,
        scale: int = None,
        quality: int = None,
        start: float = None,
        end: float = None,
        output: str = None,
    ) -> dict:
        """Export recording as GIF or WebP animation.

        Args:
            format: "gif" or "webp".
            source: Path to video file (uses last recording if omitted).
            fps: Frames per second for the export.
            scale: Width in pixels (height scales proportionally).
            quality: Quality 1-100.
            start: Start time in seconds.
            end: End time in seconds.
            output: Output file path.

        Returns:
            {path, format, width, height, frames, fps, duration, size, size_mb}
        """
        body: Dict[str, Any] = {"format": format}
        if source:
            body["source"] = source
        if fps is not None:
            body["fps"] = fps
        if scale is not None:
            body["scale"] = scale
        if quality is not None:
            body["quality"] = quality
        if start is not None:
            body["start"] = start
        if end is not None:
            body["end"] = end
        if output:
            body["output"] = output
        return self._post("/export", body)

    def trim(
        self,
        start: float,
        end: float,
        source: str = None,
        output: str = None,
        fast_copy: bool = None,
    ) -> dict:
        """Trim a recording to a time range.

        Args:
            start: Start time in seconds.
            end: End time in seconds.
            source: Input video path (uses last recording if omitted).
            output: Output file path.
            fast_copy: Use fast copy mode (no re-encode, default True).

        Returns:
            {path, original_duration, trimmed_duration, start, end, size, size_mb}
        """
        body: Dict[str, Any] = {"start": start, "end": end}
        if source:
            body["source"] = source
        if output:
            body["output"] = output
        if fast_copy is not None:
            body["fast_copy"] = fast_copy
        return self._post("/trim", body)

    def speedramp(
        self,
        segments: List[Dict[str, Any]],
        source: str = None,
        output: str = None,
    ) -> dict:
        """Apply speed ramp to recording segments.

        Args:
            segments: List of {start, end, speed} dicts. speed=2.0 = 2x speed.
            source: Input video path (uses last recording if omitted).
            output: Output file path.

        Returns:
            {path, duration, size, size_mb, segments_applied}
        """
        body: Dict[str, Any] = {"segments": segments}
        if source:
            body["source"] = source
        if output:
            body["output"] = output
        return self._post("/speedramp", body)

    def concat(
        self,
        sources: List[str],
        output: str = None,
        crossfade: float = None,
    ) -> dict:
        """Concatenate multiple recordings into one.

        Args:
            sources: List of video file paths to concatenate.
            output: Output file path.
            crossfade: Crossfade duration in seconds between clips.

        Returns:
            {path, duration, size, size_mb, segments}
        """
        body: Dict[str, Any] = {"sources": sources}
        if output:
            body["output"] = output
        if crossfade is not None:
            body["crossfade"] = crossfade
        return self._post("/concat", body)

    def crop(
        self,
        x: int,
        y: int,
        width: int,
        height: int,
        source: str = None,
        output: str = None,
    ) -> dict:
        """Crop a recording to a region.

        Args:
            x: Left offset in pixels.
            y: Top offset in pixels.
            width: Crop width in pixels.
            height: Crop height in pixels.
            source: Input video path (uses last recording if omitted).
            output: Output file path.

        Returns:
            {path, width, height, size, size_mb}
        """
        body: Dict[str, Any] = {"x": x, "y": y, "width": width, "height": height}
        if source:
            body["source"] = source
        if output:
            body["output"] = output
        return self._post("/crop", body)

    def annotate(
        self,
        texts: List[Dict[str, Any]],
        source: str = None,
        output: str = None,
    ) -> dict:
        """Burn text annotations into a video.

        Args:
            texts: List of {text, time, x?, y?, duration?, color?, fontSize?} dicts.
            source: Input video path (uses last recording if omitted).
            output: Output file path.

        Returns:
            {path, annotations_applied, size, size_mb}
        """
        body: Dict[str, Any] = {"texts": texts}
        if source:
            body["source"] = source
        if output:
            body["output"] = output
        return self._post("/annotate", body)

    def ocr(self, source: str = None) -> dict:
        """Run on-device OCR on a screenshot or video frame.

        Args:
            source: Image or video path (captures screenshot if omitted).

        Returns:
            {text, words?, source?}
        """
        body: Dict[str, Any] = {}
        if source:
            body["source"] = source
        return self._post("/ocr", body)

    def thumbnail(
        self,
        time: float = None,
        source: str = None,
        output: str = None,
    ) -> dict:
        """Extract a thumbnail image from a video.

        Args:
            time: Timestamp in seconds (default: 0).
            source: Input video path (uses last recording if omitted).
            output: Output PNG path.

        Returns:
            {path, width, height, size, time}
        """
        body: Dict[str, Any] = {}
        if time is not None:
            body["time"] = time
        if source:
            body["source"] = source
        if output:
            body["output"] = output
        return self._post("/thumbnail", body)

    def frames(
        self,
        source: str = None,
        fps: float = None,
        output_dir: str = None,
        format: str = None,
        max: int = None,
    ) -> dict:
        """Extract all frames from a video as images.

        Args:
            source: Input video path (uses last recording if omitted).
            fps: Frame rate for extraction (default: video fps).
            output_dir: Directory for output images.
            format: "png" or "jpg".
            max: Maximum number of frames to extract.

        Returns:
            {paths, count, fps, duration}
        """
        body: Dict[str, Any] = {}
        if source:
            body["source"] = source
        if fps is not None:
            body["fps"] = fps
        if output_dir:
            body["output_dir"] = output_dir
        if format:
            body["format"] = format
        if max is not None:
            body["max"] = max
        return self._post("/frames", body)

    def frame(self, source: str = None, output: str = None) -> dict:
        """Capture the current frame with recording context metadata.

        Args:
            source: Video path (uses last recording if omitted).
            output: Output PNG path.

        Returns:
            {path, width, height, time}
        """
        body: Dict[str, Any] = {}
        if source:
            body["source"] = source
        if output:
            body["output"] = output
        return self._post("/frame", body)

    def validate(self, path: str) -> dict:
        """Validate a video file is readable and get its metadata.

        Args:
            path: Path to video file.

        Returns:
            {ok, path, duration, resolution, fps, size, size_mb}
        """
        return self._post("/validate", {"path": path})

    # ── System / window management ────────────────────────────────────────────

    def windows(self) -> list:
        """List all open windows.

        Returns:
            List of {app, title, pid, bounds?, isActive?}
        """
        return self._get("/windows")

    def focus_window(self, app: str = None, pid: int = None, title: str = None) -> dict:
        """Bring a window to focus.

        Returns:
            {ok, app?}
        """
        body: Dict[str, Any] = {}
        if app:
            body["app"] = app
        if pid is not None:
            body["pid"] = pid
        if title:
            body["title"] = title
        return self._post("/window/focus", body)

    def position_window(
        self,
        app: str = None,
        pid: int = None,
        x: int = None,
        y: int = None,
        width: int = None,
        height: int = None,
    ) -> dict:
        """Set position and size of a window.

        Returns:
            {ok}
        """
        body: Dict[str, Any] = {}
        if app:
            body["app"] = app
        if pid is not None:
            body["pid"] = pid
        if x is not None:
            body["x"] = x
        if y is not None:
            body["y"] = y
        if width is not None:
            body["width"] = width
        if height is not None:
            body["height"] = height
        return self._post("/window/position", body)

    def hide_others(self, app: str = None, pid: int = None) -> dict:
        """Hide all windows except those of a specific app.

        Returns:
            {ok, hidden}
        """
        body: Dict[str, Any] = {}
        if app:
            body["app"] = app
        if pid is not None:
            body["pid"] = pid
        return self._post("/window/hide-others", body)

    def active_window(self) -> dict:
        """Get the currently active (focused) window.

        Returns:
            {app, title, pid, bounds?}
        """
        return self._get("/system/active-window")

    def clipboard(self) -> dict:
        """Get the current clipboard contents.

        Returns:
            {text, type}
        """
        return self._get("/system/clipboard")

    def running_apps(self) -> list:
        """List all running applications.

        Returns:
            List of {name, pid, bundleId?, isActive?}
        """
        return self._get("/system/running-apps")

    # ── Timeline & sessions ───────────────────────────────────────────────────

    def timeline(self) -> dict:
        """Get structured session timeline with chapters, notes, highlights.

        Returns:
            {elapsed, chapters, notes, highlights}
        """
        return self._get("/timeline")

    def recordings(self) -> list:
        """List all saved recordings.

        Returns:
            List of {filename, path, size, duration?, created_at?}
        """
        return self._get("/recordings")

    def delete_recording(self, filename: str) -> dict:
        """Delete a saved recording by filename (basename only, not full path).

        Args:
            filename: Filename of recording to delete (e.g. "demo.mp4").

        Returns:
            {ok, filename}
        """
        return self._delete("/recording", {"filename": filename})

    def sessions(self) -> list:
        """List all recording sessions.

        Returns:
            List of {id, name, isRecording, videoPath?, chapters}
        """
        return self._get("/sessions")

    def get_session(self, session_id: str) -> dict:
        """Get a specific session by ID.

        Returns:
            {id, name, isRecording, videoPath?, chapters}
        """
        return self._get(f"/session/{session_id}")

    def delete_session(self, session_id: str) -> dict:
        """Delete a session by ID.

        Returns:
            {ok}
        """
        return self._delete(f"/session/{session_id}")

    # ── Convenience ───────────────────────────────────────────────────────────

    def record(
        self,
        fn: Callable,
        name: str = None,
        gif: bool = False,
        gif_scale: int = 800,
    ) -> dict:
        """Start recording, run fn(), stop, optionally export GIF.

        Args:
            fn: Callable to execute while recording.
            name: Recording label.
            gif: If True, export a GIF after stopping.
            gif_scale: GIF width in pixels (default: 800).

        Returns:
            Stop result dict, with gif_path added if gif=True.

        Example::

            result = sm.record(lambda: do_stuff(), name="demo", gif=True)
            print(result["gif_path"])
        """
        self.start(name=name)
        try:
            fn()
        finally:
            pass  # stop() called below regardless
        result = self.stop()
        if gif:
            gif_result = self.export(format="gif", scale=gif_scale)
            result["gif_path"] = gif_result.get("path")
        return result

    # ── Context manager ───────────────────────────────────────────────────────

    def __enter__(self):
        return self

    def __exit__(self, *args):
        try:
            if self.status().get("recording"):
                self.stop()
        except Exception:
            pass

    # ── Scripting ─────────────────────────────────────────────────────────────

    def script(self, commands: list) -> dict:
        """Run a sequence of recording commands as a batch script.

        Args:
            commands: List of command dicts, e.g.:
                [{"action": "start"}, {"sleep": 2}, {"action": "chapter", "name": "Section 1"}]
                Valid actions: start, stop, chapter, highlight, note, screenshot, sleep.

        Returns:
            {ok, steps_run, steps: [{action, ok, error?}], error?}

        Example::

            sm.script([
                {"action": "start", "name": "demo"},
                {"sleep": 3},
                {"action": "chapter", "name": "Key moment"},
                {"action": "stop"},
            ])
        """
        return self._post("/script", {"commands": commands})

    def script_batch(self, scripts: list, continue_on_error: bool = False) -> dict:
        """Run multiple named scripts in sequence.

        Args:
            scripts: List of script dicts, e.g.:
                [{"name": "setup", "commands": [...]}, {"name": "demo", "commands": [...]}]
            continue_on_error: If True, continue running remaining scripts after a failure.

        Returns:
            {ok, scripts_run, scripts: [{name, ok, steps_run, steps}]}

        Example::

            sm.script_batch([
                {"name": "intro", "commands": [{"action": "highlight"}]},
                {"name": "main", "commands": [{"action": "chapter", "name": "Main"}]},
            ])
        """
        body: Dict[str, Any] = {"scripts": scripts}
        if continue_on_error:
            body["continue_on_error"] = True
        return self._post("/script/batch", body)

    # ── System info ───────────────────────────────────────────────────────────

    def report(self) -> dict:
        """Get a session report with summary statistics.

        Returns:
            {recording, session_id?, elapsed?, chapters_count, notes_count, ...}
        """
        return self._get("/report")

    def debug(self) -> dict:
        """Get debug info about the server state.

        Returns:
            {save_directory, server_recording, active_connections, ...}
        """
        return self._get("/debug")

    def logs(self) -> dict:
        """Get recent server log entries.

        Returns:
            {entries: [{level, message, timestamp}], count}
        """
        return self._get("/logs")

    # ── Jobs ──────────────────────────────────────────────────────────────────

    def jobs(self) -> dict:
        """List all background async jobs and their status.

        Returns:
            {jobs: [{id, status, progress?, result?}], count}
        """
        return self._get("/jobs")

    def get_job(self, job_id: str) -> dict:
        """Get status and result for a specific background job.

        Args:
            job_id: Job ID returned by async operations (e.g. from /export with job_id).

        Returns:
            {id, status, progress?, result?, error?}
        """
        return self._get(f"/job/{job_id}")

    # ── Streaming ─────────────────────────────────────────────────────────────

    def stream_status(self) -> dict:
        """Get SSE stream status.

        Returns:
            {active_clients, total_frames_sent}
        """
        return self._get("/stream/status")

    # ── PiP ───────────────────────────────────────────────────────────────────

    def start_pip(self, source: str = None) -> dict:
        """Start Picture-in-Picture mode.

        Args:
            source: Video source path or 'last' for the most recent recording.

        Returns:
            {ok, source}
        """
        body: Dict[str, Any] = {}
        if source:
            body["source"] = source
        return self._post("/start/pip", body)

    # ── Browser (Playwright) ──────────────────────────────────────────────────

    def browser(
        self,
        url: str,
        duration_seconds: float,
        script: Optional[str] = None,
        width: int = 1280,
        height: int = 720,
        name: Optional[str] = None,
        quality: Optional[str] = None,
        async_: bool = False,
    ) -> dict:
        """Record a Chromium window driven by Playwright.

        Spawns a Node subprocess (installed at ~/.screenmuse/playwright-runner
        via browser_install) that launches a headful Chromium window at the
        given URL, optionally runs a user script in page context, and records
        the window with the standard ScreenMuse pipeline.

        Args:
            url: Page to open (http/https/file).
            duration_seconds: Maximum recording time (1-600).
            script: Optional async JS to run in page context. `page`,
                `context`, and `browser` are in scope. Awaited before the
                recording ends.
            width: Viewport width (320-3840). Default 1280.
            height: Viewport height (240-2160). Default 720.
            name: Optional recording name.
            quality: low / medium / high / max.
            async_: Return a job ID immediately; poll GET /job/{id}.

        Returns:
            The enriched stop response (path, duration, size, resolution…)
            plus a `browser` block with `url_requested`, `url_final`, `title`,
            `pid`, `exit_code`, and any `script_error`/`nav_error`.

        Raises:
            RuntimeError: If POST /browser/install has not been called yet.
        """
        body: Dict[str, Any] = {
            "url": url,
            "duration_seconds": duration_seconds,
            "width": width,
            "height": height,
        }
        if script is not None:
            body["script"] = script
        if name is not None:
            body["name"] = name
        if quality is not None:
            body["quality"] = quality
        if async_:
            body["async"] = True
        return self._post("/browser", body)

    def browser_install(self, async_: bool = True) -> dict:
        """Install the Playwright runner (Node + Chromium) on first use.

        Idempotent. The first call downloads Playwright and Chromium
        (~130MB) and can take a couple of minutes on a cold cache.
        Defaults to async_=True so the HTTP request returns a job ID;
        poll GET /job/{id} for completion.

        Returns:
            Either the install status dict or a job dict.
        """
        body: Dict[str, Any] = {}
        if async_:
            body["async"] = True
        return self._post("/browser/install", body)

    def browser_status(self) -> dict:
        """Inspect the Playwright runner install without triggering an install.

        Returns:
            {runner_directory, runner_script_exists, playwright_installed,
             node_path, npm_path, ready}
        """
        return self._get("/browser/status")

    # ── Upload ────────────────────────────────────────────────────────────────

    def upload_icloud(self, source: str = "last", folder: str = None) -> dict:
        """Upload a recording to iCloud Drive.

        Args:
            source: Video path or 'last' for the most recent recording.
            folder: iCloud folder to upload to (default: 'ScreenMuse').

        Returns:
            {ok, path, icloud_path}
        """
        body: Dict[str, Any] = {"source": source}
        if folder:
            body["folder"] = folder
        return self._post("/upload/icloud", body)
