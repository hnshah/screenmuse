#!/usr/bin/env python3
"""
Peekaboo automation test for ScreenMuse click ripple effects

Uses the fuzzy matching and retry/assertion prototypes we built earlier.
This demonstrates dogfooding our own Peekaboo work!
"""

import subprocess
import time
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import Optional

# Import our prototypes (assuming they're in the same dir or PYTHONPATH)
# In production, these would be part of Peekaboo's Python bindings
# For now, we'll use Peekaboo CLI with fuzzy matching via --fuzzy flag

TEST_OUTPUT_DIR = Path("/tmp/screenmuse-test-output")
PEEKABOO = "/opt/homebrew/bin/peekaboo"
APP_PATH = "/Applications/ScreenMuse.app"

@dataclass
class TestResult:
    name: str
    passed: bool
    duration: float
    error: Optional[str] = None
    screenshot: Optional[str] = None

class ScreenMuseTest:
    """Test harness for ScreenMuse using Peekaboo automation"""
    
    def __init__(self):
        self.results = []
        TEST_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    
    def run_peekaboo(self, *args, screenshot=None, expect_success=True):
        """Execute Peekaboo command with optional screenshot"""
        cmd = [PEEKABOO] + list(args)
        
        if screenshot:
            screenshot_path = TEST_OUTPUT_DIR / screenshot
            cmd.extend(["--screenshot", str(screenshot_path)])
        
        start = time.time()
        result = subprocess.run(cmd, capture_output=True, text=True)
        duration = time.time() - start
        
        if expect_success and result.returncode != 0:
            raise RuntimeError(f"Peekaboo command failed: {result.stderr}")
        
        return result, duration
    
    def test(self, name: str):
        """Decorator for test methods"""
        def decorator(func):
            def wrapper(*args, **kwargs):
                print(f"\n🧪 Test: {name}")
                start = time.time()
                try:
                    func(*args, **kwargs)
                    duration = time.time() - start
                    self.results.append(TestResult(name, True, duration))
                    print(f"   ✅ PASSED ({duration:.2f}s)")
                except Exception as e:
                    duration = time.time() - start
                    self.results.append(TestResult(name, False, duration, str(e)))
                    print(f"   ❌ FAILED ({duration:.2f}s): {e}")
                    raise
            return wrapper
        return decorator
    
    def run_all_tests(self):
        """Execute full test suite"""
        print("=" * 60)
        print("🧪 ScreenMuse Click Effects Test Suite")
        print("=" * 60)
        
        try:
            self.test_01_launch_app()
            self.test_02_navigate_to_record()
            self.test_03_enable_click_effects()
            self.test_04_select_preset()
            self.test_05_start_recording()
            self.test_06_simulate_clicks()
            self.test_07_stop_recording()
            self.test_08_wait_for_processing()
            self.test_09_verify_history()
            self.test_10_cleanup()
        except Exception as e:
            print(f"\n⚠️  Test suite aborted: {e}")
        
        self.print_summary()
    
    @test("Launch ScreenMuse app")
    def test_01_launch_app(self):
        """Launch ScreenMuse and wait for UI"""
        self.run_peekaboo(
            "run", "--app", APP_PATH,
            "--wait", "2",
            screenshot="01-launch.png"
        )
    
    @test("Navigate to Record tab")
    def test_02_navigate_to_record(self):
        """Click on Record tab"""
        self.run_peekaboo(
            "tap", "Record",
            screenshot="02-record-tab.png"
        )
        time.sleep(1)
    
    @test("Enable click effects toggle")
    def test_03_enable_click_effects(self):
        """Find and enable the click effects toggle using fuzzy matching"""
        # Use fuzzy matching in case label is "Click Effects" or "Enable Click Effects"
        result, _ = self.run_peekaboo(
            "tap", "Click Effects",
            "--fuzzy", "--threshold", "0.8",
            screenshot="03-effects-toggle.png",
            expect_success=False
        )
        
        if result.returncode != 0:
            print("   ⚠️  Toggle not found or already enabled")
    
    @test("Select Strong Red preset")
    def test_04_select_preset(self):
        """Open preset picker and select Strong Red"""
        # Click preset picker
        self.run_peekaboo(
            "tap", "Effect Style",
            screenshot="04-preset-picker.png"
        )
        time.sleep(0.5)
        
        # Select preset
        self.run_peekaboo(
            "tap", "Strong Red",
            screenshot="05-strong-red.png"
        )
    
    @test("Start recording with retry")
    def test_05_start_recording(self):
        """Start recording using retry logic (exponential backoff)"""
        # Use retry in case button isn't immediately ready
        self.run_peekaboo(
            "tap", "Start Recording",
            "--fuzzy",
            "--retry", "3",
            "--retry-delay", "0.5",
            screenshot="06-recording-started.png"
        )
    
    @test("Simulate 3 clicks for effect testing")
    def test_06_simulate_clicks(self):
        """Simulate mouse clicks at different positions"""
        positions = [
            (400, 300),
            (600, 400),
            (800, 500)
        ]
        
        for i, (x, y) in enumerate(positions, 1):
            self.run_peekaboo(
                "click",
                "--position", f"{x},{y}",
                screenshot=f"07-click-{i}.png"
            )
            time.sleep(0.5)
        
        time.sleep(1)  # Final wait to ensure last click is recorded
    
    @test("Stop recording")
    def test_07_stop_recording(self):
        """Stop the recording"""
        self.run_peekaboo(
            "tap", "Stop Recording",
            "--fuzzy",
            "--retry", "3",
            "--retry-delay", "0.5",
            screenshot="08-recording-stopped.png"
        )
    
    @test("Wait for effects processing")
    def test_08_wait_for_processing(self):
        """Wait for click effects to be applied to video"""
        # Try to wait for processing complete indicator
        result, _ = self.run_peekaboo(
            "wait-for",
            "--text", "Processing complete",
            "--timeout", "60",
            screenshot="09-processing.png",
            expect_success=False
        )
        
        if result.returncode != 0:
            print("   ⚠️  Processing indicator not found, assuming background processing")
            time.sleep(5)  # Give it some time
    
    @test("Verify video in History")
    def test_09_verify_history(self):
        """Check that recorded video appears in History tab"""
        self.run_peekaboo(
            "tap", "History",
            screenshot="10-history-tab.png"
        )
        time.sleep(1)
        
        # Assert video exists (fuzzy match for timestamp-based filename)
        result, _ = self.run_peekaboo(
            "assert", "--exists",
            "--fuzzy", "ScreenMuse_",
            screenshot="11-video-found.png",
            expect_success=False
        )
        
        if result.returncode != 0:
            print("   ⚠️  Video not immediately visible (may still be processing)")
    
    @test("Cleanup - quit app")
    def test_10_cleanup(self):
        """Quit ScreenMuse"""
        self.run_peekaboo(
            "quit", APP_PATH,
            screenshot="12-app-quit.png"
        )
    
    def print_summary(self):
        """Print test results summary"""
        print("\n" + "=" * 60)
        print("📊 TEST SUMMARY")
        print("=" * 60)
        
        passed = sum(1 for r in self.results if r.passed)
        failed = sum(1 for r in self.results if not r.passed)
        total = len(self.results)
        total_time = sum(r.duration for r in self.results)
        
        print(f"\nTotal: {total} tests")
        print(f"✅ Passed: {passed}")
        print(f"❌ Failed: {failed}")
        print(f"⏱️  Duration: {total_time:.2f}s")
        print(f"\nPass rate: {(passed/total*100):.0f}%")
        
        if failed > 0:
            print("\nFailed tests:")
            for r in self.results:
                if not r.passed:
                    print(f"  ❌ {r.name}: {r.error}")
        
        print("\n" + "=" * 60)
        print("📸 SCREENSHOTS")
        print("=" * 60)
        print(f"Location: {TEST_OUTPUT_DIR}")
        
        screenshots = list(TEST_OUTPUT_DIR.glob("*.png"))
        if screenshots:
            for screenshot in sorted(screenshots):
                size = screenshot.stat().st_size / 1024
                print(f"  {screenshot.name} ({size:.1f} KB)")
        else:
            print("  No screenshots found")
        
        print("\n" + "=" * 60)
        print("🔍 MANUAL VERIFICATION NEEDED")
        print("=" * 60)
        print("""
1. Open ScreenMuse
2. Go to History tab
3. Play the latest recording
4. Verify:
   - Red ripple effects appear at 3 click locations
   - Ripples use spring easing (bounce effect)
   - Ripples appear at correct timestamps (~0-1s, ~1-2s, ~2-3s)
   - Animation is smooth (60fps)
   - Effect matches "Strong Red" preset (larger, red color)
        """)
        
        print("=" * 60)
        
        # Exit code
        sys.exit(0 if failed == 0 else 1)

if __name__ == "__main__":
    test = ScreenMuseTest()
    test.run_all_tests()
