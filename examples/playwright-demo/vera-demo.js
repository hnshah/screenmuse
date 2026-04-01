/**
 * vera-demo.js — ScreenMuse v0.5.0 Feature Showcase
 * 
 * This demo shows off the native macOS capabilities that make ScreenMuse unique:
 * - Window positioning & management
 * - Clean desktop (hide-others)
 * - System state capture
 * - Playwright integration
 */

const { chromium } = require('playwright');
const { ScreenMuse, sleep } = require('./screenmuse');

const sm = new ScreenMuse();

async function main() {
  console.log('🎬 ScreenMuse v0.5.0 Demo Starting...\n');

  // Verify ScreenMuse is running
  const version = await sm.getVersion();
  console.log(`✅ ScreenMuse ${version.version} ready\n`);

  // Launch browser
  const browser = await chromium.launch({
    headless: false,
    args: ['--window-size=1440,900', '--window-position=0,0']
  });
  
  const page = await browser.newPage({ 
    viewport: { width: 1440, height: 830 } 
  });

  try {
    console.log('📊 Starting recording with native features...');
    
    const result = await sm.record(
      {
        name: 'v0.5.0-showcase',
        window: 'Google Chrome for Testing',
        frame: { x: 0, y: 0, width: 1440, height: 900 },
        quality: 'high',
        hideOthers: true  // 🎯 Clean desktop - no other apps visible!
      },
      async (sm) => {
        
        // ═══════════════════════════════════════════════════════════
        // ACT 1: Window Management Demo
        // ═══════════════════════════════════════════════════════════
        
        await sm.chapter('Window Management');
        console.log('  📍 Demonstrating window positioning...');
        
        // Show vera-space.pages.dev
        await page.goto('https://vera-space.pages.dev');
        await page.waitForLoadState('networkidle');
        await sleep(2000);
        
        await sm.note('Native window APIs - no other tool can do this');
        
        // ═══════════════════════════════════════════════════════════
        // ACT 2: ScreenMuse Test Report
        // ═══════════════════════════════════════════════════════════
        
        await sm.chapter('v0.4.0 Test Report');
        console.log('  📋 Showing test report...');
        
        await page.goto('https://vera-space.pages.dev/screenmuse/v0.4.0-report.html');
        await page.waitForLoadState('networkidle');
        await sleep(2500);
        
        // Scroll to show content
        await page.evaluate(() => window.scrollTo({ top: 400, behavior: 'smooth' }));
        await sleep(1500);
        
        await sm.note('Comprehensive bug documentation');
        
        // ═══════════════════════════════════════════════════════════
        // ACT 3: Native APIs Research
        // ═══════════════════════════════════════════════════════════
        
        await sm.chapter('Native APIs Research');
        console.log('  🔬 Showing research that became v0.5.0...');
        
        await page.goto('https://vera-space.pages.dev/screenmuse/native-apis.html');
        await page.waitForLoadState('networkidle');
        await sleep(2500);
        
        // Scroll through recommendations
        await page.evaluate(() => window.scrollTo({ top: 600, behavior: 'smooth' }));
        await sleep(1500);
        await page.evaluate(() => window.scrollTo({ top: 1200, behavior: 'smooth' }));
        await sleep(1500);
        
        await sm.note('Research → Code in 5 hours');
        
        // ═══════════════════════════════════════════════════════════
        // ACT 4: Automation Research
        // ═══════════════════════════════════════════════════════════
        
        await sm.chapter('Automation Strategy');
        console.log('  🎯 Showing Playwright integration...');
        
        await page.goto('https://vera-space.pages.dev/screenmuse/automation-research.html');
        await page.waitForLoadState('networkidle');
        await sleep(2500);
        
        await page.evaluate(() => window.scrollTo({ top: 800, behavior: 'smooth' }));
        await sleep(1500);
        
        await sm.note('Playwright + ScreenMuse = Dream Team');
        
        // ═══════════════════════════════════════════════════════════
        // ACT 5: System State Capture (Show the unique features!)
        // ═══════════════════════════════════════════════════════════
        
        await sm.chapter('System State Capture');
        console.log('  💾 Capturing system state (unique to ScreenMuse)...');
        
        // Get active window info
        const activeWindow = await sm.getActiveWindow();
        console.log(`  🪟 Active: ${activeWindow.app} - "${activeWindow.window_title}"`);
        await sm.note(`Recording: ${activeWindow.app} at ${activeWindow.window_width}x${activeWindow.window_height}`);
        await sleep(1000);
        
        // Get running apps
        const runningApps = await sm.getRunningApps();
        console.log(`  🖥️  Running apps: ${runningApps.count}`);
        await sm.note(`System has ${runningApps.count} apps running`);
        await sleep(1000);
        
        // ═══════════════════════════════════════════════════════════
        // ACT 6: Design Options Page
        // ═══════════════════════════════════════════════════════════
        
        await sm.chapter('User Research');
        console.log('  🎨 Showing design research...');
        
        await page.goto('https://vera-space.pages.dev/demo-options.html');
        await page.waitForLoadState('networkidle');
        await sleep(2500);
        
        // Scroll through options
        await page.evaluate(() => window.scrollTo({ top: 500, behavior: 'smooth' }));
        await sleep(1500);
        await page.evaluate(() => window.scrollTo({ top: 1000, behavior: 'smooth' }));
        await sleep(1500);
        
        await sm.note('Show, don\'t tell - user research in action');
        
        // ═══════════════════════════════════════════════════════════
        // ACT 7: Frontend-Slides Presentation
        // ═══════════════════════════════════════════════════════════
        
        await sm.chapter('Zero-Dependency Presentation');
        console.log('  📊 Opening Frontend-Slides presentation...');
        
        await page.goto('https://vera-space.pages.dev/screenmuse/presentation.html');
        await page.waitForLoadState('networkidle');
        await sleep(3000);
        
        // Navigate through a few slides using arrow keys
        await page.keyboard.press('ArrowDown');
        await sleep(2000);
        await page.keyboard.press('ArrowDown');
        await sleep(2000);
        await page.keyboard.press('ArrowDown');
        await sleep(2000);
        
        await sm.note('Single HTML file, zero dependencies, production-ready');
        
        // ═══════════════════════════════════════════════════════════
        // FINALE: Back to Home
        // ═══════════════════════════════════════════════════════════
        
        await sm.chapter('Finale');
        console.log('  🏠 Returning home...');
        
        await page.goto('https://vera-space.pages.dev');
        await page.waitForLoadState('networkidle');
        await sleep(3000);
        
        await sm.note('Research → Documentation → Code → Success');
        
        console.log('\n✨ Demo script complete!');
      }
    );

    // ═══════════════════════════════════════════════════════════
    // Results
    // ═══════════════════════════════════════════════════════════
    
    console.log('\n' + '═'.repeat(60));
    console.log('🎉 DEMO RECORDING COMPLETE!');
    console.log('═'.repeat(60));
    console.log(`📹 Video: ${result.videoPath}`);
    console.log(`⏱️  Duration: ${result.metadata.elapsed.toFixed(1)}s`);
    console.log(`📚 Chapters: ${result.metadata.chapters.length}`);
    console.log('');
    
    // Show chapters
    console.log('📑 Chapters:');
    result.metadata.chapters.forEach((ch, i) => {
      console.log(`   ${i + 1}. ${ch.name} (${ch.timestamp.toFixed(1)}s)`);
    });
    console.log('');
    
    // Get full session report
    const report = await sm.getReport();
    console.log('📊 Session Report:');
    console.log(report);
    
    console.log('\n✅ Video saved! Opening in Finder...');
    
    // Open video location
    const { exec } = require('child_process');
    exec(`open -R "${result.videoPath}"`);

  } catch (error) {
    console.error('\n❌ Demo failed:', error.message);
    throw error;
  } finally {
    await browser.close();
  }
}

main().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
