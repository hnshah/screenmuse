/**
 * Demo 3: Batch Demo Factory (Robust Version)
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

const DEMOS = [
  { name: '03-batch-example-com', url: 'https://example.com' },
  { name: '03-batch-example-org', url: 'https://example.org' },
  { name: '03-batch-example-net', url: 'https://example.net' }
];

async function main() {
  console.log('🎬 Demo 3: Batch Demo Factory');
  console.log('─'.repeat(50));
  console.log(`Creating ${DEMOS.length} demos...\n`);
  
  const results = [];
  
  for (let i = 0; i < DEMOS.length; i++) {
    const demo = DEMOS[i];
    console.log(`\n[${i + 1}/${DEMOS.length}] ${demo.url}`);
    
    const result = await recordDemo(chromium, demo.name, async (page) => {
      await page.goto(demo.url);
      await page.waitForLoadState('networkidle');
      await sleep(2000);
      
      await page.evaluate(() => window.scrollBy(0, 300));
      await sleep(1500);
      
      await page.evaluate(() => window.scrollBy(0, 300));
      await sleep(1000);
    });
    
    results.push(result);
    
    if (i < DEMOS.length - 1) {
      await sleep(2000);
    }
  }
  
  console.log('\n' + '─'.repeat(50));
  console.log('📊 Batch Summary:');
  console.log(`   Total demos: ${results.length}`);
  console.log('🎉 Demo 3 complete!');
}

main().catch(console.error);
