const { chromium } = require('playwright');
const { ScreenMuse, sleep } = require('./screenmuse');

const sm = new ScreenMuse();

async function main() {
  const browser = await chromium.launch({
    headless: false,
    args: ['--window-size=1440,900']
  });
  
  const page = await browser.newPage({ viewport: { width: 1440, height: 830 } });
  await sleep(2000);

  try {
    // Start recording (no window specified = full screen)
    await sm.start({ name: 'v0.5.0-demo', quality: 'high' });
    await sleep(1000);
    
    await sm.chapter('Vera Space');
    await page.goto('https://vera-space.pages.dev');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    
    await sm.chapter('Test Report');
    await page.goto('https://vera-space.pages.dev/screenmuse/v0.4.0-report.html');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    
    await sm.chapter('Native APIs');
    await page.goto('https://vera-space.pages.dev/screenmuse/native-apis.html');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    
    await sm.chapter('Presentation');
    await page.goto('https://vera-space.pages.dev/screenmuse/presentation.html');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    await page.keyboard.press('ArrowDown');
    await sleep(2000);
    await page.keyboard.press('ArrowDown');
    await sleep(2000);
    
    await sm.chapter('Complete');
    await sleep(2000);
    
    const result = await sm.stop();
    console.log(`\n✅ Video: ${result.video_path}`);
    
    require('child_process').exec(`open -R "${result.video_path}"`);
  } finally {
    await browser.close();
  }
}

main().catch(console.error);
