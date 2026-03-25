/**
 * Robust Demo Recording Base
 * 
 * Fixes window detection on macOS where browser.process().pid is null
 */

const { ScreenMusePlaywright } = require('../../../packages/screenmuse-playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Record a browser demo with robust window detection
 */
async function recordDemo(browser, name, script) {
  console.log(`🎬 Recording: ${name}`);
  console.log('─'.repeat(50));
  
  // Launch browser first
  const browserInstance = await browser.launch({
    headless: false,
    args: ['--window-size=1440,900']
  });
  
  // Create page to get a window title
  const context = await browserInstance.newContext();
  const page = await context.newPage();
  await page.goto('about:blank');
  
  // Wait for window to be registered
  await sleep(2000);
  
  // Find the Chromium window by title/app
  const windowsResp = await fetch('http://localhost:7823/windows');
  const { windows } = await windowsResp.json();
  
  // Get the browser PID if possible
  const browserPid = browserInstance.process?.()?.pid;
  
  // Find matching Chrome window - prefer by PID if available
  let chromiumWindow;
  
  if (browserPid) {
    chromiumWindow = windows.find(w => w.pid === browserPid);
    if (chromiumWindow) {
      console.log(`✅ Found window by PID: ${browserPid}`);
    }
  }
  
  // Fallback: find by title containing "about:blank" or empty (new browser)
  if (!chromiumWindow) {
    const newBrowserWindows = windows.filter(w => 
      (w.app?.toLowerCase().includes('chrom') || 
       w.title?.toLowerCase().includes('chrom') ||
       w.bundle_id?.includes('chromium')) &&
      (w.title?.includes('about:blank') || 
       w.title === '' ||
       w.title?.length < 10)
    );
    
    // Take the most recently created (last in list)
    chromiumWindow = newBrowserWindows[newBrowserWindows.length - 1];
    
    if (chromiumWindow) {
      console.log(`✅ Found new browser window by empty/blank title`);
    }
  }
  
  // Last resort: any Chrome window
  if (!chromiumWindow) {
    chromiumWindow = windows.find(w => 
      w.app?.toLowerCase().includes('chrom') ||
      w.title?.toLowerCase().includes('chrom') ||
      w.bundle_id?.includes('chromium')
    );
  }
  
  if (!chromiumWindow) {
    console.error('❌ Could not find Chromium window!');
    console.error('Available windows:', windows.map(w => w.app).join(', '));
    await browserInstance.close();
    throw new Error('Chromium window not found');
  }
  
  console.log(`✅ Found window: ${chromiumWindow.app} (PID: ${chromiumWindow.pid})`);
  
  // Start recording with explicit window PID
  console.log('🎬 Starting recording...');
  const startResp = await fetch('http://localhost:7823/start', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      name,
      quality: 'high',
      window_pid: chromiumWindow.pid
    })
  });
  
  if (!startResp.ok) {
    const error = await startResp.text();
    await browserInstance.close();
    throw new Error(`Failed to start recording: ${error}`);
  }
  
  const startData = await startResp.json();
  console.log(`✅ Recording started (session: ${startData.session_id})`);
  
  // Run the actual demo script
  try {
    await sleep(1000); // Let recording stabilize
    await page.bringToFront();
    await sleep(500);
    
    await script(page, context, browserInstance);
    
    await sleep(1000); // Final pause
  } catch (error) {
    console.error('❌ Script error:', error.message);
    throw error;
  } finally {
    // Stop recording
    console.log('⏹️  Stopping recording...');
    const stopResp = await fetch('http://localhost:7823/stop', { method: 'POST' });
    const stopData = await stopResp.json();
    
    console.log(`✅ Recording saved: ${stopData.path}`);
    console.log(`   Duration: ${stopData.elapsed?.toFixed(1)}s`);
    
    // Close browser
    await browserInstance.close();
    
    // Export GIF
    console.log('\n📤 Exporting GIF...');
    const gifResp = await fetch('http://localhost:7823/export', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: 'last',
        format: 'gif',
        fps: 10,
        scale: 600
      })
    });
    
    const gifData = await gifResp.json();
    console.log(`✅ GIF: ${gifData.path}`);
    console.log(`   Size: ${(gifData.size / 1024 / 1024).toFixed(2)}MB\n`);
    
    return {
      video: stopData.path,
      gif: gifData.path,
      duration: stopData.elapsed
    };
  }
}

module.exports = { recordDemo, sleep };
