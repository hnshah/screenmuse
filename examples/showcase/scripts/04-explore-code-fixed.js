/**
 * Demo 4: Explore Code (FIXED)
 * 
 * Uses robust selectors and fail-fast error handling
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '04-explore-code', async (page) => {
    console.log('📍 Navigating to ScreenMuse repo...');
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(3500);
    
    // Navigate to packages folder
    console.log('🔍 Looking for packages folder...');
    try {
      // FIXED: Use robust selector strategies
      let packagesLink;
      
      // Strategy 1: By href ending
      packagesLink = page.locator('a[href$="/packages"]').first();
      
      if (await packagesLink.count() === 0) {
        // Strategy 2: By text content  
        console.log('  Strategy 1 failed, trying by text...');
        packagesLink = page.getByRole('link', { name: 'packages' }).first();
      }
      
      if (await packagesLink.count() === 0) {
        // Strategy 3: By partial href
        console.log('  Strategy 2 failed, trying by partial href...');
        packagesLink = page.locator('a[href*="/tree/"][href*="/packages"]').first();
      }
      
      console.log('✅ packages link found');
      
      console.log('👆 Clicking packages/ (using evaluate)...');
      await packagesLink.evaluate(el => el.click());
      
      console.log('⏳ Waiting for packages directory...');
      await page.waitForURL(/\/tree\/.*\/packages/, { timeout: 10000 });
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3500);
      
      console.log('✅ packages/ loaded, current URL:', page.url());
      
    } catch (error) {
      console.error('❌ Failed to navigate to packages:', error.message);
      console.error('Current URL:', page.url());
      await page.screenshot({ path: '/tmp/demo4-error-1.png' });
      throw error;
    }
    
    // Click screenmuse-playwright
    console.log('🔍 Looking for screenmuse-playwright...');
    try {
      let playwrightLink;
      
      // Strategy 1: By href containing screenmuse-playwright
      playwrightLink = page.locator('a[href*="screenmuse-playwright"]').first();
      
      if (await playwrightLink.count() === 0) {
        // Strategy 2: By text
        console.log('  Strategy 1 failed, trying by text...');
        playwrightLink = page.getByRole('link', { name: 'screenmuse-playwright' }).first();
      }
      
      console.log('✅ screenmuse-playwright link found');
      
      console.log('👆 Clicking screenmuse-playwright/ (using evaluate)...');
      await playwrightLink.evaluate(el => el.click());
      
      await page.waitForURL(/screenmuse-playwright/, { timeout: 10000 });
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3500);
      
      console.log('✅ screenmuse-playwright/ loaded');
      
      // Scroll to show files
      console.log('📜 Scrolling...');
      await page.evaluate(() => window.scrollBy({ top: 300, behavior: 'smooth' }));
      await sleep(2500);
      
    } catch (error) {
      console.error('❌ Failed to navigate to screenmuse-playwright:', error.message);
      await page.screenshot({ path: '/tmp/demo4-error-2.png' });
      throw error;
    }
    
    // Click on index.js
    console.log('🔍 Looking for index.js...');
    try {
      let indexLink;
      
      // Strategy 1: By href containing index.js
      indexLink = page.locator('a[href*="index.js"]').first();
      
      if (await indexLink.count() === 0) {
        // Strategy 2: By text
        console.log('  Strategy 1 failed, trying by text...');
        indexLink = page.getByRole('link', { name: 'index.js' }).first();
      }
      
      console.log('✅ index.js link found');
      
      console.log('👆 Clicking index.js (using evaluate)...');
      await indexLink.evaluate(el => el.click());
      
      await page.waitForURL(/\/blob\/.*index\.js/, { timeout: 10000 });
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3000);
      
      console.log('✅ index.js loaded');
      
      // Scroll through code
      console.log('📜 Scrolling code...');
      await page.evaluate(() => window.scrollBy({ top: 500, behavior: 'smooth' }));
      await sleep(2250);
      
    } catch (error) {
      console.error('❌ Failed to open index.js:', error.message);
      await page.screenshot({ path: '/tmp/demo4-error-3.png' });
      throw error;
    }
    
    console.log('✅ All navigation complete!');
  });
  
  console.log('🎉 Demo 4 complete!');
}

main().catch(console.error);
