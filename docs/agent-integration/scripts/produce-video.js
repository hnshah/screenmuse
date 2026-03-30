#!/usr/bin/env node
/**
 * produce-video.js — Autonomous video production runner for AI agents
 *
 * Orchestrates the full recording pipeline:
 *   pre-flight checks → browser launch → window positioning →
 *   ScreenMuse start → workflow execution → stop → quality validation → GIF export
 *
 * Prerequisites:
 *   npm install playwright
 *   npx playwright install chromium
 *   ScreenMuse running: curl http://localhost:7823/status
 *
 * Usage:
 *   node scripts/produce-video.js --workflow=google-search --query="stripe api docs"
 *   node scripts/produce-video.js --workflow=docs-navigation --url="https://nextjs.org/docs"
 *   node scripts/produce-video.js --custom=./my-workflow.js
 *   node scripts/produce-video.js --workflow=google-search --quality=high --duration=30
 */

const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

// ── Configuration ─────────────────────────────────────────────────────────────

const SCREENMUSE_URL = process.env.SCREENMUSE_URL || 'http://localhost:7823';
const QUALITY_THRESHOLD_MB_PER_S = parseFloat(process.env.QUALITY_THRESHOLD || '0.05');
const WINDOW_WIDTH = parseInt(process.env.WINDOW_WIDTH || '1440');
const WINDOW_HEIGHT = parseInt(process.env.WINDOW_HEIGHT || '900');

// Parse CLI args
const args = parseArgs(process.argv.slice(2));

// ── ScreenMuse Client ─────────────────────────────────────────────────────────

class ScreenMuse {
  constructor(baseURL = SCREENMUSE_URL) {
    this.baseURL = baseURL;
    this.apiKey = process.env.SCREENMUSE_API_KEY || readAPIKey();
  }

  async request(method, endpoint, body) {
    const headers = { 'Content-Type': 'application/json' };
    if (this.apiKey) headers['X-ScreenMuse-Key'] = this.apiKey;

    const res = await fetch(`${this.baseURL}${endpoint}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });

    const json = await res.json().catch(() => ({}));
    if (!res.ok) {
      throw new Error(`ScreenMuse ${method} ${endpoint} → ${res.status}: ${json.error || JSON.stringify(json)}`);
    }
    return json;
  }

  async status() { return this.request('GET', '/status'); }
  async health() { return this.request('GET', '/health'); }

  async start(options = {}) {
    return this.request('POST', '/start', options);
  }

  async stop() { return this.request('POST', '/stop'); }
  async chapter(name) { return this.request('POST', '/chapter', { name }); }
  async highlight() { return this.request('POST', '/highlight'); }
  async note(text) { return this.request('POST', '/note', { text }); }

  async export(videoPath, format = 'gif') {
    return this.request('POST', '/export', { path: videoPath, format, async: true });
  }

  async pollJob(jobId, timeoutMs = 60000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const job = await this.request('GET', `/job/${jobId}`);
      if (job.status === 'completed') return job.result;
      if (job.status === 'failed') throw new Error(`Job ${jobId} failed: ${job.error}`);
      await sleep(1000);
    }
    throw new Error(`Job ${jobId} timed out after ${timeoutMs}ms`);
  }

  async windows() { return this.request('GET', '/windows'); }

  async focusWindow(app) {
    return this.request('POST', '/window/focus', { app });
  }

  async positionWindow(app, frame) {
    return this.request('POST', '/window/position', { app, ...frame });
  }
}

// ── Pre-flight Checks ─────────────────────────────────────────────────────────

async function preflight(sm) {
  console.log('🔍 Pre-flight checks...');

  // 1. ScreenMuse responding
  let health;
  try {
    health = await sm.health();
  } catch (e) {
    throw new Error(
      `ScreenMuse not responding at ${SCREENMUSE_URL}\n` +
      'Fix: Ensure ScreenMuse.app is running and HTTP server is started.\n' +
      'Check: curl http://localhost:7823/status'
    );
  }

  // 2. Screen recording permission
  if (health.permissions?.screen_recording === false) {
    throw new Error(
      'Screen recording permission not granted.\n' +
      'Fix: System Settings → Privacy & Security → Screen Recording → ScreenMuse ✓\n' +
      'Then relaunch ScreenMuse.'
    );
  }

  // 3. Not already recording
  const status = await sm.status();
  if (status.recording) {
    throw new Error(
      'ScreenMuse is already recording. Stop the current recording first:\n' +
      'curl -X POST http://localhost:7823/stop'
    );
  }

  console.log(`✅ ScreenMuse ${health.version || 'ready'} — pre-flight passed`);
  return health;
}

// ── Quality Validation ────────────────────────────────────────────────────────

function validateQuality(result) {
  const { path: videoPath, duration, size_mb } = result;

  if (!videoPath || !fs.existsSync(videoPath)) {
    throw new Error(`Video file not found: ${videoPath}`);
  }

  const stats = fs.statSync(videoPath);
  if (stats.size === 0) {
    throw new Error('Video file is empty — recording may have failed silently');
  }

  if (duration && size_mb) {
    const mbPerSecond = size_mb / duration;
    if (mbPerSecond < QUALITY_THRESHOLD_MB_PER_S) {
      throw new Error(
        `Quality check failed: ${mbPerSecond.toFixed(3)} MB/s is below threshold ${QUALITY_THRESHOLD_MB_PER_S} MB/s\n` +
        'The video likely contains no content. Check screen recording permissions.'
      );
    }
    console.log(`✅ Quality: ${mbPerSecond.toFixed(3)} MB/s (${size_mb.toFixed(1)} MB, ${duration.toFixed(1)}s)`);
  }

  return videoPath;
}

// ── GIF Export ────────────────────────────────────────────────────────────────

async function exportGIF(sm, videoPath) {
  console.log('🎬 Exporting GIF...');
  try {
    const job = await sm.export(videoPath, 'gif');
    if (job.job_id) {
      const result = await sm.pollJob(job.job_id);
      console.log(`✅ GIF: ${result.path}`);
      return result.path;
    }
    if (job.path) {
      console.log(`✅ GIF: ${job.path}`);
      return job.path;
    }
  } catch (e) {
    console.warn(`⚠️  GIF export failed (non-fatal): ${e.message}`);
  }
  return null;
}

// ── Main Runner ───────────────────────────────────────────────────────────────

async function main() {
  const sm = new ScreenMuse();

  // Pre-flight
  await preflight(sm);

  // Load workflow
  const workflow = await loadWorkflow(args);

  // Launch browser
  console.log(`🌐 Launching browser (${WINDOW_WIDTH}×${WINDOW_HEIGHT})...`);
  const browser = await chromium.launch({
    headless: false,
    args: [
      `--window-size=${WINDOW_WIDTH},${WINDOW_HEIGHT}`,
      '--window-position=0,0',
      '--no-default-browser-check',
      '--disable-extensions',
    ],
  });

  const context = await browser.newContext({
    viewport: { width: WINDOW_WIDTH, height: WINDOW_HEIGHT - 70 },
  });
  const page = await context.newPage();

  let videoResult = null;
  let gifPath = null;

  try {
    // Position window
    await sleep(500); // let browser fully open
    try {
      await sm.positionWindow('Chromium', {
        x: 0, y: 0,
        width: WINDOW_WIDTH,
        height: WINDOW_HEIGHT,
      });
    } catch {
      // Non-fatal — window positioning may fail if window isn't detected yet
    }

    // Start recording
    const recordingName = args.name || `${workflow.name}-${Date.now()}`;
    console.log(`📹 Starting recording: ${recordingName}`);
    await sm.start({
      name: recordingName,
      window: 'Chromium',
      quality: args.quality || 'high',
    });

    // Run workflow
    console.log(`▶️  Running workflow: ${workflow.name}`);
    await workflow.run(page, sm, args);

    // Stop recording
    console.log('⏹️  Stopping recording...');
    videoResult = await sm.stop();

    // Validate quality
    const videoPath = validateQuality(videoResult);
    console.log(`✅ Video: ${videoPath}`);

    // Export GIF
    gifPath = await exportGIF(sm, videoPath);

    return { video: videoPath, gif: gifPath, metadata: videoResult };
  } finally {
    await browser.close();
  }
}

// ── Workflow Loader ───────────────────────────────────────────────────────────

async function loadWorkflow(args) {
  if (args.custom) {
    const customPath = path.resolve(args.custom);
    if (!fs.existsSync(customPath)) {
      throw new Error(`Custom workflow not found: ${customPath}`);
    }
    return require(customPath);
  }

  const workflowName = args.workflow || 'google-search';
  const builtins = {
    'google-search': () => require('../workflows/google-search.js'),
    'docs-navigation': () => require('../workflows/docs-navigation.js'),
    'product-demo': () => require('../workflows/product-demo.js'),
  };

  if (!builtins[workflowName]) {
    const available = Object.keys(builtins).join(', ');
    throw new Error(`Unknown workflow: ${workflowName}\nAvailable: ${available}\nOr use --custom=./my-workflow.js`);
  }

  return builtins[workflowName]();
}

// ── Utilities ─────────────────────────────────────────────────────────────────

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function parseArgs(argv) {
  const result = {};
  for (const arg of argv) {
    const [key, ...rest] = arg.replace(/^--/, '').split('=');
    result[key] = rest.join('=') || true;
  }
  return result;
}

function readAPIKey() {
  try {
    const keyPath = path.join(process.env.HOME || '~', '.screenmuse', 'api_key');
    if (fs.existsSync(keyPath)) {
      return fs.readFileSync(keyPath, 'utf8').trim();
    }
  } catch {
    // No key file — authentication may be disabled
  }
  return null;
}

// ── Entry Point ───────────────────────────────────────────────────────────────

main()
  .then(result => {
    console.log('\n✅ Production complete!');
    console.log(`   Video: ${result.video}`);
    if (result.gif) console.log(`   GIF:   ${result.gif}`);
    process.exit(0);
  })
  .catch(err => {
    console.error('\n❌ Production failed:', err.message);
    process.exit(1);
  });
