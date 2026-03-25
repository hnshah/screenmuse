/**
 * screenmuse-playwright — Playwright Test fixture
 *
 * Records every test automatically. On failure, the video is saved with a
 * "_FAILED" suffix so you can find it instantly in your recordings folder.
 *
 * Usage:
 *   1. Import `test` and `expect` from this file instead of @playwright/test
 *   2. Use the `recordedPage` fixture — it's a regular Playwright Page, recording active
 *   3. Run normally: npx playwright test
 *
 * Output:
 *   ~/Movies/ScreenMuse/<TestName>.mp4          — passing test
 *   ~/Movies/ScreenMuse/<TestName>_FAILED.mp4   — failing test (auto-renamed)
 *
 * Requirements:
 *   - ScreenMuse running: ./scripts/dev-run.sh
 *   - npm install playwright screenmuse-playwright
 */

'use strict';

const path = require('path');
const fs = require('fs');
const http = require('http');
const { test: base, expect } = require('@playwright/test');
const { chromium } = require('playwright');

// ── Minimal ScreenMuse HTTP client (no extra deps) ────────────────────────────

function smRequest(method, endpoint, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const opts = {
      hostname: '127.0.0.1',
      port: 7823,
      path: endpoint,
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
      },
    };
    const req = http.request(opts, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        try { resolve(JSON.parse(data)); } catch { resolve(data); }
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

// ── Fixture ───────────────────────────────────────────────────────────────────

/**
 * `recordedPage` fixture
 *
 * Gives the test a Playwright Page with ScreenMuse recording active.
 * Automatically renames the video to *_FAILED on test failure and attaches
 * it to the Playwright HTML report.
 */
const test = base.extend({
  recordedPage: async ({}, use, testInfo) => {
    // Sanitise test title → safe filename
    const safeName = testInfo.title
      .replace(/[^a-zA-Z0-9\s\-_]/g, '')
      .replace(/\s+/g, '-')
      .slice(0, 80) || `test-${Date.now()}`;

    // Launch a visible browser (required for ScreenMuse to capture it)
    const browser = await chromium.launch({ headless: false });
    const context = await browser.newContext();
    const page = await context.newPage();

    // Start recording
    let startResult = null;
    try {
      startResult = await smRequest('POST', '/start', { name: safeName });
    } catch (err) {
      console.warn(`[ScreenMuse] Could not start recording: ${err.message}. Continuing without recording.`);
    }

    let error = null;
    try {
      await use(page);
    } catch (e) {
      error = e;
    } finally {
      // Always stop recording
      let stopResult = null;
      if (startResult) {
        try {
          stopResult = await smRequest('POST', '/stop', null);
        } catch (err) {
          console.warn(`[ScreenMuse] Could not stop recording: ${err.message}`);
        }
      }

      const videoPath = stopResult?.video_path;

      if (videoPath && fs.existsSync(videoPath)) {
        if (testInfo.status === 'failed' || testInfo.status === 'timedOut' || error) {
          // Rename to _FAILED for instant identification
          const ext = path.extname(videoPath);
          const base = path.basename(videoPath, ext);
          const dir = path.dirname(videoPath);
          const failedPath = path.join(dir, `${base}_FAILED${ext}`);

          try {
            fs.renameSync(videoPath, failedPath);
            await testInfo.attach('🎥 failure recording', {
              path: failedPath,
              contentType: 'video/mp4',
            });
            console.log(`\n🎥 Failure recording saved: ${failedPath}`);
          } catch {
            await testInfo.attach('recording', { path: videoPath, contentType: 'video/mp4' });
          }
        } else {
          // Attach passing video too (remove this block if you only want failures)
          await testInfo.attach('recording', {
            path: videoPath,
            contentType: 'video/mp4',
          }).catch(() => {});
        }
      }

      await context.close().catch(() => {});
      await browser.close().catch(() => {});
    }

    // Re-throw so Playwright marks the test as failed
    if (error) throw error;
  },
});

exports.test = test;
exports.expect = expect;

// ─── Example tests ────────────────────────────────────────────────────────────
//
// Replace the `test(...)` calls below with your own tests.
//
// test('homepage title — passes', async ({ recordedPage: page }) => {
//   await page.goto('https://example.com');
//   await expect(page.locator('h1')).toContainText('Example Domain');
// });
//
// test('broken selector — fails with _FAILED video', async ({ recordedPage: page }) => {
//   await page.goto('https://example.com');
//   await page.click('#this-does-not-exist');   // will fail → video renamed _FAILED
// });
