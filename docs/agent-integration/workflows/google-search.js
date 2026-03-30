/**
 * google-search.js — Google search workflow
 *
 * Records a natural-looking Google search:
 *   Open Google → type query slowly → submit → hover first result → click
 *
 * Args:
 *   --query="stripe api documentation"  (default: "screenmuse github")
 *
 * Duration: ~20 seconds
 */

const name = 'google-search';

async function run(page, sm, args) {
  const query = args.query || 'screenmuse github';

  // Navigate to Google
  await sm.chapter('Open Google');
  await page.goto('https://www.google.com', { waitUntil: 'networkidle' });
  await sleep(1500);

  // Dismiss cookie consent if present
  try {
    const acceptBtn = page.locator('button:has-text("Accept all"), button:has-text("I agree")').first();
    if (await acceptBtn.isVisible({ timeout: 2000 })) {
      await acceptBtn.click();
      await sleep(500);
    }
  } catch {
    // No consent dialog
  }

  // Click search box
  await sm.chapter('Type search query');
  const searchBox = page.locator('textarea[name="q"], input[name="q"]').first();
  await searchBox.click();
  await sleep(500);

  // Type with human-like delays (50-150ms per character)
  for (const char of query) {
    await page.keyboard.type(char, { delay: 80 + Math.floor(Math.random() * 70) });
  }
  await sleep(800);

  // Submit
  await sm.chapter('View search results');
  await sm.highlight(); // zoom effect on submit
  await page.keyboard.press('Enter');
  await page.waitForLoadState('networkidle');
  await sleep(2000);

  // Hover first organic result
  const firstResult = page.locator('h3').first();
  await firstResult.scrollIntoViewIfNeeded();
  await firstResult.hover();
  await sleep(1500);

  // Click it
  await sm.chapter('Open first result');
  await sm.highlight();
  await firstResult.click();
  await page.waitForLoadState('domcontentloaded');
  await sleep(2000);

  // Scroll down a bit
  await page.mouse.wheel(0, 300);
  await sleep(1500);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

module.exports = { name, run };
