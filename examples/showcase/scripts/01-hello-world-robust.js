/**
 * Demo 1: Hello World (Robust Version)
 * 
 * Uses explicit window PID detection to ensure window-only capture
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '01-hello-world', async (page) => {
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
  
  console.log('🎉 Demo 1 complete!');
  console.log(`   Video: ${result.video}`);
  console.log(`   GIF: ${result.gif}`);
}

main().catch(console.error);
