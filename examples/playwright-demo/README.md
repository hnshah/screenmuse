# Playwright + ScreenMuse: Automated Demo Recording

Record polished product demos by combining Playwright's browser automation with ScreenMuse's recording and effects.

**Playwright** handles what it does best: reliable browser automation, selectors, waiting for network, JavaScript injection.

**ScreenMuse** handles what it does best: recording quality, click effects, auto-zoom, chapters, and native macOS integration.

---

## Quick Start

```bash
# 1. Start ScreenMuse
cd /path/to/screenmuse
./scripts/dev-run.sh

# 2. Install deps
cd examples/playwright-demo
npm install
npx playwright install chromium

# 3. Edit demo.js — set your DEMO_URL and fill in the demo script
# 4. Run
node demo.js
```

---

## How it Works

```
┌─────────────────┐    HTTP API     ┌──────────────────────┐
│  Your Script    │ ─────────────► │  ScreenMuse (port     │
│  (demo.js)      │                │  7823)                │
│                 │                │                        │
│  Playwright     │                │  ┌─────────────────┐  │
│  controls       │                │  │ SCStream        │  │
│  browser        │                │  │ AVAssetWriter   │  │
│                 │                │  │ Click effects   │  │
│  sm.chapter()   │ ─────────────► │  │ Auto-zoom       │  │
│  sm.highlight() │                │  │ Window manager  │  │
│  sm.note()      │                │  └─────────────────┘  │
└─────────────────┘                └──────────────────────┘
```

---

## The ScreenMuse Helper (screenmuse.js)

Zero-dependency wrapper around the HTTP API. Drop it into any project.

```javascript
const { ScreenMuse } = require('./screenmuse');
const sm = new ScreenMuse();  // default: http://localhost:7823

// Recording
await sm.start({ name: 'my-demo', quality: 'high' });
await sm.chapter('Login screen');
await sm.highlight();          // next click gets zoom + ripple effect
await sm.note('User clicks login');
await sm.pause();              // pause during boring setup
await sm.resume();             // resume when action starts
const result = await sm.stop();

// Window management (native macOS — Playwright can't do this)
await sm.focusWindow('Google Chrome');
await sm.positionWindow('Google Chrome', { x: 0, y: 0, width: 1440, height: 900 });
await sm.hideOthers('Google Chrome');  // clean desktop

// System state
const clipboard = await sm.getClipboard();
const activeWindow = await sm.getActiveWindow();
const runningApps = await sm.getRunningApps();
```

---

## The `record()` Helper

Wraps the full setup-record-stop lifecycle:

```javascript
const result = await sm.record(
  {
    name: 'product-demo',
    window: 'Chromium',
    frame: { x: 0, y: 0, width: 1440, height: 900 },
    quality: 'high',
    hideOthers: true,   // hide other apps for clean recording
  },
  async (sm) => {
    // Your demo script goes here
    // sm.chapter(), sm.highlight(), etc. available

    await page.goto('https://yourapp.com');
    await sm.chapter('Homepage');

    await sm.highlight();
    await page.click('text=Get Started');
    await sm.chapter('Sign up flow');
  }
);

console.log(result.videoPath);  // → ~/Movies/ScreenMuse/product-demo.mp4
```

---

## Timing Tips

**Add pauses deliberately** — humans need time to read UI state:

```javascript
await page.goto('https://app.example.com');
await page.waitForLoadState('networkidle');
await sleep(1500);    // let viewer read the homepage
await sm.chapter('Homepage');

await page.click('text=Sign In');
await sleep(800);     // let button feedback show before chapter
await sm.chapter('Sign In');
```

**Use chapters generously** — they create the timeline structure for later editing.

**Use `sm.note()` when something is interesting** — it goes into the log so you can find it later:

```javascript
const count = await page.locator('.user-row').count();
await sm.note(`Dashboard shows ${count} users`);
```

---

## Window Setup Best Practice

Always position and focus before recording starts:

```javascript
// Position browser exactly where you want it
await sm.positionWindow('Chromium', { x: 0, y: 0, width: 1440, height: 900 });

// Hide Slack, Notes, etc. — clean desktop
await sm.hideOthers('Chromium');

// Small delay for animations to settle
await sleep(300);

// Now start recording
await sm.start({ name: 'demo', window_title: 'Chromium', quality: 'high' });
```

---

## Debugging

If something goes wrong, get a full session report:

```javascript
const report = await sm.getReport();
console.log(report);
// OR: curl http://localhost:7823/report | python3 -c "import sys,json; print(json.load(sys.stdin)['report'])"
```

Drop a note at the moment something breaks:

```javascript
try {
  await page.click('text=Submit');
} catch (err) {
  await sm.note(`BROKE: ${err.message}`);
  throw err;
}
```

---

## API Reference

All ScreenMuse API endpoints: `curl http://localhost:7823/version`
