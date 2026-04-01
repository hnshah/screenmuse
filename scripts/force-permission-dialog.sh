#!/bin/bash
# Force ScreenMuse to appear in permission dialogs
#
# This script:
# 1. Launches ScreenMuse
# 2. Triggers permission requests
# 3. Tells you exactly what to do

set -e

APP_PATH="$(pwd)/ScreenMuse.app"

echo "🔐 Force Permission Dialog Helper"
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "❌ ScreenMuse.app not found"
    echo ""
    echo "Build it first:"
    echo "  ./scripts/build-cli.sh --only"
    exit 1
fi

echo "1. Launching ScreenMuse..."
echo ""

# Kill old instance
pkill -9 ScreenMuse 2>/dev/null || true
sleep 1

# Launch app (this will trigger permission dialog)
open "$APP_PATH"

echo "2. ScreenMuse is launching..."
echo ""
echo "   You should see a permission dialog pop up NOW."
echo ""
echo "   📋 If you see the dialog:"
echo "      Click 'Open System Settings' button"
echo ""
echo "   📋 If you DON'T see a dialog:"
echo "      The app might already have been denied before."
echo "      Let's manually add it..."
echo ""

sleep 3

# Check if app started
if ps aux | grep -v grep | grep -q ScreenMuse; then
    echo "   ✅ ScreenMuse is running (PID: $(pgrep ScreenMuse))"
else
    echo "   ⚠️  ScreenMuse didn't start (permission probably denied)"
fi

echo ""
echo "3. Opening System Settings manually..."
echo ""
echo "   📋 STEP-BY-STEP:"
echo ""
echo "   For Screen Recording:"
echo "   1. System Settings → Privacy & Security"
echo "   2. Click 'Screen Recording' in the left sidebar"
echo "   3. Look for 'ScreenMuse' in the list"
echo "   4. If NOT in list: Click the (+) button at bottom"
echo "   5. Navigate to: $(pwd)/ScreenMuse.app"
echo "   6. Click 'Open' to add it"
echo "   7. Enable the checkbox next to ScreenMuse"
echo ""
echo "   For Accessibility (optional, for keystroke overlays):"
echo "   1. Same place: Privacy & Security"
echo "   2. Click 'Accessibility' in the left sidebar"  
echo "   3. Same steps: add ScreenMuse.app if not in list"
echo ""

# Open Screen Recording settings
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

echo "   Waiting for you to enable permissions..."
echo ""
read -p "   Press ENTER when you've enabled Screen Recording: " _

echo ""
echo "4. Relaunching ScreenMuse..."

pkill -9 ScreenMuse 2>/dev/null || true
sleep 1
open "$APP_PATH"
sleep 4

echo ""
echo "5. Testing if it worked..."

if curl -s http://localhost:7823/status >/dev/null 2>&1; then
    echo "   ✅ SUCCESS! Server is running on port 7823"
    echo ""
    echo "   Test it:"
    echo "   curl http://localhost:7823/status | jq '.'"
else
    echo "   ⚠️  Server still not responding"
    echo ""
    echo "   Check the logs for permission errors:"
    echo "   tail -30 ~/Movies/ScreenMuse/Logs/screenmuse-$(date +%Y-%m-%d).log"
    echo ""
    echo "   Look for this line:"
    echo "   'Screen Recording permission NOT granted'"
fi

echo ""
echo "Done!"
