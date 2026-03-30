# ScreenMuse Video Production Skill

**Produce high-quality demo videos autonomously using ScreenMuse + Playwright.**

---

## When to Use This Skill

**Trigger phrases:**
- "Record a video of..."
- "Create a demo showing..."
- "Capture this workflow..."
- "Make a video of searching for..."
- "Show how to..."
- "Record me doing..."

**Use for:**
- Product demos
- Tutorial videos
- User workflow captures
- Bug reproductions
- Competitive analysis recordings
- Landing page tours

**Don't use for:**
- Static screenshots (use `browser` tool snapshot)
- Long recordings (>2 minutes)
- Multiple windows simultaneously (not yet supported)

---

## Prerequisites

**Before starting ANY video production:**

```bash
# 1. Check ScreenMuse is running and API responding
curl -s http://localhost:7823/status
# Must return JSON. If not: restart ScreenMuse.app

# 2. Verify screen recording permission granted
# System Settings → Privacy & Security → Screen Recording → ScreenMuse ✓

# 3. Clean slate: close unnecessary browser windows/tabs
```

**If API not responding:** STOP. Write diagnostic note. Human must restart ScreenMuse.

---

## Video Production Process

### Step 1: Planning (MANDATORY)

**Never skip this.** Every video needs:

```javascript
const plan = {
  goal: "Show how to search for Stripe API docs",
  audience: "Developers evaluating ScreenMuse",
  duration: 20, // seconds
  scenes: [
    { time: "0-3s", action: "Google homepage", capture: "Initial state" },
    { time: "3-6s", action: "Type query", capture: "Typing + autocomplete" },
    { time: "6-12s", action: "View results", capture: "Results page" },
    { time: "12-16s", action: "Click result", capture: "Navigation" },
    { time: "16-20s", action: "Destination", capture: "Final page" }
  ],
  keyMoments: ["Query typed", "Results shown", "Clicked link", "Arrived at docs"]
};
```

**Ask yourself:**
- What is the ONE thing this video shows?
- Who watches this and why?
- What are the 3-5 key moments that MUST be captured?
- How long should it be? (15-30s ideal, 45s max)

---

### Step 2: Write the Shot List

**Template:**
```
Scene 1 (0-3s): [Starting state]
  Action: [What happens]
  Capture: [What we're recording]
  Wait: 2s

Scene 2 (3-6s): [Primary action]
  Action: [User does X]
  Capture: [Result of X]
  Wait: 1s

Scene 3 (6-12s): [Follow-up]
  ...
```

**Timing rules:**
- 2s pause at start (recording initialization)
- 1-2s between actions (visual clarity)
- Type slowly (150ms per character)
- Wait for page loads (`networkidle`)
- Total: 15-30 seconds ideal

---

### Step 3: Setup Script

**Browser config:**
```javascript
const browser = await chromium.launch({
  headless: false,
  args: [
    '--window-size=1400,900',  // Readable, not too big
    '--window-position=100,100' // Top-left, visible
  ]
});
```

**ScreenMuse config:**
```javascript
const recording = await axios.post('http://localhost:7823/start', {
  name: 'descriptive-name',     // google-search-stripe-api
  quality: 'high',               // Not 'max' (file size explosion)
  window_pid: chromePid          // NOT fullscreen
});
```

**Why these settings:**
- `1400x900` - Big enough to read, small enough for GIFs
- `window_pid` - Captures only browser, not whole screen
- `quality: high` - Balance of quality vs file size
- `100,100` position - Avoids screen edges/notch

---

### Step 4: Execute Recording

**Code structure:**
```javascript
// 1. Navigate to starting point
await page.goto('https://google.com');
await page.waitForLoadState('networkidle');
await page.waitForTimeout(2000); // Let settle

// 2. Get window PID
const windows = await axios.get('http://localhost:7823/windows');
const chrome = windows.data.windows.find(w => 
  w.app.includes('Chromium') || w.app.includes('Chrome')
);

// 3. Start recording
await axios.post('http://localhost:7823/start', {
  name: 'video-name',
  quality: 'high',
  window_pid: chrome.pid
});

// 4. Wait for initialization
await page.waitForTimeout(2000);

// 5. Execute scenes
// Scene 1
await page.fill('input', 'search query');
await page.waitForTimeout(1000);

// Scene 2
await page.keyboard.press('Enter');
await page.waitForLoadState('networkidle');
await page.waitForTimeout(2000);

// Scene 3...

// 6. Stop recording
const result = await axios.post('http://localhost:7823/stop');

// 7. Export GIF
const gif = await axios.post('http://localhost:7823/export', {
  video_path: result.data.video_path,
  format: 'gif',
  width: 1000,
  fps: 10
});
```

**Critical timing rules:**
- 2s after `start` before first action (initialization)
- 1-2s between actions (visual separation)
- Always wait for `networkidle` after navigation
- Type with `{ delay: 150 }` (visible, capturable)

---

### Step 5: Quality Validation

**Automatic check:**
```javascript
const sizeMBPerSec = result.data.size_mb / result.data.duration;
const hasContent = sizeMBPerSec > 0.05;

if (!hasContent) {
  console.error('❌ Video is blank (< 0.05 MB/s)');
  console.error('Possible causes:');
  console.error('  • Screen recording permission not granted');
  console.error('  • Wrong window targeted');
  console.error('  • ScreenMuse capture failure');
}
```

**Manual check:**
- Open MP4 in QuickTime
- Scrub through - all scenes captured?
- Open GIF - smooth playback?
- Text readable at 1000px width?

**Quality thresholds:**
- ✅ > 0.05 MB/s = Has content
- ⚠️ 0.02-0.05 MB/s = Partial capture
- ❌ < 0.02 MB/s = Blank video

---

## Common Video Workflows

### 1. Google Search Workflow

**Use case:** "Show how someone finds X via Google"

**Template:**
```javascript
// Scene 1: Homepage
await page.goto('https://google.com');

// Scene 2: Search
await page.fill('textarea[name="q"]', 'search query');
await page.keyboard.press('Enter');

// Scene 3: Results
await page.waitForLoadState('networkidle');
await page.locator('h3').first().hover();

// Scene 4: Click
await page.locator('h3').first().click();

// Scene 5: Destination
await page.waitForLoadState('networkidle');
await page.evaluate(() => window.scrollBy(0, 300));
```

**Duration:** 20 seconds  
**File:** `workflows/google-search.js`

---

### 2. Documentation Navigation

**Use case:** "Show finding specific doc section"

**Template:**
```javascript
// Scene 1: Docs homepage
await page.goto('https://docs.example.com');

// Scene 2: Open sidebar
await page.locator('nav button').click();

// Scene 3: Expand category
await page.locator('nav a:has-text("Category")').click();

// Scene 4: Click article
await page.locator('a:has-text("Article")').click();

// Scene 5: Scroll to section
await page.locator('#section-id').scrollIntoViewIfNeeded();
```

**Duration:** 20 seconds  
**File:** `workflows/docs-navigation.js`

---

### 3. Form Fill

**Use case:** "Show completing a signup/contact form"

**Template:**
```javascript
// Scene 1: Empty form
await page.goto('https://example.com/signup');

// Scene 2: Fill name
await page.fill('input[name="name"]', 'John Doe');
await page.waitForTimeout(1000);

// Scene 3: Fill email
await page.fill('input[name="email"]', 'john@example.com');
await page.waitForTimeout(1000);

// Scene 4: Submit
await page.click('button[type="submit"]');

// Scene 5: Success
await page.waitForSelector('.success-message');
```

**Duration:** 15 seconds  
**File:** `workflows/form-fill.js`

---

### 4. Product Hunt Browse

**Use case:** "Show discovering a product"

**Template:**
```javascript
// Scene 1: Homepage
await page.goto('https://producthunt.com');

// Scene 2: Scroll products
await page.evaluate(() => window.scrollBy(0, 400));

// Scene 3: Hover product card
await page.locator('.product-card').first().hover();

// Scene 4: Click product
await page.locator('.product-card').first().click();

// Scene 5: View product page
await page.evaluate(() => window.scrollBy(0, 300));
```

**Duration:** 20 seconds  
**File:** `workflows/product-hunt-browse.js`

---

### 5. Scroll Capture (Landing Page)

**Use case:** "Show full landing page layout"

**Template:**
```javascript
// Scene 1: Hero
await page.goto('https://example.com');

// Scene 2-4: Scroll sections
for (let i = 0; i < 3; i++) {
  await page.evaluate(() => window.scrollBy(0, 500));
  await page.waitForTimeout(1500);
}

// Scene 5: Footer
await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
```

**Duration:** 15 seconds  
**File:** `workflows/landing-page-scroll.js`

---

## Error Handling

### "ScreenMuse API not responding"

**Symptoms:**
- `curl http://localhost:7823/status` fails
- Connection refused / timeout

**Fix:**
```bash
# Kill and restart
killall ScreenMuseApp
# Open ScreenMuse.app from Applications
# Verify: curl http://localhost:7823/status
```

**In code:**
```javascript
try {
  await axios.get('http://localhost:7823/status', { timeout: 3000 });
} catch (error) {
  console.error('❌ ScreenMuse not responding');
  console.error('   Please restart ScreenMuse.app');
  process.exit(1);
}
```

---

### "Video is blank"

**Symptoms:**
- File size < 0.05 MB/s
- QuickTime shows black screen

**Possible causes:**
1. **Permission issue** - System Settings → Screen Recording → ScreenMuse ✓
2. **Wrong window PID** - Browser not the active window
3. **Window minimized** - Must be visible on screen
4. **ScreenMuse bug** - Check app logs

**Debug:**
```javascript
// Log what we're capturing
const windows = await axios.get('http://localhost:7823/windows');
console.log('Available windows:', windows.data.windows);

// Verify PID is correct
console.log('Targeting PID:', chromePid);
```

---

### "Recording cuts off early"

**Symptoms:**
- Video stops before last scene
- Duration shorter than expected

**Possible causes:**
1. **Browser closed too soon** - Add delay before `browser.close()`
2. **ScreenMuse timeout** - Check if max duration hit
3. **Script error** - Recording stopped when script crashed

**Fix:**
```javascript
// Wait before closing browser
await page.waitForTimeout(3000);
await axios.post('http://localhost:7823/stop');
await page.waitForTimeout(2000); // Let stop complete
await browser.close();
```

---

## Output Files

**Video files saved to:**
```
~/Movies/ScreenMuse/
  google-search-stripe-api_2026-03-28_18-30-45.mp4
  
~/Movies/ScreenMuse/Exports/
  google-search-stripe-api_2026-03-28_18-30-45.gif
```

**Naming convention:**
- Use descriptive names (`google-search-stripe-api`)
- Not generic (`test-1`, `video-recording`)
- Helps find recordings later

**File sizes (typical):**
- 20s MP4: 1-3 MB
- 20s GIF (1000px, 10fps): 3-8 MB

---

## Production Checklist

**Before every recording:**
- [ ] ScreenMuse HTTP API responding (`curl localhost:7823/status`)
- [ ] Screen recording permission granted
- [ ] Shot list written (5 scenes with timing)
- [ ] Browser positioned correctly (1400×900, top-left)
- [ ] Other windows closed (clean capture)

**During recording:**
- [ ] 2s wait after `start` (initialization)
- [ ] Slow typing (150ms delay)
- [ ] 1-2s pauses between actions
- [ ] Wait for page loads (`networkidle`)
- [ ] Total duration 15-30s

**After recording:**
- [ ] Quality check (> 0.05 MB/s)
- [ ] Manual review (open MP4)
- [ ] GIF exported successfully
- [ ] Files named descriptively

---

## Integration with OpenClaw

**When user asks: "Record a video of searching for X"**

```javascript
// 1. Acknowledge + confirm plan
"Creating a 20-second video: Google search for X
Scenes: homepage → type query → results → click → destination
Starting production..."

// 2. Run pre-flight checks
await preflight();

// 3. Execute production script
await produceVideo(plan);

// 4. Validate + report
"✅ Video complete: ~/Movies/ScreenMuse/...
Size: 1.8 MB, Duration: 20.3s, Quality: ✅ (0.089 MB/s)"
```

**When to use workflows:**
- User request matches common pattern
- Load template: `workflows/google-search.js`
- Customize for specific query/site
- Execute

**When to write custom:**
- Unique workflow not in templates
- Write shot list first
- Build script from structure
- Test once, then templatize if reusable

---

## Files Structure

```
skills/screenmuse-video-production/
  SKILL.md                          ← This file
  
  workflows/
    google-search.js                ← Template: Google search
    docs-navigation.js              ← Template: Docs sidebar nav
    form-fill.js                    ← Template: Form completion
    product-hunt-browse.js          ← Template: PH discovery
    landing-page-scroll.js          ← Template: Landing page tour
  
  scripts/
    produce-video.js                ← Main production runner
    validate-quality.js             ← Quality check utility
    preflight-check.js              ← API health check
  
  examples/
    google-search-stripe-api.js     ← Complete working example
    nextjs-docs-navigation.js       ← Complete working example
```

---

## For Developers

**What ScreenMuse needs to be production-ready:**

### High Priority

1. **HTTP API reliability**
   - Currently: Process runs but API stops responding
   - Need: Robust error recovery, logging
   - Impact: Blocks all automation

2. **Quality validation endpoints**
   - `GET /recordings/:id/stats` - frame count, size, fps
   - `GET /recordings/:id/quality` - MB/s, frame drops, issues
   - Makes debugging possible

3. **Recording state management**
   - What if script crashes during recording?
   - Clean up stale sessions automatically
   - Expose `/recordings/active` endpoint

### Medium Priority

4. **Metadata in recordings**
   - Store window title, URL, app name
   - Helps identify recordings later
   - `GET /recordings/:id/metadata`

5. **Frame drop detection**
   - Log when frames are dropped
   - Expose in quality endpoint
   - `{ frames_expected: 600, frames_captured: 580, drop_rate: 0.033 }`

6. **Multiple export formats in one call**
   - `POST /export { formats: ['gif', 'mp4', 'webm'] }`
   - Saves time, ensures consistency

### Nice to Have

7. **Recording annotations**
   - Add text/arrows during recording
   - `POST /annotate { text: "Click here", x: 100, y: 200 }`
   - Would be killer feature

8. **Smart cropping**
   - Auto-detect active area
   - Crop to content, not full window
   - Smaller file sizes, better focus

9. **Chapter markers**
   - Mark scenes during recording
   - `POST /marker { label: "Search results" }`
   - Enable seek in player, segment exports

---

## Related Skills

- **browser** - For screenshots/snapshots (not video)
- **web_fetch** - For page content without visual capture
- None yet for video editing/post-production

---

**This skill enables autonomous, high-quality demo video production. Use it whenever you need to show, not tell.**
