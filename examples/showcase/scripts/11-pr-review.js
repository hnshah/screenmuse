/**
 * Demo 11: Pull Request Review
 * 
 * Complex multi-step GitHub workflow: navigate PR, view files, comments
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '11-pr-review', async (page) => {
    console.log('📍 Navigating to ScreenMuse repo...');
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await sleep(2500);
    
    // Click Pull requests tab
    console.log('🔍 Looking for Pull requests tab...');
    try {
      let prTab = page.locator('a[href*="/pulls"]').first();
      
      if (await prTab.count() === 0) {
        prTab = page.getByRole('link', { name: /Pull requests/i }).first();
      }
      
      console.log('✅ Pull requests tab found');
      console.log('👆 Clicking Pull requests...');
      await prTab.evaluate(el => el.click());
      
      await page.waitForURL(/\/pulls/, { timeout: 10000 });
      await page.waitForLoadState('networkidle');
      await sleep(3000);
      
      console.log('✅ Pull requests page loaded:', page.url());
      
      // Scroll to show PR list
      console.log('📜 Scrolling to show PRs...');
      await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
      await sleep(2000);
      
      // Look for a PR (open or closed)
      console.log('🔍 Looking for a pull request...');
      
      // Try to find any PR link
      const prLinks = await page.locator('a[href*="/pull/"]').all();
      
      if (prLinks.length > 0) {
        console.log(`✅ Found ${prLinks.length} PRs`);
        console.log('👆 Clicking first PR...');
        
        await prLinks[0].evaluate(el => el.click());
        await sleep(3000);
        await page.waitForLoadState('networkidle');
        
        console.log('✅ PR opened:', page.url());
        
        // Scroll through PR
        console.log('📜 Scrolling PR description...');
        await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
        await sleep(2000);
        
        // Look for Files changed tab
        console.log('🔍 Looking for Files changed tab...');
        const filesTab = page.locator('a[href*="/files"]').first();
        
        if (await filesTab.count() > 0) {
          console.log('✅ Files changed tab found');
          console.log('👆 Clicking Files changed...');
          await filesTab.evaluate(el => el.click());
          
          await sleep(3000);
          await page.waitForLoadState('networkidle');
          
          console.log('✅ Files changed view loaded');
          
          // Scroll through diff
          console.log('📜 Scrolling through file changes...');
          await page.evaluate(() => window.scrollBy({ top: 500, behavior: 'smooth' }));
          await sleep(2000);
          
          await page.evaluate(() => window.scrollBy({ top: 500, behavior: 'smooth' }));
          await sleep(1500);
        }
      } else {
        console.log('⚠️  No PRs found, showing empty state...');
        await page.evaluate(() => window.scrollBy({ top: 600, behavior: 'smooth' }));
        await sleep(3000);
      }
      
    } catch (error) {
      console.error('❌ Failed to navigate PRs:', error.message);
      await page.screenshot({ path: '/tmp/demo11-error.png' });
      throw error;
    }
    
    console.log('✅ PR review navigation complete');
  });
  
  console.log('🎉 Demo 11 complete!');
}

main().catch(console.error);
