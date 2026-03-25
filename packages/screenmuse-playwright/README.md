# screenmuse-playwright

Record Playwright browser automation sessions with [ScreenMuse](https://github.com/hnshah/screenmuse). Zero boilerplate, automatic window targeting, chapter markers on navigation.

## Installation

```bash
npm install playwright screenmuse-playwright
npx playwright install chromium
```

## Prerequisites

- **macOS 14+** (Sonoma or later)
- **ScreenMuse.app** running on your Mac (launches the HTTP server on port 7823)
- **Node.js 18+**

Verify ScreenMuse is running:

```bash
curl http://localhost:7823/status
```

## Basic Usage

```js
const { chromium } = require('playwright');
const { ScreenMusePlaywright } = require('screenmuse-playwright');

const sm = new ScreenMusePlaywright();

const result = await sm.recordBrowser({
  browser: chromium,
  name: 'github-search-demo',
  quality: 'high',
  autoChapters: true,
}, async (page) => {
  await page.goto('https://github.com');
  await page.getByLabel('Search').click();
  await page.keyboard.type('screenmuse');
  await page.keyboard.press('Enter');
  await page.waitForLoadState('networkidle');
});

console.log(`Video: ${result.videoPath}`);

// Export as GIF
const gif = await result.exportGif({ fps: 10, scale: 600 });
console.log(`GIF: ${gif.path}`);
```

**Before (manual coordination):** ~150 lines, race conditions, 60% success rate
**After (this package):** ~10 lines, zero race conditions, 100% reliable

## Troubleshooting

### Multiple Chrome Windows

When multiple Chrome windows are open, ScreenMuse may record the wrong one. Solutions:

1. **Use `hideOthers: true`** to hide other app windows before recording:
   ```js
   await sm.recordBrowser({ browser: chromium, hideOthers: true }, async (page) => { ... });
   ```

2. **Use the `findBrowserWindow()` helper** to explicitly find and target the right window:
   ```js
   const sm = new ScreenMusePlaywright();
   const browser = await chromium.launch({ headless: false });
   const win = await sm.findBrowserWindow(browser);
   // Use win.pid with a manual /start call if needed
   ```

3. **Pass `window_pid` explicitly** in your start options if you know the PID.

### GitHub Virtual Scrolling

GitHub uses virtual scrolling on some pages, which can cause Playwright's `.click()` to fail with "element not visible" errors. Use `.evaluate()` to bypass visibility checks:

```js
// Instead of:
await page.locator('.some-element').click();

// Use:
await page.locator('.some-element').evaluate(el => el.click());
```

### Window Not Found

If ScreenMuse can't find the browser window:

1. Make sure **ScreenMuse.app is running** — check with `curl http://localhost:7823/status`
2. Verify the browser is **not headless** — `headless: false` is required
3. Check available windows: `curl http://localhost:7823/windows`
4. Give the window time to register — the package waits automatically, but complex launch configs may need more time

### PID Returns null on macOS

On macOS, `browser.process().pid` often returns `null` with Playwright. **This package handles it automatically** — when PID is null, it:

1. Queries the ScreenMuse `/windows` endpoint
2. Filters for Chrome/Chromium windows
3. Prefers newly-opened windows (empty or about:blank title)
4. Uses the last match (most recently opened)

No action needed — the fallback is built in. You'll see a log message:

```
[screenmuse-playwright] browser.process().pid is null — using /windows fallback
[screenmuse-playwright] Found browser window via /windows: pid=12345 app="Google Chrome" title=""
```

## Playwright Test Integration

Use the provided fixture to automatically record every test. On failure, the video is saved with a `_FAILED` suffix.

See [`examples/playwright-test-fixture.js`](examples/playwright-test-fixture.js) for the full fixture.

```js
// test.setup.js — import test/expect from the fixture instead of @playwright/test
const { test, expect } = require('./playwright-test-fixture');

test('homepage title', async ({ recordedPage: page }) => {
  await page.goto('https://example.com');
  await expect(page.locator('h1')).toContainText('Example Domain');
});

// Failed tests → ~/Movies/ScreenMuse/<TestName>_FAILED.mp4
// Passing tests → ~/Movies/ScreenMuse/<TestName>.mp4
```

## API Reference

### `new ScreenMusePlaywright(opts?)`

Creates a new ScreenMuse-Playwright integration instance.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `url` | `string` | `http://localhost:7823` | ScreenMuse server URL |
| `timeout` | `number` | `30000` | Request timeout in ms |

The URL can also be set via the `SCREENMUSE_URL` environment variable.

### `sm.recordBrowser(options, script) → Promise<RecordingResult>`

Record a full browser automation session. Handles launch → PID detection → start recording → run script → stop → close.

**Options:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `browser` | `BrowserType` | *required* | Playwright browser type (`chromium`, `firefox`, `webkit`) |
| `name` | `string` | auto-generated | Recording name |
| `quality` | `string` | `'high'` | `'low'` \| `'medium'` \| `'high'` \| `'max'` |
| `autoChapters` | `boolean` | `true` | Add chapter markers on page navigation |
| `autoNotes` | `boolean` | `true` | Add notes on console errors / page errors |
| `hideOthers` | `boolean` | `false` | Hide other app windows before recording |
| `launchOptions` | `object` | `{}` | Playwright `launch()` options |
| `webhook` | `string` | — | URL to POST when recording completes |

**Script:** `async (page, context, browser) => { ... }` — receives standard Playwright objects.

### `sm.findBrowserWindow(browser?) → Promise<{pid, app, title} | null>`

Find a Chrome/Chromium browser window via the ScreenMuse `/windows` endpoint. Useful when `browser.process().pid` returns null (common on macOS).

Returns the best matching window object with `pid`, `app`, and `title` fields, or `null` if no Chrome window is found.

### `RecordingResult`

Returned by `recordBrowser()`. Wraps the video with chainable export methods.

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `videoPath` | `string` | Absolute path to the recorded MP4 |
| `duration` | `number` | Recording duration in seconds |
| `chapters` | `Array` | Auto-chapters: `[{name, url, time, auto}]` |
| `metadata` | `object` | Raw stop response metadata |

**Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `exportGif(opts?)` | `Promise<{path, size_mb, frame_count}>` | Export as animated GIF |
| `exportWebP(opts?)` | `Promise<{path, size_mb, frame_count}>` | Export as animated WebP |
| `trim(opts?)` | `Promise<RecordingResult>` | Trim to time range (stream copy, instant) |
| `speedramp(opts?)` | `Promise<RecordingResult>` | Auto-compress idle sections |
| `annotate(overlays, opts?)` | `Promise<RecordingResult>` | Burn text overlays into video |
| `thumbnail(opts?)` | `Promise<{path, time, width, height}>` | Extract a still frame |
| `crop(region, opts?)` | `Promise<RecordingResult>` | Crop a region from the video |
| `uploadToiCloud()` | `Promise<{ok, icloud_path}>` | Upload to iCloud Drive |
| `timeline()` | `Promise<object>` | Get structured timeline (chapters, notes, highlights) |

**Export options (for `exportGif` / `exportWebP`):**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `fps` | `number` | `10` | Frames per second |
| `scale` | `number` | `800` | Max width in pixels |
| `start` | `number` | — | Start time in seconds |
| `end` | `number` | — | End time in seconds |
