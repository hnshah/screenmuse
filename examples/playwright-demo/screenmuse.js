/**
 * screenmuse.js — lightweight ScreenMuse API wrapper for Node.js
 *
 * No dependencies. Drop this file into any project.
 * Compatible with Node 18+ (native fetch).
 */

class ScreenMuse {
  constructor(baseURL = 'http://localhost:7823') {
    this.baseURL = baseURL;
  }

  async _request(method, path, body) {
    const opts = {
      method,
      headers: { 'Content-Type': 'application/json' },
    };
    if (body) opts.body = JSON.stringify(body);
    const res = await fetch(`${this.baseURL}${path}`, opts);
    const json = await res.json();
    if (!res.ok) {
      throw new Error(`ScreenMuse ${method} ${path} → ${res.status}: ${json.error || JSON.stringify(json)}`);
    }
    return json;
  }

  // ── Recording ──────────────────────────────────────────────────────────────

  /** Start a recording. Returns { session_id, status, name } */
  async start(options = {}) {
    return this._request('POST', '/start', options);
  }

  /** Stop the recording. Returns { video_path, metadata } */
  async stop() {
    return this._request('POST', '/stop');
  }

  /** Pause recording (stream stops, writer keeps open) */
  async pause() {
    return this._request('POST', '/pause');
  }

  /** Resume a paused recording */
  async resume() {
    return this._request('POST', '/resume');
  }

  /** Mark a chapter at current timestamp */
  async chapter(name) {
    return this._request('POST', '/chapter', { name });
  }

  /** Flag next click for enhanced highlight + auto-zoom */
  async highlight() {
    return this._request('POST', '/highlight');
  }

  /** Take a screenshot (no recording needed) */
  async screenshot(path) {
    return this._request('POST', '/screenshot', path ? { path } : {});
  }

  /** Drop a timestamped note into the usage log */
  async note(text) {
    return this._request('POST', '/note', { text });
  }

  /** Get current recording status */
  async status() {
    return this._request('GET', '/status');
  }

  // ── Window Management ──────────────────────────────────────────────────────

  /**
   * Bring an app window to the front.
   * @param {string} app - Display name ("Notes", "Google Chrome") or bundle ID
   */
  async focusWindow(app) {
    return this._request('POST', '/window/focus', { app });
  }

  /**
   * Position and resize an app's window.
   * @param {string} app - Display name or bundle ID
   * @param {{ x, y, width, height }} frame - Window frame
   */
  async positionWindow(app, { x = 0, y = 0, width = 1440, height = 900 } = {}) {
    return this._request('POST', '/window/position', { app, x, y, width, height });
  }

  /**
   * Hide all apps except the recording target.
   * Equivalent to Option-clicking in the Dock.
   * @param {string} app - App to keep visible
   */
  async hideOthers(app) {
    return this._request('POST', '/window/hide-others', { app });
  }

  // ── System State ───────────────────────────────────────────────────────────

  /** Read the current clipboard contents */
  async getClipboard() {
    return this._request('GET', '/system/clipboard');
  }

  /** Get the frontmost app and focused window info */
  async getActiveWindow() {
    return this._request('GET', '/system/active-window');
  }

  /** List all running apps */
  async getRunningApps() {
    return this._request('GET', '/system/running-apps');
  }

  // ── Convenience ────────────────────────────────────────────────────────────

  /** Get full session report (for bug reports) */
  async getReport() {
    const r = await this._request('GET', '/report');
    return r.report;
  }

  /** Check ScreenMuse version and available endpoints */
  async getVersion() {
    return this._request('GET', '/version');
  }

  /**
   * Record a Playwright session.
   * Sets up the window, starts recording, runs your script, stops.
   *
   * @param {object} options
   * @param {string} options.name - Recording name
   * @param {string} options.window - Window/app to record
   * @param {{ x, y, width, height }} [options.frame] - Window frame (default 1440×900)
   * @param {string} [options.quality] - "low" | "medium" | "high" (default "medium")
   * @param {boolean} [options.hideOthers] - Hide other apps before recording (default true)
   * @param {Function} script - Async function that performs the demo
   * @returns {{ videoPath, metadata, elapsed }}
   */
  async record(options, script) {
    const { name, window: appWindow, frame, quality = 'medium', hideOthers = true } = options;

    // 1. Set up window
    if (appWindow) {
      await this.focusWindow(appWindow);
      if (frame) {
        await this.positionWindow(appWindow, frame);
      }
      if (hideOthers) {
        await this.hideOthers(appWindow);
      }
      // Small delay to let window settle
      await sleep(300);
    }

    // 2. Start recording
    const session = await this.start({ name, quality, window_title: appWindow });
    console.log(`🎬 Recording started: ${session.session_id}`);

    let result;
    try {
      // 3. Run the demo script
      await script(this);

      // 4. Stop and get video
      result = await this.stop();
      console.log(`✅ Recording saved: ${result.video_path}`);
    } catch (err) {
      await this.note(`ERROR: ${err.message}`).catch(() => {});
      await this.stop().catch(() => {});
      throw err;
    }

    return {
      videoPath: result.video_path,
      metadata: result.metadata,
    };
  }
}

  // ── Live Stream ──────────────────────────────────────────────────────────────

  /**
   * Subscribe to real-time frame events via Server-Sent Events.
   *
   * Each frame is delivered as a parsed object:
   *   { ts, width, height, format, size, data: Buffer }
   *
   * @param {object}   opts
   * @param {number}   [opts.fps=2]      - Frames per second (1–30)
   * @param {number}   [opts.scale=1280] - Max output width in pixels
   * @param {string}   [opts.format='jpeg'] - 'jpeg' or 'png'
   * @param {number}   [opts.quality=60] - JPEG quality 0–100
   * @param {Function} opts.onFrame      - Called with each frame object
   * @param {Function} [opts.onError]    - Called on stream errors
   * @param {AbortSignal} [opts.signal]  - Pass an AbortController.signal to stop
   * @returns {Promise<void>}            - Resolves when stream ends
   *
   * @example
   * const controller = new AbortController();
   * sm.stream({ fps: 2, scale: 640, onFrame: (f) => {
   *   fs.writeFileSync('/tmp/latest.jpg', f.data);
   *   console.log(`Frame ${f.width}×${f.height} ${f.size} bytes`);
   * }, signal: controller.signal });
   *
   * // Stop after 30s
   * setTimeout(() => controller.abort(), 30000);
   */
  async stream(opts = {}) {
    const { fps = 2, scale = 1280, format = 'jpeg', quality = 60,
            onFrame, onError, signal } = opts;

    if (typeof onFrame !== 'function') throw new Error('stream() requires opts.onFrame callback');

    const params = new URLSearchParams({ fps, scale, format, quality });
    const url = `${this.baseURL}/stream?${params}`;

    const http = require('http');
    return new Promise((resolve, reject) => {
      const req = http.get(url, (res) => {
        if (res.statusCode !== 200) {
          reject(new Error(`Stream returned HTTP ${res.statusCode}`));
          return;
        }

        let buffer = '';
        let currentEvent = 'message';
        let currentData = '';

        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          buffer += chunk;
          const lines = buffer.split('\n');
          buffer = lines.pop(); // keep incomplete last line

          for (const line of lines) {
            if (line.startsWith('event:')) {
              currentEvent = line.slice(6).trim();
            } else if (line.startsWith('data:')) {
              currentData = line.slice(5).trim();
            } else if (line.startsWith(':')) {
              // heartbeat — ignore
            } else if (line === '') {
              // End of event
              if (currentData && currentEvent === 'frame') {
                try {
                  const payload = JSON.parse(currentData);
                  const frame = {
                    ts: payload.ts,
                    width: payload.width,
                    height: payload.height,
                    format: payload.format,
                    size: payload.size,
                    data: Buffer.from(payload.data, 'base64'),
                  };
                  onFrame(frame);
                } catch (e) {
                  if (onError) onError(e);
                }
              }
              currentEvent = 'message';
              currentData = '';
            }
          }
        });

        res.on('end', () => resolve());
        res.on('error', (err) => {
          if (onError) onError(err);
          resolve(); // don't reject — stream end is expected
        });
      });

      req.on('error', reject);

      if (signal) {
        signal.addEventListener('abort', () => {
          req.destroy();
          resolve();
        });
      }
    });
  }

  /**
   * Capture frames for a fixed duration, returning an array of frame objects.
   *
   * @param {number} durationMs   - How long to stream in milliseconds
   * @param {object} [opts={}]    - Same opts as stream() except onFrame/signal
   * @returns {Promise<Array>}    - Array of frame objects
   */
  async captureFrames(durationMs, opts = {}) {
    const frames = [];
    const controller = new AbortController();
    setTimeout(() => controller.abort(), durationMs);
    await this.stream({ ...opts, onFrame: (f) => frames.push(f), signal: controller.signal });
    return frames;
  }
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

module.exports = { ScreenMuse, sleep };
