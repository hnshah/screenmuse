/**
 * Demo 6: Commit History
 * 
 * Browse commits and view diffs
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '06-commit-history', async (page) => {
    console.log('📍 Navigating to ScreenMuse repo...');
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(2500);
    
    // Click commits
    console.log('🔍 Looking for commits link...');
    try {
      let commitsLink = page.locator('a[href*="/commits"]').first();
      
      if (await commitsLink.count() === 0) {
        commitsLink = page.getByRole('link', { name: /commits/i }).first();
      }
      
      console.log('✅ Commits link found');
      console.log('👆 Clicking commits...');
      await commitsLink.evaluate(el => el.click());
      
      await page.waitForURL(/\/commits/, { timeout: 10000 });
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3000);
      
      console.log('✅ Commits page loaded:', page.url());
      
      // Scroll commits list
      console.log('📜 Scrolling commits...');
      await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
      await sleep(2000);
      
      // Click first commit
      console.log('🔍 Looking for a commit...');
      const commitLink = page.locator('.commit-title a, a.text-bold').first();
      
      if (await commitLink.count() > 0) {
        console.log('✅ Commit found');
        console.log('👆 Clicking commit...');
        await commitLink.evaluate(el => el.click());
        
        await sleep(3000);
        await page.waitForLoadState('networkidle');
        
        console.log('✅ Commit opened:', page.url());
        
        // Scroll through diff
        console.log('📜 Scrolling diff...');
        await page.evaluate(() => window.scrollBy({ top: 500, behavior: 'smooth' }));
        await sleep(2000);
        
        await page.evaluate(() => window.scrollBy({ top: 500, behavior: 'smooth' }));
        await sleep(2000);
        
        await page.evaluate(() => window.scrollBy({ top: 500, behavior: 'smooth' }));
        await sleep(1500);
      } else {
        console.log('⚠️  No commit found, showing list...');
        await page.evaluate(() => window.scrollBy({ top: 600, behavior: 'smooth' }));
        await sleep(3000);
      }
      
    } catch (error) {
      console.error('❌ Failed to browse commits:', error.message);
      await page.screenshot({ path: '/tmp/demo6-error.png' });
      throw error;
    }
    
    console.log('✅ Navigation complete');
  });
  
  console.log('🎉 Demo 6 complete!');
}

main().catch(console.error);
