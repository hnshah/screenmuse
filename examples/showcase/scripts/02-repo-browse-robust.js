/**
 * Demo 2: Repository Browsing
 * 
 * Browse ScreenMuse repo - README, code, files
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '02-repo-browse', async (page) => {
    // Go directly to ScreenMuse repo
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(3750); // +50%
    
    // Scroll down to show README
    await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
    await sleep(3000); // +50%
    
    // Scroll more
    await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
    await sleep(3000); // +50%
    
    // Click on a file (README.md)
    const readmeLink = page.locator('a[title="README.md"]').first();
    if (await readmeLink.isVisible()) {
      await readmeLink.click();
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3000); // +50%
      
      // Scroll in file view
      await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
      await sleep(2250); // +50%
    }
  });
  
  console.log('🎉 Demo 2 complete!');
}

main().catch(console.error);
