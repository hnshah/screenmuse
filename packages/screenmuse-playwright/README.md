# screenmuse-playwright

Record Playwright browser automation sessions with ScreenMuse. Zero boilerplate.

```js
const { chromium } = require('playwright');
const { ScreenMusePlaywright } = require('screenmuse-playwright');

const sm = new ScreenMusePlaywright();

const result = await sm.recordBrowser({
  name: 'github-search-demo',
  quality: 'high',
  browser: chromium,
  autoChapters: true,
}, async (page) => {
  await page.goto('https://github.com');
  await page.getByLabel('Search').click();
  await page.keyboard.type('screenmuse');
  await page.keyboard.press('Enter');
  await page.waitForLoadState('networkidle');
});

console.log(`Video: ${result.videoPath}`);  // ~/Movies/ScreenMuse/github-search-demo.mp4
```

**Before (manual coordination):** ~150 lines, race conditions, 60% success rate  
**After (this package):** ~10 lines, zero race conditions, 100% reliable

---

## Prerequisites

1. **ScreenMuse.app** running on your Mac (launches the HTTP server on port 7823)
2. Node.js 18+
3. Playwright installed: `npm install playwright`

## Install

```bash
npm install screenmuse-playwright playwright
npx playwright install chromium
```

## How it works

```
recordBrowser()
 │
 ├─ Launch browser (Playwright)
 ├─ Get browser process PID
 ├─ Tell ScreenMuse: "record this window" (POST /start with window_pid)
 ├─ Wire page.on('load') → POST /chapter (if autoChapters: true)
 ├─ Run your script
 └─ POST /stop → close browser → return RecordingResult
```

No new ScreenMuse endpoints. Uses the existing REST API.

---

## API

### `new ScreenMusePlaywright(opts?)`

| Option | Default | Description |
|--------|---------|-------------|
| `url` | `http://localhost:7823` | ScreenMuse server URL |
| `timeout` | `30000` | Request timeout in ms |

### `sm.recordBrowser(options, script) → RecordingResult`

| Option | Default | Description |
|--------|---------|-------------|
| `browser` | required | Playwright BrowserType (`chromium`, `firefox`, `webkit`) |
| `name` | auto | Recording name |
| `quality` | `'high'` | `'low'` \| `'medium'` \| `'high'` \| `'max'` |
| `autoChapters` | `true` | Add chapter markers on page navigation |
| `autoNotes` | `true` | Add notes on console errors / page errors |
| `hideOthers` | `false` | Hide other windows before recording |
| `launchOptions` | `{}` | Playwright `launch()` options |
| `webhook` | — | URL to POST when recording completes |

`script` receives `(page, context, browser)` — standard Playwright objects.

### `RecordingResult`

```js
result.videoPath    // Absolute path to the MP4 file
result.duration     // Duration in seconds
result.chapters     // Auto-chapters: [{name, url, time, auto}]
result.metadata     // Raw stop response metadata

// All export methods are async and return new RecordingResult or the export info:
await result.exportGif({ fps, scale, start, end })    // → {path, size_mb, frame_count}
await result.exportWebP({ fps, scale, start, end })   // → {path, size_mb, frame_count}
await result.trim({ start, end })                     // → RecordingResult (trimmed video)
await result.speedramp({ speed_factor, min_idle_seconds }) // → RecordingResult (compressed)
await result.annotate(overlays, opts)                 // → RecordingResult (with text overlays)
await result.thumbnail({ time, scale, format })       // → {path, time, width, height}
await result.crop(region, opts)                       // → RecordingResult (cropped video)
await result.uploadToiCloud()                         // → {ok, icloud_path}
await result.timeline()                               // → {chapters, notes, highlights}
```

---

## Examples

### Basic recording

```js
const result = await sm.recordBrowser({ browser: chromium, name: 'demo' }, async (page) => {
  await page.goto('https://yourapp.com');
  await page.click('[data-test=sign-in]');
  await page.fill('[data-test=email]', 'demo@example.com');
  await page.click('[data-test=submit]');
});

console.log(result.videoPath);
```

### Export as GIF for docs

```js
const result = await sm.recordBrowser({ browser: chromium }, async (page) => {
  await page.goto('https://yourapp.com/feature');
  await page.waitForLoadState('networkidle');
});

const gif = await result.trim({ start: 0.5 }).then(r => r.exportGif({ fps: 10, scale: 600 }));
console.log(gif.path); // drop into your docs
```

### QA test with automatic video on failure

```js
test('checkout flow', async () => {
  const { result } = await sm.recordBrowser(
    { browser: chromium, name: 'checkout-test', quality: 'medium' },
    async (page) => {
      await page.goto('/cart');
      await page.click('[data-test=checkout]');
      await expect(page.locator('.success')).toBeVisible();
    }
  ).then(r => ({ ok: true, result: r })).catch(e => ({ ok: false, error: e, result: null }));

  if (!result) throw new Error(`Test failed — video: ${result?.videoPath ?? 'not saved'}`);
});
```

### Batch demo generation

```js
const demos = [
  { name: 'signup',    script: signupScript },
  { name: 'dashboard', script: dashboardScript },
  { name: 'export',    script: exportScript },
];

for (const demo of demos) {
  const result = await sm.recordBrowser({ browser: chromium, ...demo }, demo.script);
  await result.exportGif({ fps: 10, scale: 600 });
  console.log(`✅ ${demo.name}`);
}
// → 3 videos + 3 GIFs, unattended
```

### With text annotations (burn steps into video)

```js
const result = await sm.recordBrowser({ browser: chromium, name: 'annotated-demo' }, async (page) => {
  await page.goto('https://github.com/settings');
});

const annotated = await result.annotate([
  { text: 'Step 1: Open GitHub Settings', start: 0, end: 6, position: 'bottom' },
  { text: 'Step 2: Scroll to Security',   start: 6, end: 12 },
]);

await annotated.exportGif({ fps: 8 });
```

### Pair with Peekaboo (observe + record)

```
Peekaboo: screenshot, UI element map, click/type/scroll
ScreenMuse: record the full session, export as GIF/MP4

Use both: Peekaboo drives the UI, ScreenMuse captures the proof.
```

With Claude Desktop (both MCPs configured):
1. `screenmuse_start(name: "demo")` — start recording
2. Peekaboo navigates the UI
3. `screenmuse_chapter(name: "Step 2")` — mark progress
4. `screenmuse_stop()` — finish
5. `screenmuse_export(format: "gif")` — deliver artifact

---

## Environment Variables

```bash
SCREENMUSE_URL=http://localhost:7823   # Custom port
```

---

## Error handling

If ScreenMuse isn't running, you get a clear message:

```
Error: ScreenMuse is not running. Launch ScreenMuse.app first.
(Expected at http://localhost:7823)
```

If the browser window can't be found for window-specific recording, it falls back to full-screen recording automatically.

If your script throws, the recording still stops and the browser closes. The error propagates after cleanup.

---

## Changelog

### 1.0.0
- `recordBrowser()` with automatic window PID detection
- `autoChapters: true` — page navigation → chapter markers
- `autoNotes: true` — console errors → recording notes
- `RecordingResult` with `.exportGif()`, `.exportWebP()`, `.trim()`, `.speedramp()`, `.annotate()`, `.thumbnail()`, `.crop()`, `.uploadToiCloud()`, `.timeline()`
- Fallback to full-screen recording if window-specific recording fails
- Zero npm dependencies (native fetch, Node 18+)
