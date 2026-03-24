/**
 * Batch demo generation — generate multiple demo videos unattended.
 *
 * Run one script, get N perfect videos. Each one:
 *   - Records the relevant browser flow
 *   - Gets trimmed to remove dead time
 *   - Gets exported as a GIF for docs/marketing
 *
 * Run: node examples/batch-demos.js
 */

const { chromium } = require('playwright');
const { ScreenMusePlaywright } = require('../');

const sm = new ScreenMusePlaywright();

const DEMOS = [
  {
    name: 'homepage-tour',
    script: async (page) => {
      await page.goto('https://example.com');
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(2000);
    },
  },
  {
    name: 'github-search',
    script: async (page) => {
      await page.goto('https://github.com');
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(1500);
    },
  },
  {
    name: 'hacker-news',
    script: async (page) => {
      await page.goto('https://news.ycombinator.com');
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(1500);
    },
  },
];

async function generateDemo(demo) {
  console.log(`\n🎬 Recording: ${demo.name}`);

  const result = await sm.recordBrowser({
    name: demo.name,
    quality: 'high',
    browser: chromium,
    autoChapters: true,
    launchOptions: { args: ['--window-size=1440,900'] },
  }, demo.script);

  console.log(`   ✅ Video: ${result.videoPath} (${result.duration?.toFixed(1)}s)`);

  // Trim silence from start/end
  const trimmed = await result.trim({ start: 0.5 });
  console.log(`   ✂️  Trimmed: ${trimmed.videoPath}`);

  // Export GIF for docs
  const gif = await trimmed.exportGif({ fps: 8, scale: 640 });
  console.log(`   📦 GIF: ${gif.path} (${gif.size_mb?.toFixed(1)}MB)`);

  return { name: demo.name, videoPath: trimmed.videoPath, gifPath: gif.path };
}

async function main() {
  console.log(`Generating ${DEMOS.length} demo videos...\n`);

  const results = [];
  for (const demo of DEMOS) {
    // Sequential to avoid window conflicts (parallel is fine with separate PIDs)
    try {
      const r = await generateDemo(demo);
      results.push({ ok: true, ...r });
    } catch (err) {
      console.error(`   ❌ ${demo.name} failed: ${err.message}`);
      results.push({ ok: false, name: demo.name, error: err.message });
    }
  }

  console.log('\n── Summary ──────────────────────────────────────────');
  results.forEach(r => {
    if (r.ok) {
      console.log(`✅ ${r.name}`);
      console.log(`   Video: ${r.videoPath}`);
      console.log(`   GIF:   ${r.gifPath}`);
    } else {
      console.log(`❌ ${r.name}: ${r.error}`);
    }
  });

  const passed = results.filter(r => r.ok).length;
  console.log(`\n${passed}/${results.length} demos generated`);
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
