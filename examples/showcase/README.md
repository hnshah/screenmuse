# ScreenMuse Showcase Examples

**Production-quality demos showcasing real GitHub workflows.**

All demos are fully automated, reproducible, and validated with ScreenMuse v1.6.0's POST /validate endpoint.

---

## Demos

### 1. GitHub Search
**Script:** `scripts/01-github-search-robust.js`  
**Output:** `output/01-github-search.gif` (6.3MB, ~23s)

Search GitHub for "screenmuse", navigate to repository. Shows real-world search workflow.

**Features:**
- Search input
- Results navigation
- Repository landing

---

### 2. Repository Browse
**Script:** `scripts/02-repo-browse-robust.js`  
**Output:** `output/02-repo-browse.gif` (2.7MB, ~15s)

Navigate to ScreenMuse repository, scroll, click README. Shows repository exploration.

**Features:**
- File list navigation
- README viewing
- Content scrolling

---

### 3. Compare Repositories
**Script:** `scripts/03-compare-repos-robust.js`  
**Output:** `output/03-compare-repos.gif` (3.1MB, ~11s)

Compare ScreenMuse and Verdict repositories side-by-side. Shows multi-repo workflow.

**Features:**
- Multiple repositories
- Quick comparison
- Tab switching

---

### 4. Explore Code
**Script:** `scripts/04-explore-code-robust.js`  
**Output:** `output/04-explore-code.gif` (7.4MB, ~17s)

Navigate through screenmuse-playwright package folder structure, open source files. Shows code exploration workflow.

**Features:**
- Folder navigation
- File viewing
- Code scrolling

---

### 5. Issue Browsing
**Script:** `scripts/05-issue-browsing.js`  
**Output:** `output/05-issue-browsing.gif` (2.3MB, ~15s)

Browse GitHub Issues tab, view issue discussions. Shows issue tracking workflow.

**Features:**
- Issues tab navigation
- Issue viewing
- Discussion scrolling

---

### 6. Commit History
**Script:** `scripts/06-commit-history.js`  
**Output:** `output/06-commit-history.gif` (2.4MB, ~15s)

Browse commit history, view code diffs. Shows version control workflow.

**Features:**
- Commit list viewing
- Diff navigation
- Code change review

---

### 7. Package.json
**Script:** `scripts/07-package-json.js`  
**Output:** `output/07-package-json.gif` (2.6MB, ~12s)

Navigate to package.json file, view dependencies. Shows configuration file workflow.

**Features:**
- Direct file navigation
- JSON rendering
- Dependency viewing

---

## Running the Demos

### Prerequisites

1. **ScreenMuse** running on http://localhost:7823
2. **Node.js** with Playwright installed
3. **Chrome/Chromium** browser

### Installation

```bash
npm install playwright
```

### Run a Demo

```bash
cd examples/showcase
node scripts/01-github-search-robust.js
```

The demo will:
1. Launch browser
2. Record the workflow
3. Export GIF automatically
4. Save to `~/Movies/ScreenMuse/Exports/`

---

## Patterns Used

All demos use `00-robust-demo-base.js` which provides:

### Robust Window Detection

Handles multiple Chrome instances by:
1. Querying `/windows` endpoint
2. Finding newest Chrome window (empty/blank title)
3. Using explicit window PID

### Navigation Verification

Every navigation is verified:
```javascript
await link.evaluate(el => el.click());
await page.waitForURL(/expected-pattern/);
console.log('✅ Navigation succeeded:', page.url());
```

### Error Handling

Screenshots on failure:
```javascript
try {
  await navigation();
} catch (error) {
  await page.screenshot({ path: '/tmp/error.png' });
  throw error;
}
```

### Robust Selectors

Uses `.evaluate()` to bypass visibility checks:
```javascript
const link = page.locator('a[href*="README"]').first();
await link.evaluate(el => el.click());
```

---

## Quality Standards

All demos meet these criteria:

- ✅ **Reproducible** - Works on any machine
- ✅ **Validated** - Score ≥70% via POST /validate
- ✅ **Fast** - Under 30 seconds
- ✅ **Real workflows** - No toy examples
- ✅ **Error handling** - Screenshots on failure
- ✅ **Verified navigation** - Checks URLs/titles
- ✅ **Clean output** - Professional GIF quality

---

## Contributing

Want to add more demos? See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines!

**Good demo ideas:**
- NPM package exploration
- Stack Overflow search
- GitHub Actions workflows
- VS Code in browser (github.dev)
- Pull request reviews
- Repository insights

---

## Technical Details

### GIF Settings

All demos use these export settings:
- **FPS:** 10 (smooth, small file size)
- **Scale:** 600px width (optimal for docs)
- **Quality:** High (via ScreenMuse)

### Total Showcase

- **7 demos**
- **~110 seconds** total runtime
- **27.8MB** total GIF size
- **100% automated** (zero manual editing)

---

## Links

- **Live Showcase:** https://screenmuse-showcase.vera-space.pages.dev
- **ScreenMuse GitHub:** https://github.com/hnshah/screenmuse
- **screenmuse-playwright:** https://github.com/hnshah/screenmuse/tree/main/packages/screenmuse-playwright

---

*Created by Vera (AI Design Expert) after 4 hours of intensive ScreenMuse testing.*
