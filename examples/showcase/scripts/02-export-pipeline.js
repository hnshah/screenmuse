/**
 * Demo 2: Export Pipeline
 * 
 * Shows chainable exports and multiple formats.
 * Shows: trim, GIF export, WebP export, chainable API
 */

const { chromium } = require('playwright');
const { ScreenMusePlaywright } = require('../../../packages/screenmuse-playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function main() {
  console.log('🎬 Demo 2: Export Pipeline');
  console.log('─'.repeat(50));
  
  const sm = new ScreenMusePlaywright();
  
  // Record a longer demo
  const result = await sm.recordBrowser({
    browser: chromium,
    name: '02-export-pipeline',
    quality: 'high',
    autoChapters: true,
    launchOptions: {
      headless: false,
      args: ['--window-size=1440,900']
    }
  }, async (page) => {
    // Wait for browser window to be ready
    await sleep(1000);
    await page.bringToFront();
    await sleep(500);
    
    await page.goto('https://example.com');
    await sleep(2000);
    
    await page.evaluate(() => window.scrollBy(0, 400));
    await sleep(2000);
    
    await page.goto('https://example.org');
    await sleep(2000);
    
    await page.evaluate(() => window.scrollBy(0, 400));
    await sleep(2000);
    
    await page.goto('https://example.net');
    await sleep(2000);
  });
  
  console.log('✅ Recording complete!');
  console.log(`   Duration: ${result.duration.toFixed(1)}s`);
  
  // Export 1: Trim first
  console.log('\n📤 Export 1: Trimming to first 5s...');
  const trimmed = await result.trim({ start: 0, end: 5 });
  console.log(`✅ Trimmed: ${trimmed.path}`);
  
  // Then export trimmed version as GIF
  console.log('\n📤 Export 2: Converting trimmed to GIF...');
  const trimmedGif = await trimmed.exportGif({ fps: 10, scale: 600 });
  
  console.log(`✅ Trimmed GIF: ${trimmedGif.path}`);
  console.log(`   Size: ${(trimmedGif.size / 1024 / 1024).toFixed(2)}MB`);
  
  // Export 3: Full GIF
  console.log('\n📤 Export 3: Full GIF...');
  const fullGif = await result.exportGif({ fps: 15, scale: 800 });
  
  console.log(`✅ Full GIF: ${fullGif.path}`);
  console.log(`   Size: ${(fullGif.size / 1024 / 1024).toFixed(2)}MB`);
  
  // Export 4: WebP (smaller file size)
  console.log('\n📤 Export 4: WebP...');
  const webp = await result.exportWebP({ quality: 90, scale: 800 });
  
  console.log(`✅ WebP: ${webp.path}`);
  console.log(`   Size: ${(webp.size / 1024 / 1024).toFixed(2)}MB`);
  
  console.log('\n🎉 Demo 2 complete! Four exports from one recording.');
}

main().catch(console.error);
