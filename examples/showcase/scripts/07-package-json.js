/**
 * Demo 7: Package.json Exploration
 * 
 * View package.json file
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '07-package-json', async (page) => {
    console.log('📍 Navigating to screenmuse-playwright package...');
    // Go directly to the package
    await page.goto('https://github.com/hnshah/screenmuse/tree/main/packages/screenmuse-playwright');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(3000);
    
    console.log('✅ Package directory loaded');
    
    // Scroll to show files
    console.log('📜 Scrolling to files...');
    await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
    await sleep(2000);
    
    // Click package.json
    console.log('🔍 Looking for package.json...');
    try {
      let packageLink = page.locator('a[href*="package.json"]').first();
      
      if (await packageLink.count() === 0) {
        packageLink = page.getByRole('link', { name: /package\.json/i }).first();
      }
      
      console.log('✅ package.json found');
      console.log('👆 Clicking package.json...');
      await packageLink.evaluate(el => el.click());
      
      await page.waitForURL(/package\.json/, { timeout: 10000 });
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3000);
      
      console.log('✅ package.json loaded:', page.url());
      
      // Scroll through file
      console.log('📜 Scrolling file...');
      await page.evaluate(() => window.scrollBy({ top: 300, behavior: 'smooth' }));
      await sleep(2000);
      
      console.log('📜 Scrolling to dependencies...');
      await page.evaluate(() => window.scrollBy({ top: 300, behavior: 'smooth' }));
      await sleep(2000);
      
      console.log('📜 Scrolling more...');
      await page.evaluate(() => window.scrollBy({ top: 300, behavior: 'smooth' }));
      await sleep(1500);
      
    } catch (error) {
      console.error('❌ Failed to open package.json:', error.message);
      await page.screenshot({ path: '/tmp/demo7-error.png' });
      throw error;
    }
    
    console.log('✅ Navigation complete');
  });
  
  console.log('🎉 Demo 7 complete!');
}

main().catch(console.error);
