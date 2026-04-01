/**
 * Demo 9: OCR-Guided Navigation
 * 
 * Uses POST /frames + POST /ocr to verify content before proceeding
 * Showcases v1.6.0 frame extraction and OCR debug features
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function extractAndVerify(timeSeconds, expectedText) {
  console.log(`   🔍 Extracting frame at ${timeSeconds}s...`);
  
  // Extract frame
  const framesResp = await fetch('http://localhost:7823/frames', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: 'last',
      timestamps: [timeSeconds]
    })
  });
  
  const framesData = await framesResp.json();
  
  if (!framesData.frames?.[0]?.path) {
    console.log('   ❌ Frame extraction failed');
    return false;
  }
  
  console.log(`   ✅ Frame extracted: ${framesData.frames[0].path}`);
  
  // OCR with debug
  console.log(`   🔍 Running OCR (looking for "${expectedText}")...`);
  
  const ocrResp = await fetch('http://localhost:7823/ocr', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: framesData.frames[0].path,
      level: 'accurate',
      debug: true
    })
  });
  
  const ocrData = await ocrResp.json();
  
  if (ocrData.debug) {
    console.log(`   📊 Image: ${ocrData.debug.image_size}, upscaled: ${ocrData.debug.upscaled}`);
  }
  
  const found = ocrData.text?.toLowerCase().includes(expectedText.toLowerCase());
  console.log(`   ${found ? '✅' : '❌'} Text "${expectedText}": ${found ? 'FOUND' : 'NOT FOUND'}`);
  
  return found;
}

async function main() {
  console.log('🧪 OCR-GUIDED NAVIGATION DEMO');
  console.log('='.repeat(70));
  console.log('This demo uses OCR to verify content at each step.');
  console.log('');
  
  const result = await recordDemo(chromium, '09-ocr-guided', async (page) => {
    // Step 1: Navigate to GitHub
    console.log('📍 Step 1: Navigate to GitHub...');
    await page.goto('https://github.com');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    
    // Verify we're on GitHub
    await extractAndVerify(2, 'GitHub');
    
    // Step 2: Search for screenmuse
    console.log('\n📍 Step 2: Search for screenmuse...');
    const searchBox = page.locator('[name="q"]').first();
    await searchBox.fill('screenmuse');
    await sleep(1000);
    await searchBox.press('Enter');
    await sleep(3000);
    
    // Verify search results
    await extractAndVerify(5, 'screenmuse');
    
    // Step 3: Click repo
    console.log('\n📍 Step 3: Navigate to repository...');
    const repoLink = page.locator('a[href*="hnshah/screenmuse"]').first();
    if (await repoLink.count() > 0) {
      await repoLink.evaluate(el => el.click());
      await sleep(3000);
      
      // Verify we're on the repo
      await extractAndVerify(8, 'README');
    }
    
    console.log('\n✅ OCR-guided navigation complete!');
  });
  
  console.log('');
  console.log('='.repeat(70));
  console.log('🎉 Demo showcases v1.6.0 POST /frames + POST /ocr!');
}

main().catch(console.error);
