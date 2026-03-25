
# ScreenMuse Media Sharing Setup

**Goal:** Share screenshots and videos from ScreenMuse development with Hiten

---

## Quick Start (Recommended)

### Option 1: Local Web Viewer ⭐ **EASIEST**

```bash
# Start the viewer
python3 screenmuse-viewer.py

# Open in browser
open http://localhost:8080
```

**What you get:**
- 📸 All screenshots in a gallery
- 🎥 Videos with inline playback
- 🔄 Auto-refreshes when new files appear
- 💾 Download links for everything

**Perfect for:** Quick iteration, showing progress, debugging

---

### Option 2: Direct Telegram Upload

```bash
# Setup (one-time)
export TELEGRAM_BOT_TOKEN="your_bot_token"
export TELEGRAM_CHAT_ID="24087015"  # Hiten's chat ID

# Send screenshot
./screenmuse-send-to-telegram.sh /path/to/screenshot.png "Check this out!"

# Send video
./screenmuse-send-to-telegram.sh /path/to/video.mp4 "Click effects demo"
```

**What you get:**
- 📱 Files appear directly in Telegram
- 💬 With captions
- ⚡ Instant delivery

**Perfect for:** Sharing final results, async updates

---

### Option 3: Show in Chat (My Perspective)

I can show images directly using the `image` tool:

```python
# When I have a screenshot
await image(image="/tmp/screenmuse-test-output/screenshot.png",
           prompt="Here's the click effect in action")
```

**What you get:**
- 🖼️ Images inline in our conversation
- 💭 With my analysis/explanation
- 📊 Can analyze multiple at once

**Perfect for:** Real-time discussion, comparing versions

---

## Detailed Setup

### Local Web Viewer

**File:** `screenmuse-viewer.py`

**Features:**
- Gallery view with thumbnails
- Video playback controls
- File size display
- Download buttons
- Responsive grid layout

**Usage:**
```bash
cd /tmp
python3 screenmuse-viewer.py

# Viewer runs at http://localhost:8080
# Serves: /tmp/screenmuse-test-output/
```

**Pro tip:** Keep it running during development, refresh browser to see new files

---

### Telegram Upload

**File:** `screenmuse-send-to-telegram.sh`

**Prerequisites:**
```bash
# Get bot token (if needed)
# 1. Message @BotFather on Telegram
# 2. Create new bot or use existing
# 3. Copy token

# Get your chat ID
# Already known: 24087015

# Set environment variables
export TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
export TELEGRAM_CHAT_ID="24087015"

# Test it
./screenmuse-send-to-telegram.sh screenshot.png "Test"
```

**Auto-send after tests:**
```bash
# Modify test script to auto-upload
cd screenmuse/Tests
chmod +x peekaboo-click-effects-test.sh

# Add at end:
for screenshot in /tmp/screenmuse-test-output/*.png; do
    ./screenmuse-send-to-telegram.sh "$screenshot" "Test screenshot"
done
```

---

### Cloudflare R2 (Production)

**File:** `screenmuse-media-uploader.sh`

**Setup:**
```bash
# 1. Create R2 bucket (Cloudflare dashboard)
# 2. Generate API token (R2 Read & Write)
# 3. Configure AWS CLI for R2

aws configure --profile r2
# Access Key: <R2 token>
# Secret Key: <R2 secret>
# Region: auto
# Output: json

# 4. Set environment variables
export R2_BUCKET="screenmuse-dev"
export R2_ENDPOINT="https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com"
export PUBLIC_URL_BASE="https://media.screenmuse.dev"

# 5. Upload
./screenmuse-media-uploader.sh screenshot.png
# Returns: https://media.screenmuse.dev/screenmuse/20260322-screenshot.png
```

**Benefits:**
- 🌍 Public URLs (shareable anywhere)
- ♾️ No expiration
- 💨 Fast CDN delivery
- 💰 Cheap (~$0.015/GB/month)

---

## Integration with ScreenMuse

### Auto-capture during tests

**Modify `peekaboo-click-effects-test.py`:**

```python
class ScreenMuseTest:
    def __init__(self):
        self.results = []
        self.media_urls = []
        TEST_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    
    def run_peekaboo(self, *args, screenshot=None, auto_share=True):
        """Execute Peekaboo with optional auto-sharing"""
        # ... existing code ...
        
        if screenshot and auto_share:
            screenshot_path = TEST_OUTPUT_DIR / screenshot
            
            # Option A: Upload to Telegram
            subprocess.run([
                "./screenmuse-send-to-telegram.sh",
                str(screenshot_path),
                f"Test: {screenshot}"
            ])
            
            # Option B: Just collect for later
            self.screenshots.append(screenshot_path)
        
        return result, duration
```

### Capture during recording

**Add to `RecordViewModel`:**

```swift
func stopRecording() async {
    // ... existing code ...
    
    // Auto-share preview screenshot
    if let thumbnail = generateThumbnail(from: outputURL) {
        let thumbnailPath = saveThumbnail(thumbnail)
        
        // Upload to Telegram
        Task.detached {
            await uploadToTelegram(thumbnailPath)
        }
    }
}

private func uploadToTelegram(_ filePath: String) async {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/tmp/screenmuse-send-to-telegram.sh")
    process.arguments = [filePath, "New recording completed"]
    try? process.run()
    process.waitUntilExit()
}
```

---

## Workflows

### Workflow 1: Show Progress During Development

```bash
# Terminal 1: Run tests
cd screenmuse/Tests
python3 peekaboo-click-effects-test.py

# Terminal 2: Start viewer
python3 /tmp/screenmuse-viewer.py

# Browser: Open http://localhost:8080
# Refresh to see new screenshots as tests run
```

### Workflow 2: Share Final Results

```bash
# After tests complete
cd /tmp/screenmuse-test-output

# Upload all screenshots
for file in *.png; do
    ../screenmuse-send-to-telegram.sh "$file" "ScreenMuse test: $file"
done

# Upload final video (if exists)
../screenmuse-send-to-telegram.sh latest-recording.mp4 "Click effects demo"
```

### Workflow 3: Real-time Collaboration

**Me (Ren):**
```python
# When I capture something interesting
image(image="/tmp/screenshot.png",
      prompt="Look at this spring easing curve - should we adjust the damping?")
```

**You (Hiten):**
- See image inline
- Provide feedback
- I iterate and show updated version

---

## File Organization

```
/tmp/screenmuse-test-output/
├── 01-launch.png                    # Peekaboo test screenshots
├── 02-record-tab.png
├── ...
├── 12-app-quit.png
├── recording-2026-03-22-2045.mp4    # Raw recording
├── recording-effects-applied.mp4    # With click effects
└── thumbnails/                       # Auto-generated previews
    ├── recording-thumb-1.png
    └── recording-thumb-2.png
```

---

## Best Practices

### For Development

1. **Keep viewer running** - Start once, refresh browser to see updates
2. **Descriptive names** - Use timestamps + feature names in filenames
3. **Delete old files** - Clean `/tmp/screenmuse-test-output/` between test runs
4. **Tag important shots** - Prefix with `KEEP-` to prevent cleanup

### For Sharing

1. **Captions matter** - Always include context: "Before fix" vs "After fix"
2. **Compress videos** - Use `ffmpeg` to reduce size before sharing:
   ```bash
   ffmpeg -i input.mp4 -vcodec libx264 -crf 28 output-compressed.mp4
   ```
3. **Thumbnails first** - Share a preview frame before the full video
4. **Batch uploads** - Group related screenshots in one message

---

## Troubleshooting

### Viewer shows empty gallery

**Fix:**
```bash
# Check if files exist
ls -lh /tmp/screenmuse-test-output/

# Create test file
echo "test" > /tmp/screenmuse-test-output/test.txt

# Refresh browser
```

### Telegram upload fails

**Fix:**
```bash
# Verify credentials
echo $TELEGRAM_BOT_TOKEN
echo $TELEGRAM_CHAT_ID

# Test with curl directly
curl -X POST \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "text=Test message"
```

### R2 upload permission denied

**Fix:**
```bash
# Re-configure AWS CLI
aws configure --profile r2

# Test connection
aws s3 ls s3://${R2_BUCKET} --endpoint-url ${R2_ENDPOINT} --profile r2
```

---

## Summary

**Recommended setup for ScreenMuse development:**

1. ✅ **Local viewer** - Always running during development
2. ✅ **Telegram upload** - For sharing final results
3. ⏭️ **R2 upload** - Only if you need persistent public URLs

**Quick start:**
```bash
cd /tmp
python3 screenmuse-viewer.py &
open http://localhost:8080
```

Now when I run tests or build features, you can see all screenshots/videos in real-time! 🎥
