/**
 * Basic demo — record a GitHub search and export as GIF.
 *
 * Run: node examples/basic-demo.js
 * Requires: ScreenMuse.app running + `npm install playwright`
 */

const { chromium } = require('playwright');
const { ScreenMusePlaywright } = require('../');

async function main() {
  const sm = new ScreenMusePlaywright();

  console.log('🎬 Starting recording...');

  const result = await sm.recordBrowser({
    name: 'github-search-demo',
    quality: 'high',
    browser: chromium,
    autoChapters: true,          // ← "github.com", "Search Results" added automatically
    launchOptions: {
      args: ['--window-size=1440,900'],
    },
  }, async (page) => {
    await page.goto('https://github.com');
    await page.waitForLoadState('networkidle');

    await page.getByLabel('Search or jump to…').click();
    await page.keyboard.type('screenmuse');
    await page.keyboard.press('Enter');
    await page.waitForLoadState('networkidle');
  });

  console.log(`✅ Video saved: ${result.videoPath}`);
  console.log(`   Duration: ${result.duration?.toFixed(1)}s`);
  console.log(`   Chapters: ${result.chapters.map(c => c.name).join(', ')}`);

  // Export as GIF for README or docs
  console.log('\n📦 Exporting GIF...');
  const gif = await result.exportGif({ fps: 10, scale: 600 });
  console.log(`✅ GIF: ${gif.path} (${gif.size_mb?.toFixed(1)}MB)`);
}

main().catch(err => {
  console.error('❌', err.message);
  process.exit(1);
});
