# Contributing to ScreenMuse Examples

Thank you for your interest in contributing demos and examples to ScreenMuse!

---

## What We're Looking For

**High-quality, real-world demos** that showcase ScreenMuse features and help developers understand how to use it.

### Good Demos

✅ **Real workflows** - GitHub PRs, NPM packages, Stack Overflow, VS Code  
✅ **Feature showcases** - Validation, OCR, frames, auto-chapters  
✅ **Autonomous patterns** - Self-validating, retry loops, quality gates  
✅ **Production-ready** - Clean code, error handling, documentation  
✅ **Fast** - Under 30 seconds (attention span)  
✅ **Validated** - Pass POST /validate with ≥70% score  

### Avoid

❌ Toy examples (example.com, lorem ipsum)  
❌ Manual recordings (must be scripted)  
❌ Flaky selectors (use robust patterns)  
❌ Silent failures (verify navigation worked)  
❌ Long demos (>60 seconds)  

---

## Directory Structure

```
examples/
├── showcase/              # Simple, beginner-friendly demos
│   ├── scripts/
│   │   ├── 00-robust-demo-base.js   # Shared utilities
│   │   ├── 01-github-search.js
│   │   └── ...
│   └── README.md
│
├── advanced/              # Complex workflows, v1.6.0 features
│   ├── scripts/
│   │   ├── 08-self-validating.js
│   │   ├── 09-ocr-guided.js
│   │   └── ...
│   └── README.md
│
└── CONTRIBUTING.md        # This file
```

---

## Contribution Checklist

Before submitting a PR, ensure your demo meets these criteria:

### 1. Code Quality ✅

- [ ] Follows 00-robust-demo-base.js pattern
- [ ] Uses `.evaluate()` for clicks (bypasses visibility checks)
- [ ] Has error handling and screenshots on failure
- [ ] Includes logging for debugging
- [ ] No hardcoded waits (use `waitForLoadState`, `waitForURL`)
- [ ] Comments explain what's happening

### 2. Robustness ✅

- [ ] Works on any machine (no hardcoded paths, user-specific data)
- [ ] Handles multiple Chrome instances (PID detection)
- [ ] Verifies navigation worked (check URLs, titles)
- [ ] Graceful degradation (if element missing, show fallback)
- [ ] Can run multiple times without conflicts

### 3. Quality ✅

- [ ] Passes POST /validate with score ≥70%
- [ ] Duration: 10-30 seconds (ideal range)
- [ ] GIF size: <10MB
- [ ] No black frames
- [ ] Clear, smooth scrolling
- [ ] Visible UI elements (not cut off)

### 4. Documentation ✅

- [ ] README.md entry with description
- [ ] What the demo shows
- [ ] What ScreenMuse features it uses
- [ ] Any setup required (e.g., GitHub login)

### 5. Validation Report ✅

Run validation and include results:

```bash
node scripts/validate-demo.js your-demo.js
```

Include:
- Score (0-100)
- All checks (passed/failed)
- Any issues found
- How you fixed them

---

## Coding Patterns

### Robust Window Detection

```javascript
// Use 00-robust-demo-base.js
const { recordDemo, sleep } = require('./00-robust-demo-base');

const result = await recordDemo(chromium, 'demo-name', async (page) => {
  // Your demo code
});
```

This handles:
- Finding correct Chrome window
- Explicit window PID
- Auto-chapters
- Clean session management

### Robust Selectors

```javascript
// ❌ Fragile
await page.click('a[title="README.md"]');

// ✅ Robust (evaluate bypasses visibility)
const link = page.locator('a[href*="README"]').first();
await link.evaluate(el => el.click());
```

### Navigation Verification

```javascript
// ❌ Assume it worked
await link.click();
await sleep(2000);

// ✅ Verify it worked
await link.evaluate(el => el.click());
await page.waitForURL(/README/, { timeout: 10000 });
console.log('✅ README loaded:', page.url());
```

### Error Handling

```javascript
try {
  // Attempt navigation
  await element.click();
} catch (error) {
  console.error('❌ Failed:', error.message);
  await page.screenshot({ path: '/tmp/error.png' });
  throw error; // Don't silently continue!
}
```

---

## v1.6.0 Feature Examples

### Validation

```javascript
const validation = await fetch('http://localhost:7823/validate', {
  method: 'POST',
  body: JSON.stringify({
    source: 'last',
    checks: [
      { type: 'duration', min: 10, max: 30 },
      { type: 'frame_count', min: 100 },
      { type: 'no_black_frames' }
    ]
  })
});

const result = await validation.json();
if (!result.valid) {
  console.log('Validation failed, retrying...');
  // Re-record logic
}
```

### Frame Extraction

```javascript
const frames = await fetch('http://localhost:7823/frames', {
  method: 'POST',
  body: JSON.stringify({
    source: 'last',
    timestamps: [1.0, 2.5, 5.0]
  })
});

const { frames: extracted } = await frames.json();
// frames[0].path = "/tmp/frame-1s.png"
```

### OCR with Debug

```javascript
const ocr = await fetch('http://localhost:7823/ocr', {
  method: 'POST',
  body: JSON.stringify({
    source: framePath,
    level: 'accurate',
    debug: true
  })
});

const result = await ocr.json();
console.log('Text found:', result.text);
console.log('Image size:', result.debug.image_size);
console.log('Upscaled:', result.debug.upscaled);
```

---

## Testing Your Demo

### 1. Record Locally

```bash
cd examples/showcase
node scripts/your-demo.js
```

### 2. Validate

```bash
# Create validation script
node -e '
const validate = async () => {
  const resp = await fetch("http://localhost:7823/validate", {
    method: "POST",
    body: JSON.stringify({
      source: "last",
      checks: [
        { type: "duration", min: 10, max: 30 },
        { type: "frame_count", min: 80 },
        { type: "no_black_frames" }
      ]
    })
  });
  const data = await resp.json();
  console.log("Score:", data.score, "/", data.max_score);
  console.log("Valid:", data.valid);
  data.checks?.forEach(c => console.log("  ", c.pass ? "✅" : "❌", c.type));
};
validate();
'
```

### 3. Check Output

- Open the GIF
- Watch it through
- Verify:
  - Smooth scrolling
  - Clear UI elements
  - No black frames
  - Proper timing

### 4. Run Multiple Times

Ensure it works consistently:

```bash
for i in {1..3}; do
  echo "Run $i"
  node scripts/your-demo.js
  sleep 5
done
```

---

## Submission Process

### 1. Fork the Repo

```bash
git clone https://github.com/hnshah/screenmuse.git
cd screenmuse
git checkout -b feature/new-demo
```

### 2. Add Your Demo

```bash
# Add script
cp your-demo.js examples/showcase/scripts/XX-your-demo.js

# Update README
# Add entry to examples/showcase/README.md
```

### 3. Test & Validate

```bash
# Record
node examples/showcase/scripts/XX-your-demo.js

# Validate
# ... validation steps above ...

# Commit GIF
git add ~/Movies/ScreenMuse/Exports/your-demo.gif
```

### 4. Create PR

```bash
git add examples/
git commit -m "feat: add [Your Demo Name] example"
git push origin feature/new-demo
```

Then open PR on GitHub with:
- Description of what the demo shows
- Validation score
- Screenshot or GIF preview
- Any special setup needed

---

## Review Criteria

We'll review PRs for:

1. **Quality** - Does it pass validation? Is the code clean?
2. **Usefulness** - Does it showcase real workflows or features?
3. **Robustness** - Does it work reliably?
4. **Documentation** - Is it clear what it does?
5. **Uniqueness** - Does it add something new?

---

## Questions?

- Open an issue: https://github.com/hnshah/screenmuse/issues
- Join Discord: [link]
- Tag @hnshah in PR comments

---

**Thank you for contributing!** 🎬✨

Every demo helps developers understand ScreenMuse better and discover new use cases we haven't thought of yet.

*This guide was created autonomously by Vera (AI design expert) based on 3+ hours of intensive ScreenMuse testing.*
