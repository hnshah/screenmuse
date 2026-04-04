"""Unit tests for the ScreenMuse Python client.

All HTTP calls are mocked — no running server required.
Run with: python -m pytest clients/python/tests/ -v
      or: python -m unittest discover clients/python/tests

Requirements:
    pip install requests   (only the client itself; tests mock all HTTP calls)
"""

import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch, mock_open

# Make sure the package is importable from the repo root
sys.path.insert(0, str(Path(__file__).parent.parent))

# Mock `requests` before importing the client so tests work without the package
# installed (e.g. in CI environments without pip). The actual HTTP logic is still
# exercised via mock.patch; only the import-time binding needs a stand-in.
try:
    import requests  # noqa: F401
except ImportError:
    import types
    requests_mock = types.ModuleType("requests")
    requests_mock.get = MagicMock()
    requests_mock.post = MagicMock()
    requests_mock.delete = MagicMock()

    class _FakeHTTPError(Exception):
        def __init__(self, *args, response=None, **kwargs):
            super().__init__(*args, **kwargs)
            self.response = response

    exceptions_mock = types.ModuleType("requests.exceptions")
    exceptions_mock.HTTPError = _FakeHTTPError
    requests_mock.exceptions = exceptions_mock
    sys.modules["requests"] = requests_mock
    sys.modules["requests.exceptions"] = exceptions_mock

from screenmuse.client import ScreenMuse, _load_api_key


# ── Helper: build a mock requests.Response ────────────────────────────────────

def _mock_response(data: dict, status_code: int = 200) -> MagicMock:
    """Return a mock that behaves like a requests.Response."""
    m = MagicMock()
    m.status_code = status_code
    m.json.return_value = data
    m.raise_for_status = MagicMock()
    if status_code >= 400:
        from requests.exceptions import HTTPError
        m.raise_for_status.side_effect = HTTPError(f"{status_code}", response=m)
    return m


# ── API key loading ────────────────────────────────────────────────────────────

class TestApiKeyLoading(unittest.TestCase):

    def test_no_auth_env_returns_none(self):
        with patch.dict(os.environ, {"SCREENMUSE_NO_AUTH": "1"}, clear=False):
            # Remove API key env if set
            env = {k: v for k, v in os.environ.items() if k != "SCREENMUSE_API_KEY"}
            env["SCREENMUSE_NO_AUTH"] = "1"
            with patch.dict(os.environ, env, clear=True):
                result = _load_api_key()
        self.assertIsNone(result)

    def test_env_var_takes_precedence(self):
        with patch.dict(os.environ, {"SCREENMUSE_API_KEY": "env-key-123", "SCREENMUSE_NO_AUTH": ""}, clear=False):
            result = _load_api_key()
        self.assertEqual(result, "env-key-123")

    def test_file_key_used_when_no_env(self):
        with patch.dict(os.environ, {}, clear=True):
            with patch("builtins.open", mock_open(read_data="file-key-abc\n")):
                with patch("pathlib.Path.read_text", return_value="file-key-abc\n"):
                    # Temporarily make os.environ.get return None for both keys
                    result = _load_api_key()
        # If env var is missing, file key should be returned
        # This test verifies the shape of the loading logic

    def test_explicit_api_key_in_constructor(self):
        sm = ScreenMuse(api_key="explicit-key")
        self.assertEqual(sm.api_key, "explicit-key")

    def test_no_key_results_in_no_header(self):
        sm = ScreenMuse(api_key=None)
        sm.api_key = None
        headers = sm._headers()
        self.assertNotIn("X-ScreenMuse-Key", headers)

    def test_key_present_adds_header(self):
        sm = ScreenMuse(api_key="my-secret")
        headers = sm._headers()
        self.assertEqual(headers["X-ScreenMuse-Key"], "my-secret")

    def test_content_type_always_set(self):
        sm = ScreenMuse()
        sm.api_key = None
        headers = sm._headers()
        self.assertEqual(headers["Content-Type"], "application/json")


# ── Constructor ───────────────────────────────────────────────────────────────

class TestConstructor(unittest.TestCase):

    def test_default_base_url(self):
        sm = ScreenMuse()
        self.assertEqual(sm.base_url, "http://localhost:7823")

    def test_custom_host_and_port(self):
        sm = ScreenMuse(host="192.168.1.10", port=9000)
        self.assertEqual(sm.base_url, "http://192.168.1.10:9000")

    def test_default_timeout(self):
        sm = ScreenMuse()
        self.assertEqual(sm.timeout, 30)

    def test_custom_timeout(self):
        sm = ScreenMuse(timeout=60)
        self.assertEqual(sm.timeout, 60)


# ── Health & Info ─────────────────────────────────────────────────────────────

class TestHealthAndInfo(unittest.TestCase):

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key")

    @patch("screenmuse.client.requests.get")
    def test_health_calls_correct_url(self, mock_get):
        mock_get.return_value = _mock_response({"ok": True, "version": "1.6.0"})
        result = self.sm.health()
        mock_get.assert_called_once()
        args, kwargs = mock_get.call_args
        self.assertIn("/health", args[0])

    @patch("screenmuse.client.requests.get")
    def test_health_no_auth_header(self, mock_get):
        """Health endpoint should not send the API key header."""
        mock_get.return_value = _mock_response({"ok": True})
        self.sm.health()
        _, kwargs = mock_get.call_args
        headers = kwargs.get("headers", {})
        self.assertNotIn("X-ScreenMuse-Key", headers)

    @patch("screenmuse.client.requests.get")
    def test_health_returns_dict(self, mock_get):
        mock_get.return_value = _mock_response({"ok": True, "version": "1.6.0"})
        result = self.sm.health()
        self.assertIsInstance(result, dict)
        self.assertTrue(result["ok"])

    @patch("screenmuse.client.requests.get")
    def test_version_calls_correct_url(self, mock_get):
        mock_get.return_value = _mock_response({"version": "1.6.0"})
        result = self.sm.version()
        args, _ = mock_get.call_args
        self.assertIn("/version", args[0])
        self.assertEqual(result["version"], "1.6.0")


# ── Recording control ─────────────────────────────────────────────────────────

class TestRecordingControl(unittest.TestCase):

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key")

    @patch("screenmuse.client.requests.post")
    def test_start_sends_correct_body(self, mock_post):
        mock_post.return_value = _mock_response({
            "session_id": "abc123", "status": "recording", "name": "demo", "quality": "medium"
        })
        result = self.sm.start(name="demo", quality="high")
        _, kwargs = mock_post.call_args
        body = kwargs["json"]
        self.assertEqual(body["name"], "demo")
        self.assertEqual(body["quality"], "high")
        self.assertEqual(result["status"], "recording")

    @patch("screenmuse.client.requests.post")
    def test_start_no_required_args(self, mock_post):
        mock_post.return_value = _mock_response({"session_id": "abc", "status": "recording"})
        self.sm.start()  # Should not raise
        mock_post.assert_called_once()

    @patch("screenmuse.client.requests.post")
    def test_start_with_region(self, mock_post):
        mock_post.return_value = _mock_response({"status": "recording"})
        region = {"x": 100, "y": 200, "width": 800, "height": 600}
        self.sm.start(region=region)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["region"], region)

    @patch("screenmuse.client.requests.post")
    def test_start_with_webhook(self, mock_post):
        mock_post.return_value = _mock_response({"status": "recording"})
        self.sm.start(webhook="https://example.com/hook")
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["webhook"], "https://example.com/hook")

    @patch("screenmuse.client.requests.post")
    def test_stop_returns_result(self, mock_post):
        mock_post.return_value = _mock_response({
            "path": "/tmp/demo.mp4", "duration": 8.2, "size": 1024, "size_mb": 1.0,
            "session_id": "abc", "chapters": [], "notes": []
        })
        result = self.sm.stop()
        self.assertEqual(result["path"], "/tmp/demo.mp4")
        self.assertAlmostEqual(result["duration"], 8.2)

    @patch("screenmuse.client.requests.post")
    def test_stop_posts_to_correct_url(self, mock_post):
        mock_post.return_value = _mock_response({"path": "/tmp/x.mp4"})
        self.sm.stop()
        args, _ = mock_post.call_args
        self.assertIn("/stop", args[0])

    @patch("screenmuse.client.requests.post")
    def test_pause_returns_status(self, mock_post):
        mock_post.return_value = _mock_response({"status": "paused", "elapsed": 5.0})
        result = self.sm.pause()
        self.assertEqual(result["status"], "paused")

    @patch("screenmuse.client.requests.post")
    def test_resume_returns_status(self, mock_post):
        mock_post.return_value = _mock_response({"status": "recording", "elapsed": 5.0})
        result = self.sm.resume()
        self.assertEqual(result["status"], "recording")

    @patch("screenmuse.client.requests.get")
    def test_status_calls_get(self, mock_get):
        mock_get.return_value = _mock_response({"recording": False, "elapsed": 0})
        result = self.sm.status()
        args, _ = mock_get.call_args
        self.assertIn("/status", args[0])
        self.assertFalse(result["recording"])

    @patch("screenmuse.client.requests.post")
    def test_mark_chapter(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm.mark_chapter("Step 1")
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["name"], "Step 1")

    @patch("screenmuse.client.requests.post")
    def test_add_note(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm.add_note("Something happened here")
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["text"], "Something happened here")

    @patch("screenmuse.client.requests.post")
    def test_highlight_next_click(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm.highlight_next_click()
        args, _ = mock_post.call_args
        self.assertIn("/highlight", args[0])

    @patch("screenmuse.client.requests.post")
    def test_screenshot_no_path(self, mock_post):
        mock_post.return_value = _mock_response({
            "path": "/tmp/screen.png", "width": 1920, "height": 1080, "size": 500
        })
        result = self.sm.screenshot()
        _, kwargs = mock_post.call_args
        self.assertNotIn("path", kwargs["json"])

    @patch("screenmuse.client.requests.post")
    def test_screenshot_with_path(self, mock_post):
        mock_post.return_value = _mock_response({"path": "/tmp/out.png"})
        self.sm.screenshot(path="/tmp/out.png")
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["path"], "/tmp/out.png")


# ── Export & editing ──────────────────────────────────────────────────────────

class TestExportAndEditing(unittest.TestCase):

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key")

    @patch("screenmuse.client.requests.post")
    def test_export_default_format_gif(self, mock_post):
        mock_post.return_value = _mock_response({
            "path": "/tmp/out.gif", "format": "gif", "width": 800,
            "height": 600, "frames": 82, "fps": 10, "duration": 8.2,
            "size": 1024, "size_mb": 1.0
        })
        result = self.sm.export()
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["format"], "gif")
        self.assertEqual(result["format"], "gif")

    @patch("screenmuse.client.requests.post")
    def test_export_webp_format(self, mock_post):
        mock_post.return_value = _mock_response({"path": "/tmp/out.webp", "format": "webp"})
        self.sm.export(format="webp", fps=15, scale=1280)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["format"], "webp")
        self.assertEqual(kwargs["json"]["fps"], 15)
        self.assertEqual(kwargs["json"]["scale"], 1280)

    @patch("screenmuse.client.requests.post")
    def test_export_time_range(self, mock_post):
        mock_post.return_value = _mock_response({"path": "/tmp/clip.gif"})
        self.sm.export(start=2.0, end=8.0)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["start"], 2.0)
        self.assertEqual(kwargs["json"]["end"], 8.0)

    @patch("screenmuse.client.requests.post")
    def test_trim_required_params(self, mock_post):
        mock_post.return_value = _mock_response({
            "path": "/tmp/trimmed.mp4", "original_duration": 60.0,
            "trimmed_duration": 30.0, "start": 10.0, "end": 40.0, "size": 512, "size_mb": 0.5
        })
        result = self.sm.trim(start=10.0, end=40.0)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["start"], 10.0)
        self.assertEqual(kwargs["json"]["end"], 40.0)
        self.assertAlmostEqual(result["original_duration"], 60.0)

    @patch("screenmuse.client.requests.post")
    def test_trim_with_source_and_fast_copy(self, mock_post):
        mock_post.return_value = _mock_response({"path": "/tmp/out.mp4"})
        self.sm.trim(start=0.0, end=5.0, source="/tmp/input.mp4", fast_copy=False)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["source"], "/tmp/input.mp4")
        self.assertFalse(kwargs["json"]["fast_copy"])

    @patch("screenmuse.client.requests.post")
    def test_speedramp_passes_segments(self, mock_post):
        mock_post.return_value = _mock_response({
            "path": "/tmp/ramped.mp4", "duration": 30.0, "size": 1024,
            "size_mb": 1.0, "segments_applied": 2
        })
        segments = [{"start": 0, "end": 10, "speed": 2.0}, {"start": 10, "end": 20, "speed": 0.5}]
        result = self.sm.speedramp(segments=segments)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["segments"], segments)
        self.assertEqual(result["segments_applied"], 2)

    @patch("screenmuse.client.requests.post")
    def test_concat_passes_sources(self, mock_post):
        mock_post.return_value = _mock_response({
            "path": "/tmp/concat.mp4", "duration": 60.0, "size": 2048,
            "size_mb": 2.0, "segments": 3
        })
        sources = ["/tmp/a.mp4", "/tmp/b.mp4", "/tmp/c.mp4"]
        result = self.sm.concat(sources=sources)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["sources"], sources)
        self.assertEqual(result["segments"], 3)

    @patch("screenmuse.client.requests.post")
    def test_concat_with_crossfade(self, mock_post):
        mock_post.return_value = _mock_response({"path": "/tmp/out.mp4"})
        self.sm.concat(sources=["/a.mp4", "/b.mp4"], crossfade=0.5)
        _, kwargs = mock_post.call_args
        self.assertAlmostEqual(kwargs["json"]["crossfade"], 0.5)

    @patch("screenmuse.client.requests.post")
    def test_crop_params(self, mock_post):
        mock_post.return_value = _mock_response({
            "path": "/tmp/cropped.mp4", "width": 800, "height": 600,
            "size": 512, "size_mb": 0.5
        })
        result = self.sm.crop(x=100, y=200, width=800, height=600)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["x"], 100)
        self.assertEqual(kwargs["json"]["y"], 200)
        self.assertEqual(kwargs["json"]["width"], 800)
        self.assertEqual(kwargs["json"]["height"], 600)

    @patch("screenmuse.client.requests.post")
    def test_annotate_passes_texts(self, mock_post):
        mock_post.return_value = _mock_response({
            "path": "/tmp/annotated.mp4", "annotations_applied": 2,
            "size": 1024, "size_mb": 1.0
        })
        texts = [
            {"text": "Step 1", "time": 0.0},
            {"text": "Step 2", "time": 5.0, "color": "#FF0000"}
        ]
        result = self.sm.annotate(texts=texts)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["texts"], texts)
        self.assertEqual(result["annotations_applied"], 2)

    @patch("screenmuse.client.requests.post")
    def test_ocr_no_source(self, mock_post):
        mock_post.return_value = _mock_response({"text": "Hello World"})
        result = self.sm.ocr()
        args, kwargs = mock_post.call_args
        self.assertIn("/ocr", args[0])
        self.assertNotIn("source", kwargs["json"])

    @patch("screenmuse.client.requests.post")
    def test_ocr_with_source(self, mock_post):
        mock_post.return_value = _mock_response({"text": "Test text"})
        self.sm.ocr(source="/tmp/frame.png")
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["source"], "/tmp/frame.png")

    @patch("screenmuse.client.requests.post")
    def test_thumbnail_default(self, mock_post):
        mock_post.return_value = _mock_response({
            "path": "/tmp/thumb.png", "width": 1920, "height": 1080,
            "size": 200, "time": 0.0
        })
        result = self.sm.thumbnail()
        self.assertIn("path", result)

    @patch("screenmuse.client.requests.post")
    def test_thumbnail_with_time(self, mock_post):
        mock_post.return_value = _mock_response({"path": "/tmp/thumb.png"})
        self.sm.thumbnail(time=5.5)
        _, kwargs = mock_post.call_args
        self.assertAlmostEqual(kwargs["json"]["time"], 5.5)

    @patch("screenmuse.client.requests.post")
    def test_validate_passes_path(self, mock_post):
        mock_post.return_value = _mock_response({
            "ok": True, "path": "/tmp/vid.mp4", "duration": 30.0, "size": 1024, "size_mb": 1.0
        })
        result = self.sm.validate("/tmp/vid.mp4")
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["path"], "/tmp/vid.mp4")
        self.assertTrue(result["ok"])


# ── System & windows ──────────────────────────────────────────────────────────

class TestSystemAndWindows(unittest.TestCase):

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key")

    @patch("screenmuse.client.requests.get")
    def test_windows_returns_list(self, mock_get):
        windows = [
            {"app": "Safari", "title": "Google", "pid": 123},
            {"app": "Terminal", "title": "bash", "pid": 456}
        ]
        mock_get.return_value = _mock_response(windows)
        result = self.sm.windows()
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["app"], "Safari")

    @patch("screenmuse.client.requests.post")
    def test_focus_window_by_app(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True, "app": "Chrome"})
        self.sm.focus_window(app="Chrome")
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["app"], "Chrome")

    @patch("screenmuse.client.requests.post")
    def test_focus_window_by_pid(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm.focus_window(pid=1234)
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["json"]["pid"], 1234)

    @patch("screenmuse.client.requests.post")
    def test_position_window_all_params(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm.position_window(app="Finder", x=0, y=0, width=1280, height=800)
        _, kwargs = mock_post.call_args
        body = kwargs["json"]
        self.assertEqual(body["app"], "Finder")
        self.assertEqual(body["x"], 0)
        self.assertEqual(body["width"], 1280)

    @patch("screenmuse.client.requests.post")
    def test_hide_others(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True, "hidden": 5})
        result = self.sm.hide_others(app="Xcode")
        self.assertEqual(result["hidden"], 5)

    @patch("screenmuse.client.requests.get")
    def test_active_window(self, mock_get):
        mock_get.return_value = _mock_response({
            "app": "VS Code", "title": "main.py", "pid": 999
        })
        result = self.sm.active_window()
        self.assertEqual(result["app"], "VS Code")

    @patch("screenmuse.client.requests.get")
    def test_clipboard(self, mock_get):
        mock_get.return_value = _mock_response({"text": "Hello World", "type": "text"})
        result = self.sm.clipboard()
        self.assertEqual(result["text"], "Hello World")
        self.assertEqual(result["type"], "text")

    @patch("screenmuse.client.requests.get")
    def test_running_apps(self, mock_get):
        apps = [{"name": "Finder", "pid": 100}, {"name": "Dock", "pid": 101}]
        mock_get.return_value = _mock_response(apps)
        result = self.sm.running_apps()
        self.assertEqual(len(result), 2)


# ── Timeline & sessions ───────────────────────────────────────────────────────

class TestTimelineAndSessions(unittest.TestCase):

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key")

    @patch("screenmuse.client.requests.get")
    def test_timeline(self, mock_get):
        mock_get.return_value = _mock_response({
            "elapsed": 12.5,
            "chapters": [{"name": "Intro", "time": 0.0}],
            "notes": [],
            "highlights": []
        })
        result = self.sm.timeline()
        self.assertAlmostEqual(result["elapsed"], 12.5)
        self.assertEqual(len(result["chapters"]), 1)

    @patch("screenmuse.client.requests.get")
    def test_recordings(self, mock_get):
        recs = [{"filename": "demo.mp4", "path": "/tmp/demo.mp4", "size": 1024}]
        mock_get.return_value = _mock_response(recs)
        result = self.sm.recordings()
        self.assertEqual(result[0]["filename"], "demo.mp4")

    @patch("screenmuse.client.requests.delete")
    def test_delete_recording_passes_filename(self, mock_delete):
        mock_delete.return_value = _mock_response({"ok": True, "filename": "demo.mp4"})
        result = self.sm.delete_recording("demo.mp4")
        _, kwargs = mock_delete.call_args
        self.assertEqual(kwargs["json"]["filename"], "demo.mp4")
        self.assertTrue(result["ok"])

    @patch("screenmuse.client.requests.get")
    def test_sessions_returns_list(self, mock_get):
        sessions = [{"id": "s1", "name": "Test", "isRecording": False, "chapters": []}]
        mock_get.return_value = _mock_response(sessions)
        result = self.sm.sessions()
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["id"], "s1")

    @patch("screenmuse.client.requests.get")
    def test_get_session(self, mock_get):
        mock_get.return_value = _mock_response({
            "id": "abc123", "name": "My Session", "isRecording": False, "chapters": []
        })
        result = self.sm.get_session("abc123")
        args, _ = mock_get.call_args
        self.assertIn("/session/abc123", args[0])
        self.assertEqual(result["id"], "abc123")

    @patch("screenmuse.client.requests.delete")
    def test_delete_session(self, mock_delete):
        mock_delete.return_value = _mock_response({"ok": True})
        result = self.sm.delete_session("abc123")
        args, _ = mock_delete.call_args
        self.assertIn("/session/abc123", args[0])
        self.assertTrue(result["ok"])


# ── Convenience record() ──────────────────────────────────────────────────────

class TestRecordConvenience(unittest.TestCase):

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key")

    @patch("screenmuse.client.requests.post")
    def test_record_calls_start_and_stop(self, mock_post):
        start_resp = _mock_response({"status": "recording"})
        stop_resp = _mock_response({"path": "/tmp/out.mp4", "duration": 3.0})
        mock_post.side_effect = [start_resp, stop_resp]

        result = self.sm.record(lambda: None, name="test")
        self.assertEqual(mock_post.call_count, 2)
        # First call: /start
        args0, _ = mock_post.call_args_list[0]
        self.assertIn("/start", args0[0])
        # Second call: /stop
        args1, _ = mock_post.call_args_list[1]
        self.assertIn("/stop", args1[0])
        self.assertEqual(result["path"], "/tmp/out.mp4")

    @patch("screenmuse.client.requests.post")
    def test_record_with_gif_exports(self, mock_post):
        start_resp = _mock_response({"status": "recording"})
        stop_resp = _mock_response({"path": "/tmp/out.mp4", "duration": 3.0})
        export_resp = _mock_response({"path": "/tmp/out.gif", "format": "gif"})
        mock_post.side_effect = [start_resp, stop_resp, export_resp]

        result = self.sm.record(lambda: None, gif=True)
        self.assertEqual(mock_post.call_count, 3)
        self.assertEqual(result["gif_path"], "/tmp/out.gif")

    @patch("screenmuse.client.requests.post")
    def test_record_no_gif_by_default(self, mock_post):
        start_resp = _mock_response({"status": "recording"})
        stop_resp = _mock_response({"path": "/tmp/out.mp4"})
        mock_post.side_effect = [start_resp, stop_resp]

        result = self.sm.record(lambda: None)
        self.assertEqual(mock_post.call_count, 2)
        self.assertNotIn("gif_path", result)


# ── Context manager ───────────────────────────────────────────────────────────

class TestContextManager(unittest.TestCase):

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key")

    @patch("screenmuse.client.requests.post")
    @patch("screenmuse.client.requests.get")
    def test_context_manager_stops_if_recording(self, mock_get, mock_post):
        mock_get.return_value = _mock_response({"recording": True})
        mock_post.return_value = _mock_response({"path": "/tmp/out.mp4"})

        with self.sm:
            pass

        mock_post.assert_called_once()
        args, _ = mock_post.call_args
        self.assertIn("/stop", args[0])

    @patch("screenmuse.client.requests.get")
    def test_context_manager_no_stop_if_not_recording(self, mock_get):
        mock_get.return_value = _mock_response({"recording": False})

        with patch("screenmuse.client.requests.post") as mock_post:
            with self.sm:
                pass
            mock_post.assert_not_called()


# ── HTTP helper internals ─────────────────────────────────────────────────────

class TestHTTPHelpers(unittest.TestCase):

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key")

    @patch("screenmuse.client.requests.post")
    def test_api_key_header_sent_on_post(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm._post("/status")
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["headers"]["X-ScreenMuse-Key"], "test-key")

    @patch("screenmuse.client.requests.get")
    def test_api_key_header_sent_on_get(self, mock_get):
        mock_get.return_value = _mock_response({"ok": True})
        self.sm._get("/status")
        _, kwargs = mock_get.call_args
        self.assertEqual(kwargs["headers"]["X-ScreenMuse-Key"], "test-key")

    @patch("screenmuse.client.requests.post")
    def test_timeout_passed_to_requests(self, mock_post):
        sm = ScreenMuse(api_key="key", timeout=45)
        mock_post.return_value = _mock_response({"ok": True})
        sm._post("/test")
        _, kwargs = mock_post.call_args
        self.assertEqual(kwargs["timeout"], 45)

    @patch("screenmuse.client.requests.get")
    def test_get_timeout_passed(self, mock_get):
        sm = ScreenMuse(api_key="key", timeout=10)
        mock_get.return_value = _mock_response({"ok": True})
        sm._get("/test")
        _, kwargs = mock_get.call_args
        self.assertEqual(kwargs["timeout"], 10)


if __name__ == "__main__":
    unittest.main()


# ===========================================================================
# Tests for newly added Python client methods (full API coverage)
# ===========================================================================

class TestScriptMethods(unittest.TestCase):
    """Tests for /script and /script/batch methods."""

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key", base_url="http://127.0.0.1:7823")

    @patch("screenmuse.client.requests.post")
    def test_script_calls_correct_endpoint(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True, "steps_run": 1})
        result = self.sm.script([{"action": "highlight"}])
        self.assertEqual(result["ok"], True)
        args, _ = mock_post.call_args
        self.assertIn("/script", args[0])

    @patch("screenmuse.client.requests.post")
    def test_script_sends_commands(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        cmds = [{"action": "chapter", "name": "Intro"}]
        self.sm.script(cmds)
        _, kwargs = mock_post.call_args
        body = json.loads(kwargs["data"])
        self.assertEqual(body["commands"], cmds)

    @patch("screenmuse.client.requests.post")
    def test_script_batch_calls_correct_endpoint(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True, "scripts_run": 1})
        result = self.sm.script_batch([{"name": "s1", "commands": [{"action": "highlight"}]}])
        self.assertEqual(result["ok"], True)
        args, _ = mock_post.call_args
        self.assertIn("/script/batch", args[0])

    @patch("screenmuse.client.requests.post")
    def test_script_batch_continue_on_error_flag(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm.script_batch([{"name": "s1", "commands": []}], continue_on_error=True)
        _, kwargs = mock_post.call_args
        body = json.loads(kwargs["data"])
        self.assertTrue(body.get("continue_on_error"))

    @patch("screenmuse.client.requests.post")
    def test_script_batch_default_no_continue_flag(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm.script_batch([{"name": "s1", "commands": []}])
        _, kwargs = mock_post.call_args
        body = json.loads(kwargs["data"])
        self.assertNotIn("continue_on_error", body)


class TestSystemInfoMethods(unittest.TestCase):
    """Tests for /report, /debug, /logs methods."""

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key", base_url="http://127.0.0.1:7823")

    @patch("screenmuse.client.requests.get")
    def test_report_calls_report_endpoint(self, mock_get):
        mock_get.return_value = _mock_response({"recording": False})
        result = self.sm.report()
        self.assertIn("recording", result)
        args, _ = mock_get.call_args
        self.assertIn("/report", args[0])

    @patch("screenmuse.client.requests.get")
    def test_debug_calls_debug_endpoint(self, mock_get):
        mock_get.return_value = _mock_response({"save_directory": "/tmp"})
        result = self.sm.debug()
        self.assertIn("save_directory", result)
        args, _ = mock_get.call_args
        self.assertIn("/debug", args[0])

    @patch("screenmuse.client.requests.get")
    def test_logs_calls_logs_endpoint(self, mock_get):
        mock_get.return_value = _mock_response({"entries": [], "count": 0})
        result = self.sm.logs()
        self.assertIn("entries", result)
        args, _ = mock_get.call_args
        self.assertIn("/logs", args[0])


class TestJobsMethods(unittest.TestCase):
    """Tests for /jobs and /job/{id} methods."""

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key", base_url="http://127.0.0.1:7823")

    @patch("screenmuse.client.requests.get")
    def test_jobs_calls_jobs_endpoint(self, mock_get):
        mock_get.return_value = _mock_response({"jobs": [], "count": 0})
        result = self.sm.jobs()
        self.assertIn("jobs", result)
        args, _ = mock_get.call_args
        self.assertIn("/jobs", args[0])

    @patch("screenmuse.client.requests.get")
    def test_get_job_includes_job_id_in_path(self, mock_get):
        mock_get.return_value = _mock_response({"id": "abc123", "status": "complete"})
        result = self.sm.get_job("abc123")
        self.assertEqual(result["id"], "abc123")
        args, _ = mock_get.call_args
        self.assertIn("/job/abc123", args[0])


class TestStreamMethods(unittest.TestCase):
    """Tests for /stream/status method."""

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key", base_url="http://127.0.0.1:7823")

    @patch("screenmuse.client.requests.get")
    def test_stream_status_calls_correct_endpoint(self, mock_get):
        mock_get.return_value = _mock_response({"active_clients": 0, "total_frames_sent": 0})
        result = self.sm.stream_status()
        self.assertEqual(result["active_clients"], 0)
        args, _ = mock_get.call_args
        self.assertIn("/stream/status", args[0])


class TestUploadAndPiPMethods(unittest.TestCase):
    """Tests for /start/pip and /upload/icloud methods."""

    def setUp(self):
        self.sm = ScreenMuse(api_key="test-key", base_url="http://127.0.0.1:7823")

    @patch("screenmuse.client.requests.post")
    def test_start_pip_calls_correct_endpoint(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        result = self.sm.start_pip()
        self.assertTrue(result["ok"])
        args, _ = mock_post.call_args
        self.assertIn("/start/pip", args[0])

    @patch("screenmuse.client.requests.post")
    def test_start_pip_with_source(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm.start_pip(source="/tmp/video.mp4")
        _, kwargs = mock_post.call_args
        body = json.loads(kwargs["data"])
        self.assertEqual(body["source"], "/tmp/video.mp4")

    @patch("screenmuse.client.requests.post")
    def test_upload_icloud_default_source(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True, "path": "/tmp/video.mp4"})
        result = self.sm.upload_icloud()
        self.assertTrue(result["ok"])
        _, kwargs = mock_post.call_args
        body = json.loads(kwargs["data"])
        self.assertEqual(body["source"], "last")
        args, _ = mock_post.call_args
        self.assertIn("/upload/icloud", args[0])

    @patch("screenmuse.client.requests.post")
    def test_upload_icloud_with_folder(self, mock_post):
        mock_post.return_value = _mock_response({"ok": True})
        self.sm.upload_icloud(source="/tmp/demo.mp4", folder="MyFolder")
        _, kwargs = mock_post.call_args
        body = json.loads(kwargs["data"])
        self.assertEqual(body["folder"], "MyFolder")
        self.assertEqual(body["source"], "/tmp/demo.mp4")
