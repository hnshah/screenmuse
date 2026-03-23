#!/bin/bash
# Reset ScreenMuse TCC permissions so macOS prompts you again
# Use this after rebuilding with swift build if permissions are stuck/denied

echo "🔄 Resetting ScreenMuse TCC permissions..."

# Reset Screen Recording permission
tccutil reset ScreenCapture ai.noats.screenmuse 2>/dev/null || \
    tccutil reset ScreenCapture 2>/dev/null

# Reset Accessibility permission
tccutil reset Accessibility ai.noats.screenmuse 2>/dev/null || true

echo "✅ Done. Relaunch ScreenMuse — it will prompt you to grant permissions again."
echo ""
echo "After granting: System Settings → Privacy & Security → Screen Recording"
echo "ScreenMuse should appear there with the toggle ON."
echo ""
echo "💡 To avoid needing this script: use ./scripts/dev-run.sh instead of swift build"
echo "   xcodebuild produces a consistently-signed app that TCC recognizes between builds."
