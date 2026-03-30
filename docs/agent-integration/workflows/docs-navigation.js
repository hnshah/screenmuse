/**
 * docs-navigation.js — Documentation site navigation workflow
 *
 * Records natural browsing of a documentation site:
 *   Load home → open sidebar → expand section → read article → scroll
 *
 * Args:
 *   --url="https://nextjs.org/docs"  (default)
 *
 * Duration: ~25 seconds
 */

const name = 'docs-navigation';

async function run(page, sm, args) {
  const url = args.url || 'https://nextjs.org/docs';

  // Load docs homepage
  await sm.chapter('Open documentation');
  await page.goto(url, { waitUntil: 'networkidle' });
  await sleep(2000);

  // Scroll down to show content
  await sm.chapter('Browse docs');
  await page.mouse.wheel(0, 200);
  await sleep(1000);

  // Find and hover a sidebar link
  const sidebarLink = page
    .locator('nav a, aside a, [role="navigation"] a')
    .filter({ hasText: /getting started|introduction|quick start|overview/i })
    .first();

  if (await sidebarLink.isVisible({ timeout: 3000 })) {
    await sidebarLink.hover();
    await sleep(800);
    await sm.highlight();
    await sidebarLink.click();
    await page.waitForLoadState('domcontentloaded');
    await sleep(2000);
  }

  // Scroll through the article
  await sm.chapter('Read article');
  for (let i = 0; i < 3; i++) {
    await page.mouse.wheel(0, 400);
    await sleep(800);
  }

  // Find a code block and hover it
  const codeBlock = page.locator('pre code, .code-block').first();
  if (await codeBlock.isVisible({ timeout: 2000 })) {
    await codeBlock.scrollIntoViewIfNeeded();
    await codeBlock.hover();
    await sleep(1500);
  }

  // Scroll back to top
  await page.keyboard.press('Home');
  await sleep(1000);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

module.exports = { name, run };
