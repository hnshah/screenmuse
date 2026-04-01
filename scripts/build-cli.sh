#!/bin/bash
# Build ScreenMuse with stable bundle ID (no Xcode required)
# 
# This script solves the TCC permission issue by:
# 1. Building with swift build
# 2. Creating a proper .app bundle with Info.plist
# 3. Code signing with entitlements
# 4. Result: stable bundle ID that macOS TCC remembers
#
# Usage:
#   ./scripts/build-cli.sh        # build + launch
#   ./scripts/build-cli.sh --only # build only, no launch

set -e

LAUNCH=true
if [ "$1" = "--only" ]; then
    LAUNCH=false
fi

echo "🔨 Building ScreenMuse..."

# Build binary
swift build -c debug 2>&1 | grep -E "error:|warning:|Build complete" || true

BINARY=".build/arm64-apple-macosx/debug/ScreenMuseApp"

if [ ! -f "$BINARY" ]; then
    echo "❌ Build failed - binary not found at $BINARY"
    exit 1
fi

echo "✅ Binary built"

# Create proper app bundle
APP_DIR="./ScreenMuse.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "📦 Creating app bundle..."

# Clean old bundle
rm -rf "$APP_DIR"

# Create bundle structure
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy binary
cp "$BINARY" "$MACOS/ScreenMuse"

# Copy Info.plist
cp "Sources/ScreenMuseApp/Resources/Info.plist" "$CONTENTS/Info.plist"

# Create PkgInfo
echo "APPL????" > "$CONTENTS/PkgInfo"

echo "✅ App bundle created"

# Code sign with entitlements
echo "✍️  Code signing..."

codesign --force --deep --sign - \
    --entitlements "ScreenMuse.entitlements" \
    --identifier "ai.noats.screenmuse" \
    "$APP_DIR" 2>&1 | grep -v "replacing existing signature" || true

echo "✅ Code signed with bundle ID: ai.noats.screenmuse"

# Verify bundle ID
echo ""
echo "📋 Verifying bundle identifier..."
codesign -d -vvv "$APP_DIR" 2>&1 | grep "Identifier=" || true

echo ""
echo "✅ Build complete: $APP_DIR"
echo ""

if [ "$LAUNCH" = true ]; then
    echo "🚀 Launching ScreenMuse..."
    echo ""
    echo "⚠️  IMPORTANT:"
    echo "   If this is first launch or you just rebuilt:"
    echo "   1. macOS will show Screen Recording permission dialog"
    echo "   2. Click 'Open System Settings'"
    echo "   3. Enable ScreenMuse in Privacy & Security → Screen Recording"
    echo "   4. Relaunch this script"
    echo ""
    
    # Kill old instance
    pkill -9 ScreenMuse 2>/dev/null || true
    sleep 1
    
    # Launch
    open "$APP_DIR"
    
    # Wait a bit and check if server started
    sleep 3
    
    echo "Checking if server started..."
    if curl -s http://localhost:7823/status >/dev/null 2>&1; then
        echo "✅ Server running on port 7823"
    else
        echo "⚠️  Server not responding (might need permissions)"
        echo ""
        echo "Check logs:"
        echo "  tail -f ~/Movies/ScreenMuse/Logs/screenmuse-$(date +%Y-%m-%d).log"
    fi
fi
