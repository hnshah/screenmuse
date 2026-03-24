/**
 * demo.js — Playwright + ScreenMuse: automated demo recording
 *
 * This example records a polished product demo of any web app.
 * Playwright handles the browser automation.
 * ScreenMuse handles recording + effects.
 *
 * Prerequisites:
 *   1. ScreenMuse app running (./scripts/dev-run.sh or Xcode)
 *   2. npm install
 *   3. node demo.js
 */

const { chromium } = require('playwright');
const { ScreenMuse, sleep } = require('./screenmuse');

const sm = new ScreenMuse();

// ── Configuration ──────────────────────────────────────────────────────────

const DEMO_URL = 'https://example.com';  // Change to your app URL
const RECORDING_NAME = 'product-demo';
const WINDOW_NAME = 'Chromium';
const WINDOW_FRAME = { x: 0, y: 0, width: 1440, height: 900 };

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  // Verify ScreenMuse is running
  console.log('Checking ScreenMuse...');
  const version = await sm.getVersion().catch(() => null);
  if (!version) {
    console.error('❌ ScreenMuse not responding on port 7823. Is the app running?');
    process.exit(1);
  }
  console.log(`✅ ScreenMuse ${version.version} ready`);

  // Launch browser
  const browser = await chromium.launch({
    headless: false,
    args: [
      `--window-size=${WINDOW_FRAME.width},${WINDOW_FRAME.height}`,
      '--window-position=0,0',
    ]
  });

  const context = await browser.newContext({
    viewport: { width: WINDOW_FRAME.width, height: WINDOW_FRAME.height - 70 }  // subtract chrome bar
  });
  const page = await context.newPage();

  try {
    const result = await sm.record(
      {
        name: RECORDING_NAME,
        window: WINDOW_NAME,
        frame: WINDOW_FRAME,
        quality: 'high',
        hideOthers: true,
      },
      async (sm) => {
        // ── Demo Script ──────────────────────────────────────────────────
        // Replace this with your actual demo flow.
        // Call sm.chapter(), sm.highlight(), sm.note() at key moments.

        await sm.chapter('Introduction');

        // Navigate to your app
        await page.goto(DEMO_URL);
        await page.waitForLoadState('networkidle');
        await sleep(1500);  // Let the UI settle before recording shows it

        await sm.note('Homepage loaded');
        await sm.chapter('Homepage');

        // Example: interact with a button
        // await sm.highlight();  // next click will get zoom + effect
        // await page.click('text=Sign In');
        // await sm.chapter('Sign In');
        // await sleep(1000);

        // Example: fill a form
        // await page.fill('#email', 'demo@example.com');
        // await page.fill('#password', 'demo123');
        // await sm.chapter('Credentials entered');

        // Example: verify something and annotate
        // await page.waitForURL('**/dashboard');
        // const title = await page.title();
        // await sm.note(`Dashboard title: ${title}`);
        // await sm.chapter('Dashboard');

        // Pause to let viewer absorb the final state
        await sleep(2000);
        // ── End Demo Script ──────────────────────────────────────────────
      }
    );

    console.log('\n📹 Demo recording complete!');
    console.log(`   Video: ${result.videoPath}`);
    console.log(`   Duration: ${result.metadata.elapsed}s`);
    console.log(`   Chapters: ${result.metadata.chapters.length}`);

    // Get session report
    const report = await sm.getReport();
    console.log('\n' + report);

  } finally {
    await browser.close();
  }
}

main().catch(err => {
  console.error('Demo failed:', err.message);
  process.exit(1);
});
