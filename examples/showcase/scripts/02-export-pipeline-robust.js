/**
 * Demo 2: Export Pipeline (Robust Version)
 */

const { chromium } = require('playwright');
const { recordDemo, sleep } = require('./00-robust-demo-base');

async function main() {
  const result = await recordDemo(chromium, '02-export-pipeline', async (page) => {
    await page.goto('https://example.com');
    await sleep(2000);
    
    await page.evaluate(() => window.scrollBy(0, 400));
    await sleep(2000);
    
    await page.goto('https://example.org');
    await sleep(2000);
    
    await page.evaluate(() => window.scrollBy(0, 400));
    await sleep(2000);
    
    await page.goto('https://example.net');
    await sleep(2000);
  });
  
  console.log('🎉 Demo 2 complete!');
}

main().catch(console.error);
