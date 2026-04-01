/**
 * Demo 1: Hello World
 * 
 * The simplest possible demo - navigation with auto-chapters.
 * Shows: window capture, auto-chapters, clean output
 */

const { chromium } = require('playwright');
const { ScreenMusePlaywright } = require('../../../packages/screenmuse-playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function main() {
  console.log('🎬 Demo 1: Hello World');
  console.log('─'.repeat(50));
  
  const sm = new ScreenMusePlaywright();
  
  const result = await sm.recordBrowser({
    browser: chromium,
    name: '01-hello-world',
    quality: 'high',
    autoChapters: true,
    launchOptions: {
      headless: false,
      args: ['--window-size=1440,900']
    }
  }, async (page) => {
    // Wait for browser window to be ready and focused
    await sleep(1000);
    
    // Bring window to front
    await page.bringToFront();
    await sleep(500);
    
    // Navigate to example.com
    await page.goto('https://example.com');
    await page.waitForLoadState('networkidle');
    await sleep(2000);
    
    // Scroll to show content
    await page.evaluate(() => window.scrollBy(0, 300));
    await sleep(1500);
    
    // Navigate to example.org (triggers chapter)
    await page.goto('https://example.org');
    await page.waitForLoadState('networkidle');
    await sleep(2000);
    
    // Scroll again
    await page.evaluate(() => window.scrollBy(0, 300));
    await sleep(1000);
  });
  
  console.log('✅ Recording complete!');
  console.log(`   Video: ${result.videoPath}`);
  console.log(`   Duration: ${result.duration.toFixed(1)}s`);
  console.log(`   Chapters: ${result.chapters.length}`);
  
  // Export GIF
  console.log('\n📤 Exporting GIF...');
  const gif = await result.exportGif({
    fps: 10,
    scale: 600
  });
  
  console.log(`✅ GIF exported: ${gif.path}`);
  console.log(`   Size: ${(gif.size / 1024 / 1024).toFixed(2)}MB`);
  
  console.log('\n🎉 Demo 1 complete!');
}

main().catch(console.error);
