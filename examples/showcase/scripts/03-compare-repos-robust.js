/**
 * Demo 3: Compare Repositories
 * 
 * Compare ScreenMuse and Verdict repos
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '03-compare-repos', async (page) => {
    // ScreenMuse repo
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(3000); // +50%
    
    // Scroll to show stars/forks
    await page.evaluate(() => window.scrollBy({ top: 300, behavior: 'smooth' }));
    await sleep(2250); // +50%
    
    // Navigate to Verdict
    await page.goto('https://github.com/hnshah/verdict');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(3000); // +50%
    
    // Scroll
    await page.evaluate(() => window.scrollBy({ top: 300, behavior: 'smooth' }));
    await sleep(2250); // +50%
    
    // Back to ScreenMuse
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(2250); // +50%
  });
  
  console.log('🎉 Demo 3 complete!');
}

main().catch(console.error);
