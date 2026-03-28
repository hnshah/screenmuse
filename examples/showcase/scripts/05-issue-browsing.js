/**
 * Demo 5: Issue Browsing
 * 
 * Browse issues, comments, and discussions
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '05-issue-browsing', async (page) => {
    console.log('📍 Navigating to ScreenMuse repo...');
    await page.goto('https://github.com/hnshah/screenmuse');
    await page.waitForLoadState('networkidle');
    await page.waitForLoadState('domcontentloaded');
    await sleep(2500);
    
    // Click Issues tab
    console.log('🔍 Looking for Issues tab...');
    try {
      let issuesTab = page.locator('a[href*="/issues"]').first();
      
      if (await issuesTab.count() === 0) {
        issuesTab = page.getByRole('link', { name: /Issues/i }).first();
      }
      
      console.log('✅ Issues tab found');
      console.log('👆 Clicking Issues...');
      await issuesTab.evaluate(el => el.click());
      
      await page.waitForURL(/\/issues/, { timeout: 10000 });
      await page.waitForLoadState('networkidle');
      await page.waitForLoadState('domcontentloaded');
      await sleep(3000);
      
      console.log('✅ Issues page loaded:', page.url());
      
      // Scroll to show issues list
      console.log('📜 Scrolling issues list...');
      await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
      await sleep(2000);
      
      // Click first issue (or create sample navigation)
      console.log('🔍 Looking for an issue...');
      const issueLink = page.locator('[aria-label*="issue"] a, .js-navigation-item a').first();
      
      if (await issueLink.count() > 0) {
        console.log('✅ Issue found');
        console.log('👆 Clicking issue...');
        await issueLink.evaluate(el => el.click());
        
        await sleep(3000);
        await page.waitForLoadState('networkidle');
        
        console.log('✅ Issue opened:', page.url());
        
        // Scroll through issue content
        console.log('📜 Scrolling issue...');
        await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
        await sleep(2000);
        
        await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
        await sleep(2000);
      } else {
        console.log('⚠️  No issues found, scrolling more...');
        await page.evaluate(() => window.scrollBy({ top: 600, behavior: 'smooth' }));
        await sleep(3000);
      }
      
    } catch (error) {
      console.error('❌ Failed to browse issues:', error.message);
      await page.screenshot({ path: '/tmp/demo5-error.png' });
      throw error;
    }
    
    console.log('✅ Navigation complete');
  });
  
  console.log('🎉 Demo 5 complete!');
}

main().catch(console.error);
