/**
 * Demo 4: GitHub Workflow
 * 
 * Real-world navigation example.
 * Shows: multiple pages, auto-chapters, realistic usage
 */

const { chromium } = require('playwright');
const { ScreenMusePlaywright } = require('../../../packages/screenmuse-playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function main() {
  console.log('🎬 Demo 4: GitHub Workflow');
  console.log('─'.repeat(50));
  
  const sm = new ScreenMusePlaywright();
  
  const result = await sm.recordBrowser({
    browser: chromium,
    name: '04-github-workflow',
    quality: 'high',
    autoChapters: true,
    launchOptions: {
      headless: false,
      args: ['--window-size=1440,900']
    }
  }, async (page) => {
    // Wait for window focus
    await sleep(1000);
    await page.bringToFront();
    await sleep(500);
    
    // Navigate to ScreenMuse repo
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await sleep(2500);
    
    // Scroll to show README
    await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
    await sleep(2000);
    
    // More scrolling
    await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
    await sleep(2000);
    
    // Click on a file (if available)
    const fileLink = page.locator('a[title="README.md"]').first();
    if (await fileLink.isVisible()) {
      await fileLink.click();
      await page.waitForLoadState('networkidle');
      await sleep(2000);
      
      // Scroll the file view
      await page.evaluate(() => window.scrollBy({ top: 300, behavior: 'smooth' }));
      await sleep(1500);
    }
    
    // Navigate to Verdict repo
    await page.goto('https://github.com/hnshah/verdict');
    await page.waitForLoadState('networkidle');
    await sleep(2500);
    
    // Scroll
    await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
    await sleep(2000);
  });
  
  console.log('✅ Recording complete!');
  console.log(`   Video: ${result.videoPath}`);
  console.log(`   Duration: ${result.duration.toFixed(1)}s`);
  console.log(`   Chapters: ${result.chapters.length}`);
  
  result.chapters.forEach((ch, i) => {
    console.log(`      ${i + 1}. ${ch.name} (${ch.time.toFixed(1)}s)`);
  });
  
  // Export GIF
  console.log('\n📤 Exporting GIF...');
  const gif = await result.exportGif({
    fps: 12,
    scale: 700
  });
  
  console.log(`✅ GIF exported: ${gif.path}`);
  console.log(`   Size: ${(gif.size / 1024 / 1024).toFixed(2)}MB`);
  
  console.log('\n🎉 Demo 4 complete!');
}

main().catch(console.error);
