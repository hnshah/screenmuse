#!/bin/bash
# Grant Screen Recording & Accessibility permissions to ScreenMuse
#
# This script:
# 1. Kills ScreenMuse if running
# 2. Opens System Settings to Screen Recording
# 3. Waits for you to enable ScreenMuse
# 4. Relaunches ScreenMuse
#
# Usage: ./scripts/grant-permissions.sh

set -e

BUNDLE_ID="ai.noats.screenmuse"
APP_PATH="$(pwd)/ScreenMuse.app"

echo "🔐 ScreenMuse Permission Helper"
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "❌ ScreenMuse.app not found at $APP_PATH"
    echo ""
    echo "Build it first:"
    echo "  ./scripts/build-cli.sh --only"
    exit 1
fi

# Kill running instance
echo "1. Stopping ScreenMuse..."
pkill -9 ScreenMuse 2>/dev/null || true
sleep 1

# Check current permission status
echo ""
echo "2. Checking current permissions..."
echo ""

# Try to get shareable content (will fail if no permission)
open "$APP_PATH"
sleep 2

# Open System Settings
echo "3. Opening System Settings..."
echo ""
echo "   📋 Steps:"
echo "   1. Look for 'Privacy & Security' in left sidebar"
echo "   2. Click 'Screen Recording'"
echo "   3. Find 'ScreenMuse' in the list"
echo "   4. Enable the checkbox"
echo "   5. Come back here and press ENTER"
echo ""

open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

echo "   Waiting for you to enable permissions..."
read -p "   Press ENTER when done: " _

# Kill and relaunch
echo ""
echo "4. Relaunching ScreenMuse..."
pkill -9 ScreenMuse 2>/dev/null || true
sleep 1

open "$APP_PATH"
sleep 3

# Test if server responds
echo ""
echo "5. Testing server..."

if curl -s http://localhost:7823/status >/dev/null 2>&1; then
    echo "   ✅ ScreenMuse is running!"
    echo ""
    echo "   Test it:"
    echo "   curl http://localhost:7823/status | jq '.'"
else
    echo "   ⚠️  Server not responding yet"
    echo ""
    echo "   Check logs:"
    echo "   tail -f ~/Movies/ScreenMuse/Logs/screenmuse-$(date +%Y-%m-%d).log"
fi

echo ""
echo "✅ Done!"
