/**
 * simple-demo.js — Quick v0.5.0 showcase
 */

const { chromium } = require('playwright');
const { ScreenMuse, sleep } = require('./screenmuse');

const sm = new ScreenMuse();

async function main() {
  console.log('🎬 v0.5.0 Demo Starting...\n');

  // Launch browser FIRST
  const browser = await chromium.launch({
    headless: false,
    args: ['--window-size=1440,900', '--window-position=0,0']
  });
  
  const page = await browser.newPage({ viewport: { width: 1440, height: 830 } });

  // Wait for window to be ready
  await sleep(2000);

  try {
    // Start recording
    console.log('📊 Starting recording...');
    await sm.start({
      name: 'v0.5.0-showcase',
      window_title: 'Google Chrome',
      quality: 'high'
    });
    
    await sleep(1000);
    
    // Now position and clean desktop
    console.log('🪟 Positioning window & cleaning desktop...');
    await sm.hideOthers('Google Chrome');
    await sleep(1000);
    
    // Demo begins
    await sm.chapter('Welcome');
    await page.goto('https://vera-space.pages.dev');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    
    await sm.chapter('Test Report');
    await page.goto('https://vera-space.pages.dev/screenmuse/v0.4.0-report.html');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    await page.evaluate(() => window.scrollTo({ top: 500, behavior: 'smooth' }));
    await sleep(2000);
    
    await sm.chapter('Native APIs');
    await page.goto('https://vera-space.pages.dev/screenmuse/native-apis.html');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    await page.evaluate(() => window.scrollTo({ top: 800, behavior: 'smooth' }));
    await sleep(2000);
    
    await sm.chapter('Automation Research');
    await page.goto('https://vera-space.pages.dev/screenmuse/automation-research.html');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    await page.evaluate(() => window.scrollTo({ top: 600, behavior: 'smooth' }));
    await sleep(2000);
    
    // System state demo
    await sm.chapter('System State');
    const activeWindow = await sm.getActiveWindow();
    console.log(`  Active: ${activeWindow.app}`);
    await sm.note(`Recording: ${activeWindow.app} (${activeWindow.window_width}x${activeWindow.window_height})`);
    await sleep(1500);
    
    await sm.chapter('Design Research');
    await page.goto('https://vera-space.pages.dev/demo-options.html');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    await page.evaluate(() => window.scrollTo({ top: 800, behavior: 'smooth' }));
    await sleep(2000);
    
    await sm.chapter('Presentation');
    await page.goto('https://vera-space.pages.dev/screenmuse/presentation.html');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    await page.keyboard.press('ArrowDown');
    await sleep(2500);
    await page.keyboard.press('ArrowDown');
    await sleep(2500);
    await page.keyboard.press('ArrowDown');
    await sleep(2500);
    
    await sm.chapter('Finale');
    await page.goto('https://vera-space.pages.dev');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    
    // Stop recording
    console.log('\n⏹️  Stopping recording...');
    const result = await sm.stop();
    
    console.log('\n' + '═'.repeat(60));
    console.log('🎉 DEMO COMPLETE!');
    console.log('═'.repeat(60));
    console.log(`📹 Video: ${result.video_path}`);
    console.log(`⏱️  Duration: ${result.metadata.elapsed.toFixed(1)}s`);
    console.log(`📚 Chapters: ${result.metadata.chapters.length}`);
    console.log('');
    
    // Open video
    const { exec } = require('child_process');
    exec(`open -R "${result.video_path}"`);

  } catch (error) {
    console.error('\n❌ Error:', error.message);
    throw error;
  } finally {
    await browser.close();
  }
}

main().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});
