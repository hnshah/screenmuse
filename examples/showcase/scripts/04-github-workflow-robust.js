/**
 * Demo 4: GitHub Workflow (Robust Version)
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '04-github-workflow', async (page) => {
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
    
    // Navigate to Verdict repo
    await page.goto('https://github.com/hnshah/verdict');
    await page.waitForLoadState('networkidle');
    await sleep(2500);
    
    // Scroll
    await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
    await sleep(2000);
  });
  
  console.log('🎉 Demo 4 complete!');
}

main().catch(console.error);
