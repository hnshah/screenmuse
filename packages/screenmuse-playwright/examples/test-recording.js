/**
 * QA test recording — record a test run so bugs have video proof.
 *
 * Integrates with any test framework. If the test fails, the video
 * is already there — no manual re-run needed.
 *
 * Run: node examples/test-recording.js
 */

const { chromium } = require('playwright');
const { ScreenMusePlaywright } = require('../');

const sm = new ScreenMusePlaywright();

/** Thin wrapper: records any async test, saves video on pass or fail. */
async function recordTest(name, testFn) {
  console.log(`\n▶ ${name}`);

  let result;
  let passed = false;

  try {
    result = await sm.recordBrowser({
      name: `test-${name.replace(/\s+/g, '-').toLowerCase()}`,
      quality: 'medium',
      browser: chromium,
      autoChapters: true,
      autoNotes: true,
    }, testFn);

    passed = true;
    console.log(`  ✅ PASSED — ${result.videoPath}`);
  } catch (err) {
    console.error(`  ❌ FAILED — ${err.message}`);
    // result may still be set if recording stopped before error
    if (result) console.log(`  📹 Video (for bug report): ${result.videoPath}`);
    return { passed: false, error: err, result };
  }

  return { passed, result };
}

// ── Example Tests ─────────────────────────────────────────────────────────────

async function main() {
  // Test 1: Homepage loads
  const t1 = await recordTest('homepage loads', async (page) => {
    await page.goto('https://example.com');
    await page.waitForLoadState('networkidle');
    const title = await page.title();
    if (!title) throw new Error('Page has no title');
  });

  // Test 2: Search works
  const t2 = await recordTest('search returns results', async (page) => {
    await page.goto('https://github.com/search?q=playwright');
    await page.waitForLoadState('networkidle');
    const results = page.locator('[data-testid="results-list"]');
    if (!await results.isVisible()) throw new Error('No search results visible');
  });

  // Summary
  const all = [t1, t2];
  const passed = all.filter(t => t.passed).length;
  console.log(`\n${passed}/${all.length} tests passed`);

  if (passed < all.length) {
    console.log('\nFailed test videos (attach to bug reports):');
    all.filter(t => !t.passed && t.result).forEach(t => {
      console.log(`  • ${t.result.videoPath}`);
    });
    process.exit(1);
  }
}

main().catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
