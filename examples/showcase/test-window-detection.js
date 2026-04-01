const { chromium } = require('playwright');

async function test() {
  console.log('1. Launching browser...');
  const browser = await chromium.launch({
    headless: false,
    args: ['--window-size=1440,900']
  });
  
  const browserPid = browser.process?.()?.pid ?? null;
  console.log(`2. Browser PID: ${browserPid}`);
  
  // Wait for window to register
  await new Promise(r => setTimeout(r, 2000));
  
  // Check if ScreenMuse can see it
  const windows = await fetch('http://localhost:7823/windows').then(r => r.json());
  console.log(`3. Total windows visible: ${windows.length}`);
  
  const chromiumWindow = windows.find(w => 
    w.pid === browserPid || 
    w.app?.toLowerCase().includes('chrom') ||
    w.title?.toLowerCase().includes('chrom')
  );
  
  if (chromiumWindow) {
    console.log('✅ Found Chromium window:');
    console.log(`   PID: ${chromiumWindow.pid}`);
    console.log(`   App: ${chromiumWindow.app}`);
    console.log(`   Title: ${chromiumWindow.title}`);
  } else {
    console.log('❌ Chromium window NOT FOUND');
    console.log('   Available windows:');
    windows.slice(0, 5).forEach(w => {
      console.log(`   - ${w.app} (PID: ${w.pid}): ${w.title?.substring(0, 50)}`);
    });
  }
  
  await browser.close();
}

test().catch(console.error);
