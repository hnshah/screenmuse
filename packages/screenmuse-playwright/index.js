/**
 * screenmuse-playwright
 *
 * First-class Playwright integration for ScreenMuse.
 * Records browser automation sessions with zero boilerplate.
 *
 * How it works:
 *   1. Launches the browser (or accepts an existing one)
 *   2. Gets the browser process PID
 *   3. Tells ScreenMuse to record that specific window
 *   4. Runs your automation script
 *   5. Stops recording, closes browser, returns a RecordingResult
 *   6. RecordingResult has chainable .exportGif() / .trim() / .annotate() etc.
 *
 * No new Swift endpoints. Uses existing ScreenMuse API.
 * Works alongside Peekaboo for full capture+automation coverage.
 *
 * @example
 *   const { ScreenMusePlaywright } = require('screenmuse-playwright');
 *   const { chromium } = require('playwright');
 *
 *   const sm = new ScreenMusePlaywright();
 *   const result = await sm.recordBrowser({ browser: chromium, name: 'my-demo' }, async (page) => {
 *     await page.goto('https://github.com');
 *     await page.getByLabel('Search').click();
 *     await page.keyboard.type('screenmuse');
 *   });
 *   const gif = await result.exportGif({ fps: 10, scale: 600 });
 *   console.log(gif.path);
 */

'use strict';

const DEFAULT_URL = 'http://localhost:7823';

// ── ScreenMusePlaywright ─────────────────────────────────────────────────────

class ScreenMusePlaywright {
  /**
   * @param {object} [opts]
   * @param {string} [opts.url]    ScreenMuse server URL (default: http://localhost:7823)
   * @param {number} [opts.timeout] Request timeout in ms (default: 30000)
   */
  constructor(opts = {}) {
    this.baseUrl = opts.url || process.env.SCREENMUSE_URL || DEFAULT_URL;
    this.timeout = opts.timeout || 30_000;
  }

  // ── Core Recording ─────────────────────────────────────────────────────────

  /**
   * Record a Playwright browser session.
   *
   * Handles the full lifecycle automatically:
   *   launch → detect PID → start recording → run script → stop → close
   *
   * @param {object}   options
   * @param {object}   options.browser            Playwright BrowserType (chromium | firefox | webkit)
   * @param {string}   [options.name]             Recording name (default: auto-generated)
   * @param {string}   [options.quality]          'low'|'medium'|'high'|'max' (default: 'high')
   * @param {boolean}  [options.autoChapters]     Auto-add chapters on page navigation (default: true)
   * @param {boolean}  [options.autoNotes]        Auto-add notes on console errors (default: true)
   * @param {boolean}  [options.hideOthers]       Hide other app windows before recording (default: false)
   * @param {object}   [options.launchOptions]    Playwright launch() options
   * @param {string}   [options.webhook]          URL to POST when recording completes
   * @param {function} script                     async (page, context, browser) => { ... }
   *
   * @returns {Promise<RecordingResult>}
   */
  async recordBrowser(options, script) {
    const {
      browser: browserType,
      name = `recording-${Date.now()}`,
      quality = 'high',
      autoChapters = true,
      autoNotes = true,
      hideOthers = false,
      launchOptions = {},
      webhook,
    } = options;

    if (!browserType) {
      throw new Error("'browser' is required — pass a Playwright browser type: e.g. { browser: chromium }");
    }
    if (typeof script !== 'function') {
      throw new Error("'script' must be an async function: async (page) => { ... }");
    }

    // 1. Verify ScreenMuse is running
    await this._checkRunning();

    // 2. Launch browser
    const browser = await browserType.launch({
      headless: false,
      ...launchOptions,
    });

    // 3. Get browser process PID (window-specific recording)
    const browserPid = browser.process?.()?.pid ?? null;

    // Give the window a moment to register with the OS
    if (browserPid) await sleep(600);

    // 4. Optionally hide other windows for a clean recording
    if (hideOthers) {
      const browserName = browserType.name?.() ?? 'Chromium';
      await this._api('/window/hide-others', { except: browserName }).catch(() => {});
      await sleep(300);
    }

    // 5. Start ScreenMuse recording
    const startBody = { name, quality };
    if (browserPid) startBody.window_pid = browserPid;
    if (webhook) startBody.webhook = webhook;

    let startResult;
    try {
      startResult = await this._api('/start', startBody);
    } catch (err) {
      // Fallback: record full screen if window-specific start fails
      if (browserPid && (err.message?.includes('window') || err.message?.includes('Window'))) {
        console.warn('[screenmuse-playwright] Window-specific recording unavailable, falling back to full screen');
        startResult = await this._api('/start', { name, quality, ...(webhook ? { webhook } : {}) });
      } else {
        await browser.close().catch(() => {});
        throw err;
      }
    }

    const sessionStart = Date.now();
    const capturedChapters = [];

    // 6. Create browser context + page
    const context = await browser.newContext();
    const page = await context.newPage();

    // 7. Wire up automatic chapter markers on page navigation
    if (autoChapters) {
      page.on('load', async () => {
        try {
          const url = page.url();
          if (!url || url === 'about:blank' || url.startsWith('chrome://')) return;
          const title = await page.title().catch(() => '');
          const chapterName = title?.trim() || new URL(url).hostname;
          await this._api('/chapter', { name: chapterName });
          capturedChapters.push({
            name: chapterName,
            url,
            time: (Date.now() - sessionStart) / 1000,
            auto: true,
          });
        } catch {
          // Chapters are best-effort — never block script execution
        }
      });
    }

    // 8. Wire up automatic notes on console errors
    if (autoNotes) {
      page.on('console', async (msg) => {
        if (msg.type() === 'error') {
          await this._api('/note', { text: `Console error: ${msg.text()}` }).catch(() => {});
        }
      });
      page.on('pageerror', async (err) => {
        await this._api('/note', { text: `Page error: ${err.message}` }).catch(() => {});
      });
    }

    // 9. Run user script
    let scriptError = null;
    try {
      await script(page, context, browser);
    } catch (err) {
      scriptError = err;
      await this._api('/note', { text: `Script error: ${err.message}` }).catch(() => {});
    } finally {
      // 10. Always stop recording + close browser, even on error
      let stopResult = null;
      try {
        stopResult = await this._api('/stop', {});
      } catch {
        // Best effort stop
      }
      await browser.close().catch(() => {});

      if (scriptError) throw scriptError;
      if (!stopResult?.video_path) throw new Error('Recording stopped but returned no video path — ScreenMuse may have crashed');

      return new RecordingResult(stopResult, capturedChapters, this);
    }
  }

  // ── Low-level API wrapper ──────────────────────────────────────────────────

  async _api(path, body = null) {
    const method = body !== null ? 'POST' : 'GET';
    const opts = {
      method,
      headers: { 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(this.timeout),
    };
    if (body !== null) opts.body = JSON.stringify(body);

    let res;
    try {
      res = await fetch(`${this.baseUrl}${path}`, opts);
    } catch (err) {
      if (err.name === 'TypeError' || err.code === 'ECONNREFUSED') {
        throw new Error(`ScreenMuse is not running. Launch ScreenMuse.app first.\n(Expected at ${this.baseUrl})`);
      }
      throw err;
    }

    const json = await res.json().catch(() => ({}));
    if (!res.ok && json.error) throw new Error(json.error);
    return json;
  }

  async _checkRunning() {
    await this._api('/status').catch(() => {
      throw new Error(`ScreenMuse is not running. Launch ScreenMuse.app first.\n(Expected at ${this.baseUrl})`);
    });
  }
}

// ── RecordingResult ──────────────────────────────────────────────────────────

/**
 * Returned by recordBrowser(). Wraps the video with chainable export methods.
 *
 * Every method that produces a new video returns a new RecordingResult,
 * so operations can be chained.
 *
 * @example
 *   const result = await sm.recordBrowser(...);
 *   const trimmed = await result.trim({ start: 1, end: 30 });
 *   const gif = await trimmed.exportGif({ fps: 10, scale: 600 });
 */
class RecordingResult {
  constructor(stopData, autoChapters, sm) {
    /** Absolute path to the recorded MP4 */
    this.videoPath = stopData.video_path;
    /** Recording duration in seconds */
    this.duration = stopData.elapsed ?? stopData.duration ?? 0;
    /** Chapters added automatically during recording */
    this.chapters = autoChapters;
    /** Raw stop response metadata */
    this.metadata = stopData.metadata ?? {};
    this._sm = sm;
  }

  /**
   * Export as animated GIF.
   * @param {object} [opts]
   * @param {number} [opts.fps=10]      Frames per second
   * @param {number} [opts.scale=800]   Max width in pixels
   * @param {number} [opts.start]       Start time in seconds
   * @param {number} [opts.end]         End time in seconds
   * @returns {Promise<{path, size_mb, frame_count}>}
   */
  async exportGif(opts = {}) {
    return this._sm._api('/export', { source: this.videoPath, format: 'gif', ...opts });
  }

  /**
   * Export as animated WebP.
   * @param {object} [opts] Same as exportGif
   * @returns {Promise<{path, size_mb, frame_count}>}
   */
  async exportWebP(opts = {}) {
    return this._sm._api('/export', { source: this.videoPath, format: 'webp', ...opts });
  }

  /**
   * Trim to a time range. Returns a new RecordingResult pointing to the trimmed file.
   * Stream copy — instant, no re-encode.
   * @param {object} [opts]
   * @param {number} [opts.start=0]   Start in seconds
   * @param {number} [opts.end]       End in seconds (default: end of video)
   * @returns {Promise<RecordingResult>}
   */
  async trim(opts = {}) {
    const r = await this._sm._api('/trim', { source: this.videoPath, ...opts });
    return new RecordingResult({ video_path: r.path, elapsed: r.duration }, this.chapters, this._sm);
  }

  /**
   * Auto-compress idle sections (silence + no mouse movement).
   * Returns a new RecordingResult pointing to the sped-up file.
   * @param {object} [opts]
   * @param {number} [opts.speed_factor=4]     Speed multiplier for idle sections
   * @param {number} [opts.min_idle_seconds=2] Minimum idle duration to compress
   * @returns {Promise<RecordingResult>}
   */
  async speedramp(opts = {}) {
    const r = await this._sm._api('/speedramp', { source: this.videoPath, ...opts });
    return new RecordingResult(
      { video_path: r.output_path ?? r.path, elapsed: r.output_duration ?? r.duration },
      this.chapters,
      this._sm
    );
  }

  /**
   * Burn text overlays into the video at specific timestamps.
   * Returns a new RecordingResult pointing to the annotated file.
   *
   * @param {Array<{text, start, end, position?, size?, color?, background?}>} overlays
   * @param {object} [opts]
   * @returns {Promise<RecordingResult>}
   *
   * @example
   *   await result.annotate([
   *     { text: 'Step 1: Open Settings', start: 2, end: 8, position: 'bottom' },
   *     { text: 'Step 2: Click Save',    start: 12, end: 18 },
   *   ]);
   */
  async annotate(overlays, opts = {}) {
    const r = await this._sm._api('/annotate', { source: this.videoPath, overlays, ...opts });
    return new RecordingResult({ video_path: r.path, elapsed: r.duration }, this.chapters, this._sm);
  }

  /**
   * Extract a still frame as JPEG/PNG.
   * @param {object} [opts]
   * @param {number} [opts.time]       Timestamp in seconds (default: middle of video)
   * @param {number} [opts.scale=800]  Max width in pixels
   * @param {string} [opts.format]     'jpeg' (default) or 'png'
   * @returns {Promise<{path, time, width, height, size_bytes}>}
   */
  async thumbnail(opts = {}) {
    return this._sm._api('/thumbnail', { source: this.videoPath, ...opts });
  }

  /**
   * Crop a region from the video.
   * Returns a new RecordingResult pointing to the cropped file.
   * @param {{ x, y, width, height }} region
   * @param {object} [opts]
   * @returns {Promise<RecordingResult>}
   */
  async crop(region, opts = {}) {
    const r = await this._sm._api('/crop', { source: this.videoPath, region, ...opts });
    return new RecordingResult({ video_path: r.path, elapsed: r.duration }, this.chapters, this._sm);
  }

  /**
   * Upload to iCloud Drive.
   * @returns {Promise<{ok, icloud_path}>}
   */
  async uploadToiCloud() {
    return this._sm._api('/upload/icloud', { source: this.videoPath });
  }

  /** Get the structured timeline (chapters, notes, highlights). */
  async timeline() {
    return this._sm._api('/timeline');
  }

  toString() {
    const dur = this.duration ? `${this.duration.toFixed(1)}s` : '?s';
    const ch = this.chapters?.length ?? 0;
    return `RecordingResult { path: "${this.videoPath}", duration: ${dur}, chapters: ${ch} }`;
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

module.exports = { ScreenMusePlaywright, RecordingResult };
