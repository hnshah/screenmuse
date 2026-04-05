#!/bin/bash

# Test script for QA feature
# Tests the /qa endpoint with sample videos

set -e

echo "=== ScreenMuse QA Feature Test ==="
echo

# Check if ScreenMuse is running
if ! curl -s http://localhost:9090/health > /dev/null 2>&1; then
    echo "❌ ScreenMuse server not running. Start it with:"
    echo "   .build/debug/ScreenMuseApp"
    exit 1
fi

echo "✅ Server is running"
echo

# Check for test videos
TEST_DIR="/tmp/screenmuse-qa-test"
mkdir -p "$TEST_DIR"

# Create a test video if it doesn't exist
ORIGINAL="$TEST_DIR/original.mp4"
PROCESSED="$TEST_DIR/processed.mp4"

if [ ! -f "$ORIGINAL" ]; then
    echo "Creating test video..."
    # Create a 5-second test video with ffmpeg
    ffmpeg -f lavfi -i testsrc=duration=5:size=1920x1080:rate=30 \
           -f lavfi -i sine=frequency=1000:duration=5 \
           -pix_fmt yuv420p -c:v libx264 -c:a aac \
           "$ORIGINAL" -y 2>&1 | grep -i "video\|audio\|time" || true
    echo "✅ Created original.mp4"
fi

if [ ! -f "$PROCESSED" ]; then
    echo "Creating processed video (trimmed)..."
    ffmpeg -i "$ORIGINAL" -t 3 -c copy "$PROCESSED" -y 2>&1 | grep -i "video\|audio\|time" || true
    echo "✅ Created processed.mp4 (3 seconds)"
fi

echo
echo "=== Test 1: Basic QA Analysis ==="
echo "Request:"
echo "  POST /qa"
echo "  Body: {\"original\": \"$ORIGINAL\", \"processed\": \"$PROCESSED\"}"
echo

RESPONSE=$(curl -s -X POST http://localhost:9090/qa \
    -H "Content-Type: application/json" \
    -d "{\"original\": \"$ORIGINAL\", \"processed\": \"$PROCESSED\"}")

echo "Response:"
echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
echo

# Check if response is valid JSON with expected fields
if echo "$RESPONSE" | jq -e '.quality_checks' > /dev/null 2>&1; then
    echo "✅ QA analysis completed successfully"
    
    # Extract key metrics
    echo
    echo "=== Quality Checks ==="
    echo "$RESPONSE" | jq -r '.quality_checks[] | "[\(.id)] \(.name): \(if .passed then "✅ PASS" else "❌ FAIL" end) - \(.message)"'
    
    echo
    echo "=== Metrics ==="
    echo "$RESPONSE" | jq -r '
        "Original Duration: \(.videos.original.duration)s",
        "Processed Duration: \(.videos.processed.duration)s", 
        "Duration Change: \(.changes.duration_change_seconds)s (\(.changes.duration_change_percent)%)",
        "File Size Change: \(.changes.file_size_change_percent)%"
    '
else
    echo "❌ Invalid response or analysis failed"
    exit 1
fi

echo
echo "=== Test 2: Edge Case - Missing File ==="
RESPONSE=$(curl -s -X POST http://localhost:9090/qa \
    -H "Content-Type: application/json" \
    -d '{"original": "/nonexistent.mp4", "processed": "/also-nonexistent.mp4"}')

if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    echo "✅ Correctly rejected missing files"
    echo "   Error: $(echo "$RESPONSE" | jq -r '.error')"
else
    echo "⚠️  Did not return error for missing files"
fi

echo
echo "=== Test 3: Edge Case - Invalid Parameters ==="
RESPONSE=$(curl -s -X POST http://localhost:9090/qa \
    -H "Content-Type: application/json" \
    -d '{}')

if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    echo "✅ Correctly rejected empty request"
    echo "   Error: $(echo "$RESPONSE" | jq -r '.error')"
else
    echo "⚠️  Did not return error for empty request"
fi

echo
echo "=== All Tests Complete ==="
echo "Test videos saved in: $TEST_DIR"
