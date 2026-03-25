/**
 * Demo 1: GitHub Search
 * 
 * Navigate GitHub and search for ScreenMuse repo
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '01-github-search', async (page) => {
    // Go to GitHub
    await page.goto('https://github.com');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(3000); // +50%
    
    // Click search
    await page.getByLabel('Search or jump to…').click();
    await sleep(1500); // +50%
    
    // Type "screenmuse"
    await page.keyboard.type('screenmuse', { delay: 150 });
    await sleep(2250); // +50%
    
    // Press Enter to search
    await page.keyboard.press('Enter');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(3750); // +50%
    
    // Click on hnshah/screenmuse result
    const repoLink = page.locator('a:has-text("hnshah/screenmuse")').first();
    if (await repoLink.isVisible()) {
      await repoLink.click();
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3000); // +50%
    }
  });
  
  console.log('🎉 Demo 1 complete!');
  console.log(`   Video: ${result.video}`);
  console.log(`   GIF: ${result.gif}`);
}

main().catch(console.error);
