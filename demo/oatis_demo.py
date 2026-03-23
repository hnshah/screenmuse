#!/usr/bin/env python3
"""
oatis_demo.py — Automated demo of ScreenMuse by Oatis.

Produces a self-running demo video showing an AI agent controlling ScreenMuse.
Run this on a Mac with ScreenMuse running.

Usage:
  python3 demo/oatis_demo.py

Story:
  1. AI agent starts recording
  2. Agent does work (opens Terminal, types commands, opens a file)
  3. Agent marks an important moment
  4. Agent stops — here is the video
"""

import time
import json
import subprocess
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../clients/python"))

try:
    from screenmuse import ScreenMuse
except ImportError:
    print("Error: Install screenmuse client first: pip install -e clients/python")
    sys.exit(1)


def osascript(script: str) -> str:
    """Run AppleScript and return stdout."""
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return result.stdout.strip()


def type_slowly(app: str, text: str, delay: float = 0.04):
    """Type text into an app character by character using AppleScript."""
    for char in text:
        escaped = char.replace("\\", "\\\\").replace('"', '\\"')
        osascript(
            f'tell application "System Events" to tell process "{app}" '
            f'to keystroke "{escaped}"'
        )
        time.sleep(delay)


def press_key(app: str, key: str, modifier: str = None):
    """Press a key in an app using AppleScript."""
    if modifier:
        osascript(
            f'tell application "System Events" to tell process "{app}" '
            f'to key code {key} using {modifier}'
        )
    else:
        osascript(
            f'tell application "System Events" to tell process "{app}" '
            f'to key code {key}'
        )


def say(text: str):
    """Print with timestamp."""
    print(f"[{time.strftime('%H:%M:%S')}] {text}")


def main():
    say("Oatis Demo — ScreenMuse Agent API")
    say("Starting ScreenMuse recording...")

    sm = ScreenMuse()

    # Check if ScreenMuse is running
    status = sm.status()
    if "error" in status:
        print("Error: ScreenMuse server not running on port 7823.")
        print("Start the ScreenMuse app first.")
        sys.exit(1)

    # Stop any existing recording
    if status.get("recording"):
        say("Stopping existing recording first...")
        sm.stop()
        time.sleep(1)

    # Start recording
    result = sm.start("oatis-screenmuse-demo")
    say(f"Recording started: session {result.get('session_id', 'unknown')}")
    time.sleep(1)

    # --- Chapter 1: Agent starts recording ---
    sm.mark_chapter("Agent starts recording")
    say("Chapter: Agent starts recording")
    time.sleep(2)

    # --- Chapter 2: Agent opens Terminal and does work ---
    sm.mark_chapter("Agent does work")
    say("Chapter: Agent does work")

    # Open Terminal
    osascript('tell application "Terminal" to activate')
    time.sleep(1.5)

    # Open a new window
    osascript(
        'tell application "Terminal" to do script '
        '"echo \\"=== ScreenMuse Demo ===\""'
    )
    time.sleep(1)

    # Type some commands to show the agent working
    type_slowly("Terminal", "echo 'Hello from Oatis — recording with ScreenMuse'")
    press_key("Terminal", "36")  # Return key
    time.sleep(1)

    type_slowly("Terminal", "date")
    press_key("Terminal", "36")  # Return key
    time.sleep(1)

    type_slowly("Terminal", "echo 'Agent is working...'")
    press_key("Terminal", "36")  # Return key
    time.sleep(1.5)

    # --- Chapter 3: Agent marks an important moment ---
    sm.mark_chapter("Important moment")
    say("Chapter: Important moment")

    # Highlight the next click
    sm.highlight_next_click()
    say("Highlighted next click")
    time.sleep(0.5)

    # Type the important command
    type_slowly("Terminal", "echo 'THIS IS THE KEY ACTION'")
    press_key("Terminal", "36")  # Return key
    time.sleep(2)

    # --- Chapter 4: Agent wraps up ---
    sm.mark_chapter("Agent wraps up")
    say("Chapter: Agent wraps up")

    type_slowly("Terminal", "echo 'Demo complete. Stopping recording.'")
    press_key("Terminal", "36")  # Return key
    time.sleep(2)

    # --- Stop recording ---
    say("Stopping recording...")
    result = sm.stop()

    video_path = result.get("video_path", "unknown")
    metadata = result.get("metadata", {})
    chapters = metadata.get("chapters", [])
    elapsed = metadata.get("elapsed", 0)

    say(f"Recording saved: {video_path}")
    say(f"Duration: {elapsed:.1f}s")
    say(f"Chapters: {len(chapters)}")
    for ch in chapters:
        say(f"  [{ch['time']:.1f}s] {ch['name']}")

    print()
    print(f"Video: {video_path}")


if __name__ == "__main__":
    main()
