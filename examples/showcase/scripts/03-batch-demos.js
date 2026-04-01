/**
 * Demo 3: Batch Demo Factory
 * 
 * Generate multiple demos automatically.
 * Shows: batch recording, consistency, demo factory pattern
 */

const { chromium } = require('playwright');
const { ScreenMusePlaywright } = require('../../../packages/screenmuse-playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

const DEMOS = [
  {
    name: '03-batch-example-com',
    url: 'https://example.com',
    title: 'Example Domain'
  },
  {
    name: '03-batch-example-org',
    url: 'https://example.org',
    title: 'Example Organization'
  },
  {
    name: '03-batch-example-net',
    url: 'https://example.net',
    title: 'Example Network'
  }
];

async function main() {
  console.log('🎬 Demo 3: Batch Demo Factory');
  console.log('─'.repeat(50));
  console.log(`Creating ${DEMOS.length} demos...\n`);
  
  const sm = new ScreenMusePlaywright();
  const results = [];
  
  for (let i = 0; i < DEMOS.length; i++) {
    const demo = DEMOS[i];
    
    console.log(`[${i + 1}/${DEMOS.length}] Recording: ${demo.title}`);
    
    const result = await sm.recordBrowser({
      browser: chromium,
      name: demo.name,
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
      
      await page.goto(demo.url);
      await page.waitForLoadState('networkidle');
      await sleep(2000);
      
      await page.evaluate(() => window.scrollBy(0, 300));
      await sleep(1500);
      
      await page.evaluate(() => window.scrollBy(0, 300));
      await sleep(1000);
    });
    
    console.log(`   ✅ ${result.videoPath}`);
    console.log(`   Duration: ${result.duration.toFixed(1)}s\n`);
    
    // Export GIF
    const gif = await result.exportGif({ fps: 10, scale: 600 });
    results.push({ demo, video: result, gif });
    
    // Small delay between demos
    if (i < DEMOS.length - 1) {
      await sleep(1000);
    }
  }
  
  console.log('─'.repeat(50));
  console.log('📊 Batch Summary:');
  console.log(`   Total demos: ${results.length}`);
  console.log(`   Total duration: ${results.reduce((sum, r) => sum + r.video.duration, 0).toFixed(1)}s`);
  console.log(`   Total GIF size: ${(results.reduce((sum, r) => sum + r.gif.size, 0) / 1024 / 1024).toFixed(2)}MB`);
  
  console.log('\n🎉 Demo 3 complete! All demos created automatically.');
}

main().catch(console.error);
