#!/bin/bash
# ScreenMuse dev build + run script
#
# Solves the TCC ad-hoc signing issue:
# - `swift build` produces a binary with a hash that changes every rebuild
# - macOS TCC (Screen Recording permission) identifies apps by code signature hash
# - So permissions must be re-granted on every `swift build` rebuild
#
# This script uses xcodebuild which produces a consistently-signed app
# that TCC recognizes between builds, so you only need to grant permissions ONCE.
#
# Usage:
#   ./scripts/dev-run.sh         # build + launch
#   ./scripts/dev-run.sh --build # build only, no launch
#   ./scripts/dev-run.sh --clean # clean build + launch

set -e

SCHEME="ScreenMuseApp"
CONFIG="Debug"
BUILD_DIR="$(pwd)/.xcode-build"
CLEAN=false
LAUNCH=true

for arg in "$@"; do
    case $arg in
        --clean) CLEAN=true ;;
        --build) LAUNCH=false ;;
    esac
done

echo "🔨 Building ScreenMuse via xcodebuild..."

if [ "$CLEAN" = true ]; then
    echo "🧹 Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
fi

# Build using Xcode's build system — handles code signing properly
# This works with Package.swift directly (no .xcodeproj needed, Xcode 13+)
xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | grep -E "(error:|warning:|Build succeeded|BUILD FAILED|remark:)" || true

APP_PATH=$(find "$BUILD_DIR" -name "ScreenMuseApp.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo ""
    echo "❌ xcodebuild failed or app not found."
    echo ""
    echo "Fallback: using swift build + manual sign..."
    echo "(Note: you may need to re-grant Screen Recording permission after each rebuild)"
    echo ""

    swift build -c debug 2>&1

    BINARY=".build/debug/ScreenMuseApp"
    if [ ! -f "$BINARY" ]; then
        echo "❌ swift build also failed. Check errors above."
        exit 1
    fi

    # Sign with entitlements to at least get the permission dialogs working
    codesign --force --deep --sign - \
        --entitlements "$(pwd)/ScreenMuse.entitlements" \
        "$BINARY" 2>/dev/null || true

    echo "✅ Built: $BINARY"

    if [ "$LAUNCH" = true ]; then
        echo "🚀 Launching..."
        exec "$BINARY"
    fi
    exit 0
fi

echo "✅ Built: $APP_PATH"

if [ "$LAUNCH" = true ]; then
    echo "🚀 Launching $APP_PATH..."
    open "$APP_PATH"
fi
