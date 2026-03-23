import requests
import json
from typing import Optional


class ScreenMuse:
    """Python client for ScreenMuse agent API (port 7823)."""

    def __init__(self, host: str = "localhost", port: int = 7823):
        self.base_url = f"http://{host}:{port}"

    def start(self, name: str) -> dict:
        """Start a new recording session."""
        r = requests.post(f"{self.base_url}/start", json={"name": name})
        r.raise_for_status()
        return r.json()

    def stop(self) -> dict:
        """Stop recording and return video path + metadata."""
        r = requests.post(f"{self.base_url}/stop")
        r.raise_for_status()
        return r.json()

    def mark_chapter(self, name: str) -> None:
        """Mark a chapter at the current timestamp."""
        requests.post(f"{self.base_url}/chapter", json={"name": name})

    def highlight_next_click(self) -> None:
        """Mark the next click as important (for auto-zoom)."""
        requests.post(f"{self.base_url}/highlight")

    def status(self) -> dict:
        """Get current recording status."""
        r = requests.get(f"{self.base_url}/status")
        r.raise_for_status()
        return r.json()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        if self.status().get("recording"):
            self.stop()
