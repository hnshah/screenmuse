#!/bin/bash
# Build ScreenMuse with TRULY stable code signature
#
# The problem: swift build creates different signatures every time
# The solution: 
#   1. Build once to a known location
#   2. Sign with explicit identifier + entitlements
#   3. NEVER rebuild unless code changes
#   4. Permissions persist forever!

set -e

LAUNCH=true
FORCE=false

for arg in "$@"; do
    case $arg in
        --only) LAUNCH=false ;;
        --force) FORCE=true ;;
    esac
done

APP_DIR="./ScreenMuse.app"
BINARY="$APP_DIR/Contents/MacOS/ScreenMuse"

# Check if app already exists and is signed
if [ -f "$BINARY" ] && [ "$FORCE" != "true" ]; then
    echo "📦 Checking existing app bundle..."
    
    # Verify it's signed with our bundle ID
    EXISTING_ID=$(codesign -d -vvv "$APP_DIR" 2>&1 | grep "Identifier=" | cut -d= -f2)
    
    if [ "$EXISTING_ID" = "ai.noats.screenmuse" ]; then
        echo "✅ App bundle exists with correct signature"
        echo "   Use --force to rebuild anyway"
        echo ""
        
        if [ "$LAUNCH" = "true" ]; then
            echo "🚀 Launching existing app..."
            open "$APP_DIR"
            
            sleep 3
            if curl -s http://localhost:7823/status >/dev/null 2>&1; then
                echo "✅ Server running on port 7823"
            else
                echo "⚠️  Server not responding (check permissions)"
            fi
        fi
        
        exit 0
    else
        echo "⚠️  Existing app has wrong signature: $EXISTING_ID"
        echo "   Rebuilding..."
    fi
fi

echo "🔨 Building ScreenMuse (this may take 10-15 seconds)..."

# Build binary
swift build -c release 2>&1 | grep -E "error:|warning:|Build complete" || true

BUILT_BINARY=".build/arm64-apple-macosx/release/ScreenMuseApp"

if [ ! -f "$BUILT_BINARY" ]; then
    echo "❌ Build failed - binary not found at $BUILT_BINARY"
    exit 1
fi

echo "✅ Binary built"

# Clean old bundle
rm -rf "$APP_DIR"

# Create bundle structure
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy binary
cp "$BUILT_BINARY" "$MACOS/ScreenMuse"

# Copy Info.plist
cp "Sources/ScreenMuseApp/Resources/Info.plist" "$CONTENTS/Info.plist"

# Create PkgInfo
echo "APPL????" > "$CONTENTS/PkgInfo"

echo "✅ App bundle created"

# Code sign with STABLE identifier
echo "✍️  Code signing with stable identifier..."

codesign --force --deep --sign - \
    --identifier "ai.noats.screenmuse" \
    --entitlements "ScreenMuse.entitlements" \
    --options runtime \
    "$APP_DIR" 2>&1 | grep -v "replacing existing signature" || true

echo "✅ Code signed"

# Verify
SIGNED_ID=$(codesign -d -vvv "$APP_DIR" 2>&1 | grep "^Identifier=" | cut -d= -f2)
echo ""
echo "📋 Bundle ID: $SIGNED_ID"

if [ "$SIGNED_ID" != "ai.noats.screenmuse" ]; then
    echo "❌ ERROR: Signature mismatch!"
    echo "   Expected: ai.noats.screenmuse"
    echo "   Got: $SIGNED_ID"
    exit 1
fi

echo "✅ Build complete!"
echo ""
echo "⚠️  IMPORTANT:"
echo "   This is the ONLY build you need!"
echo "   Don't rebuild unless code changes."
echo "   Permissions will persist for THIS build."
echo ""

if [ "$LAUNCH" = "true" ]; then
    echo "🚀 Launching ScreenMuse..."
    
    # Kill old instance
    pkill -9 ScreenMuse 2>/dev/null || true
    sleep 1
    
    open "$APP_DIR"
    sleep 4
    
    echo ""
    if curl -s http://localhost:7823/status >/dev/null 2>&1; then
        echo "✅ Server running on port 7823"
    else
        echo "⚠️  Server not responding"
        echo ""
        echo "   If this is first launch:"
        echo "   1. macOS will show permission dialog"
        echo "   2. Grant Screen Recording permission"
        echo "   3. Relaunch: open $APP_DIR"
        echo ""
        echo "   Check logs:"
        echo "   tail -f ~/Movies/ScreenMuse/Logs/screenmuse-$(date +%Y-%m-%d).log"
    fi
fi
