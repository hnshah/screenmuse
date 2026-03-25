/**
 * Demo 4: Explore Code
 * 
 * Dive into the screenmuse-playwright package code
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '04-explore-code', async (page) => {
    // Go to ScreenMuse repo
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(3500); // Increase further for Demo 4
    
    // Navigate to packages folder
    const packagesLink = page.locator('a[href*="/tree/"][title*="packages"]').first();
    if (await packagesLink.isVisible()) {
      await packagesLink.click();
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3500); // Increase further
    }
    
    // Click screenmuse-playwright
    const playwrightLink = page.locator('a:has-text("screenmuse-playwright")').first();
    if (await playwrightLink.isVisible()) {
      await playwrightLink.click();
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3500); // Increase further
      
      // Scroll to show files
      await page.evaluate(() => window.scrollBy({ top: 300, behavior: 'smooth' }));
      await sleep(2500); // Increase further
    }
    
    // Click on index.js
    const indexLink = page.locator('a[href*="index.js"]').first();
    if (await indexLink.isVisible()) {
      await indexLink.click();
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3000); // +50%
      
      // Scroll through code
      await page.evaluate(() => window.scrollBy({ top: 500, behavior: 'smooth' }));
      await sleep(2250); // +50%
    }
  });
  
  console.log('🎉 Demo 4 complete!');
}

main().catch(console.error);
