/**
 * product-demo.js — Generic product demo workflow
 *
 * Records a polished product walkthrough:
 *   Land on page → scroll hero → click CTA → explore features → scroll to pricing
 *
 * Args:
 *   --url="https://your-product.com"  (required)
 *
 * Duration: ~30 seconds
 */

const name = 'product-demo';

async function run(page, sm, args) {
  if (!args.url) {
    throw new Error('product-demo requires --url="https://your-product.com"');
  }

  // Land on product page
  await sm.chapter('Product homepage');
  await page.goto(args.url, { waitUntil: 'networkidle' });
  await sleep(2000);

  // Slow scroll through hero
  await sm.chapter('Hero section');
  await page.mouse.wheel(0, 150);
  await sleep(700);
  await page.mouse.wheel(0, 150);
  await sleep(1000);

  // Find and hover primary CTA
  const cta = page
    .locator('a, button')
    .filter({ hasText: /get started|sign up|try free|start free|demo|learn more/i })
    .first();

  if (await cta.isVisible({ timeout: 3000 })) {
    await sm.chapter('Call to action');
    await cta.scrollIntoViewIfNeeded();
    await cta.hover();
    await sleep(1500);
  }

  // Scroll through features
  await sm.chapter('Features');
  for (let i = 0; i < 4; i++) {
    await page.mouse.wheel(0, 350);
    await sleep(700 + Math.floor(Math.random() * 400));
  }

  // Find pricing section
  await sm.chapter('Pricing');
  const pricingSection = page
    .locator('section, div')
    .filter({ hasText: /pricing|plans|choose a plan/i })
    .first();

  if (await pricingSection.isVisible({ timeout: 2000 })) {
    await pricingSection.scrollIntoViewIfNeeded();
    await sleep(1500);
    await sm.highlight();
  }

  // Final scroll to footer
  await page.mouse.wheel(0, 300);
  await sleep(1000);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

module.exports = { name, run };
