/**
 * Demo 2: Browse Repository (FIXED)
 * 
 * Uses robust selectors and fail-fast error handling
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '02-repo-browse', async (page) => {
    console.log('📍 Navigating to ScreenMuse repo...');
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(3750);
    
    console.log('📜 Scrolling to file list...');
    // Scroll specifically to the file list area
    await page.evaluate(() => {
      const fileList = document.querySelector('[aria-labelledby*="file"]') || 
                      document.querySelector('[role="grid"]');
      if (fileList) {
        fileList.scrollIntoView({ behavior: 'smooth', block: 'center' });
      } else {
        window.scrollBy({ top: 600, behavior: 'smooth' });
      }
    });
    await sleep(2000);
    
    // FIXED: Use robust selector without silent failure
    console.log('🔍 Looking for README.md link...');
    try {
      // Try multiple selector strategies
      let readmeLink;
      
      // Strategy 1: By href pattern
      readmeLink = page.locator('a[href*="/blob/"][href*="README.md"]').first();
      
      if (await readmeLink.count() === 0) {
        // Strategy 2: By role and name
        console.log('  Strategy 1 failed, trying getByRole...');
        readmeLink = page.getByRole('link', { name: /README\.md/i }).first();
      }
      
      if (await readmeLink.count() === 0) {
        // Strategy 3: By text content
        console.log('  Strategy 2 failed, trying by text...');
        readmeLink = page.locator('a:has-text("README.md")').first();
      }
      
      console.log('✅ README link found');
      
      console.log('👆 Clicking README.md (using evaluate)...');
      // GitHub's virtual scrolling makes elements "not visible" even with force:true
      // Use evaluate to click directly in the browser context
      await readmeLink.evaluate(el => el.click());
      
      console.log('⏳ Waiting for file view...');
      await page.waitForURL(/\/blob\//, { timeout: 10000 });
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3000);
      
      console.log('✅ README.md loaded, current URL:', page.url());
      
      // Scroll in file view
      console.log('📜 Scrolling file view...');
      await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
      await sleep(2250);
      
    } catch (error) {
      console.error('❌ Failed to navigate to README:', error.message);
      console.error('Current URL:', page.url());
      
      // Take screenshot for debugging
      await page.screenshot({ path: '/tmp/demo2-error.png' });
      console.error('Screenshot saved to /tmp/demo2-error.png');
      
      throw error; // Fail loudly, don't continue
    }
  });
  
  console.log('🎉 Demo 2 complete!');
}

main().catch(console.error);
