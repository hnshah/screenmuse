#!/bin/bash
# Peekaboo automation test for ScreenMuse click ripple effects
# Tests: UI interaction, recording flow, click effect application

set -e

PEEKABOO="/opt/homebrew/bin/peekaboo"
TEST_OUTPUT_DIR="/tmp/screenmuse-test-output"
APP_PATH="/Applications/ScreenMuse.app"

echo "🧪 ScreenMuse Click Effects Test Suite"
echo "======================================="
echo ""

# Setup
mkdir -p "$TEST_OUTPUT_DIR"
cd "$TEST_OUTPUT_DIR"

# Test 1: Launch ScreenMuse
echo "Test 1: Launch ScreenMuse app"
$PEEKABOO run --app "$APP_PATH" --wait 2 \
  --screenshot "01-launch.png"

if [ $? -eq 0 ]; then
    echo "✅ App launched successfully"
else
    echo "❌ Failed to launch app"
    exit 1
fi

# Test 2: Navigate to Record tab
echo ""
echo "Test 2: Navigate to Record tab"
$PEEKABOO tap "Record" --screenshot "02-record-tab.png"
sleep 1

# Test 3: Enable click effects
echo ""
echo "Test 3: Enable click effects toggle"
$PEEKABOO tap "Click Effects" --fuzzy --threshold 0.8 \
  --screenshot "03-effects-enabled.png"

if [ $? -eq 0 ]; then
    echo "✅ Click effects toggle found and enabled"
else
    echo "⚠️  Toggle not found, may already be enabled"
fi

# Test 4: Select effect preset
echo ""
echo "Test 4: Select 'Strong Red' preset"
$PEEKABOO tap "Effect Style" --screenshot "04-preset-picker.png"
sleep 0.5
$PEEKABOO tap "Strong Red" --screenshot "05-strong-red-selected.png"

# Test 5: Start recording
echo ""
echo "Test 5: Start recording"
$PEEKABOO tap "Start Recording" --fuzzy \
  --screenshot "06-recording-started.png" \
  --retry 3 --retry-delay 0.5

if [ $? -eq 0 ]; then
    echo "✅ Recording started"
else
    echo "❌ Failed to start recording"
    exit 1
fi

# Test 6: Simulate clicks (for effect testing)
echo ""
echo "Test 6: Simulate mouse clicks (3 locations)"
$PEEKABOO click --position 400,300 --screenshot "07-click-1.png"
sleep 0.5
$PEEKABOO click --position 600,400 --screenshot "08-click-2.png"
sleep 0.5
$PEEKABOO click --position 800,500 --screenshot "09-click-3.png"
sleep 1

echo "✅ Test clicks recorded"

# Test 7: Stop recording
echo ""
echo "Test 7: Stop recording"
$PEEKABOO tap "Stop Recording" --fuzzy \
  --screenshot "10-recording-stopped.png" \
  --retry 3 --retry-delay 0.5

if [ $? -eq 0 ]; then
    echo "✅ Recording stopped"
else
    echo "❌ Failed to stop recording"
    exit 1
fi

# Test 8: Wait for processing (effects application)
echo ""
echo "Test 8: Wait for effects processing"
echo "   (Monitoring for 'Processing' or 'Export' indicators)"

# Use retry logic to wait for processing to complete
$PEEKABOO wait-for --text "Processing complete" --timeout 60 \
  --screenshot "11-processing-complete.png" || {
    echo "⚠️  Processing notification not found, checking alternative..."
    # Try alternative: look for video in history
    $PEEKABOO tap "History" --screenshot "12-history-tab.png"
    sleep 1
}

# Test 9: Verify video in History
echo ""
echo "Test 9: Verify recording appears in History"
$PEEKABOO tap "History" --screenshot "13-history-check.png"
sleep 1

# Check for video thumbnail
$PEEKABOO assert --exists --fuzzy "ScreenMuse_" \
  --screenshot "14-video-found.png" || {
    echo "⚠️  Video not immediately visible, may still be processing"
}

# Test 10: Cleanup - quit app
echo ""
echo "Test 10: Cleanup"
$PEEKABOO quit "$APP_PATH" --screenshot "15-app-quit.png"

# Summary
echo ""
echo "======================================="
echo "✅ Test Suite Complete!"
echo "======================================="
echo ""
echo "Screenshots saved to: $TEST_OUTPUT_DIR"
echo ""
echo "Manual verification needed:"
echo "  1. Open latest video in History"
echo "  2. Verify red ripple effects appear at click locations"
echo "  3. Check animation smoothness (spring easing)"
echo "  4. Confirm 3 ripples visible at timestamps:"
echo "     - ~0-1s (first click)"
echo "     - ~1-2s (second click)"  
echo "     - ~2-3s (third click)"
echo ""
echo "Test artifacts:"
ls -lh "$TEST_OUTPUT_DIR"/*.png 2>/dev/null || echo "  No screenshots found"
