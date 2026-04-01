/**
 * Demo 8: Self-Validating Demo
 * 
 * Showcases v1.6.0 validation: record → validate → auto-retry if failed
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function validateRecording(path) {
  const resp = await fetch('http://localhost:7823/validate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: path || 'last',
      checks: [
        { type: 'duration', min: 8, max: 25 },
        { type: 'frame_count', min: 80 },
        { type: 'no_black_frames' }
      ]
    })
  });
  
  return await resp.json();
}

async function recordAttempt(attemptNum) {
  console.log(`\n🎬 Recording attempt #${attemptNum}...`);
  
  const result = await recordDemo(chromium, `08-self-validating-attempt-${attemptNum}`, async (page) => {
    console.log('📍 Navigating to screenmuse-playwright package...');
    await page.goto('https://github.com/hnshah/screenmuse/tree/main/packages/screenmuse-playwright');
    await page.waitForLoadState('networkidle');
    await sleep(3000);
    
    console.log('📜 Scrolling through package...');
    await page.evaluate(() => window.scrollBy({ top: 400, behavior: 'smooth' }));
    await sleep(2000);
    
    // Click README
    console.log('🔍 Looking for README...');
    const readmeLink = page.locator('a[href*="README"]').first();
    if (await readmeLink.count() > 0) {
      console.log('👆 Clicking README...');
      await readmeLink.evaluate(el => el.click());
      await sleep(3000);
      
      console.log('📜 Scrolling README...');
      await page.evaluate(() => window.scrollBy({ top: 500, behavior: 'smooth' }));
      await sleep(2000);
    }
    
    console.log('✅ Recording complete');
  });
  
  return result;
}

async function main() {
  const MAX_ATTEMPTS = 3;
  let attempt = 1;
  let validation = null;
  
  console.log('🧪 SELF-VALIDATING DEMO');
  console.log('='.repeat(70));
  console.log('This demo records itself and validates quality automatically.');
  console.log('If validation fails, it retries up to 3 times.');
  console.log('');
  
  while (attempt <= MAX_ATTEMPTS) {
    // Record
    const recording = await recordAttempt(attempt);
    
    // Validate
    console.log(`\n🔍 Validating attempt #${attempt}...`);
    validation = await validateRecording();
    
    console.log(`   Score: ${validation.score || 0}/${validation.max_score || 100}`);
    console.log(`   Valid: ${validation.valid ? '✅ YES' : '❌ NO'}`);
    
    if (validation.checks) {
      console.log('   Checks:');
      validation.checks.forEach(check => {
        console.log(`      ${check.pass ? '✅' : '❌'} ${check.type}`);
      });
    }
    
    if (validation.valid) {
      console.log('\n✅ Validation PASSED!');
      console.log('📹 Final demo: 08-self-validating-attempt-' + attempt);
      break;
    } else {
      console.log('\n❌ Validation FAILED. Issues:');
      if (validation.issues) {
        validation.issues.forEach(issue => console.log(`   - ${issue}`));
      }
      
      if (attempt < MAX_ATTEMPTS) {
        console.log(`\n🔄 Retrying... (${attempt + 1}/${MAX_ATTEMPTS})`);
      } else {
        console.log('\n❌ Max attempts reached.');
      }
    }
    
    attempt++;
  }
  
  console.log('');
  console.log('='.repeat(70));
  console.log('🎉 Self-validating demo complete!');
  console.log(`   Total attempts: ${attempt}`);
  console.log(`   Final score: ${validation?.score || 0}/${validation?.max_score || 100}`);
}

main().catch(console.error);
