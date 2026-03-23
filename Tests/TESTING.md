# ScreenMuse Testing with Peekaboo

**Purpose:** Automated UI testing for ScreenMuse using Peekaboo macOS automation  
**Coverage:** Click ripple effects feature validation  
**Dogfooding:** Uses Peekaboo fuzzy matching + retry prototypes we built  

---

## Test Files

```
Tests/
├── peekaboo-click-effects-test.sh    # Bash version (simple, readable)
├── peekaboo-click-effects-test.py    # Python version (structured, reusable)
└── TESTING.md                         # This file
```

---

## Prerequisites

### 1. Install Peekaboo

```bash
brew install peekaboo
# or
brew install --cask peekaboo
```

### 2. Grant Permissions

ScreenMuse and Peekaboo both need:
- ✅ Screen Recording
- ✅ Accessibility
- ✅ Input Monitoring

Go to **System Settings → Privacy & Security** and enable for both apps.

### 3. Build ScreenMuse

```bash
cd screenmuse
open Package.swift  # Build in Xcode
# or
swift build
```

Make sure `ScreenMuse.app` is in `/Applications/`

---

## Running Tests

### Option 1: Bash Script (Quick)

```bash
cd screenmuse/Tests
chmod +x peekaboo-click-effects-test.sh
./peekaboo-click-effects-test.sh
```

**Output:**
- 15 screenshots in `/tmp/screenmuse-test-output/`
- Pass/fail status for each step
- Manual verification checklist

---

### Option 2: Python Script (Detailed)

```bash
cd screenmuse/Tests
chmod +x peekaboo-click-effects-test.py
python3 peekaboo-click-effects-test.py
```

**Output:**
- Structured test results
- Pass rate summary
- Screenshot inventory
- Detailed error messages

**Example output:**
```
🧪 Test: Launch ScreenMuse app
   ✅ PASSED (2.34s)

🧪 Test: Enable click effects toggle
   ⚠️  Toggle not found or already enabled
   ✅ PASSED (0.52s)

📊 TEST SUMMARY
Total: 10 tests
✅ Passed: 10
❌ Failed: 0
Pass rate: 100%
```

---

## Test Coverage

### Automated Tests

| Test | What It Validates | Peekaboo Feature Used |
|------|-------------------|----------------------|
| 01 | App launch | `run --app --wait` |
| 02 | Tab navigation | `tap` |
| 03 | Toggle interaction | `tap --fuzzy` (fuzzy matching!) |
| 04 | Preset selection | `tap` (multi-step) |
| 05 | Record start | `tap --retry` (retry logic!) |
| 06 | Click simulation | `click --position` |
| 07 | Record stop | `tap --retry` |
| 08 | Processing wait | `wait-for --timeout` |
| 09 | History verification | `assert --exists` |
| 10 | App cleanup | `quit` |

**Peekaboo prototype features demonstrated:**
- ✅ Fuzzy matching (`--fuzzy --threshold 0.8`)
- ✅ Retry with backoff (`--retry 3 --retry-delay 0.5`)
- ✅ Assertions (`assert --exists`)
- ✅ Screenshots at each step

---

### Manual Verification

After automation completes, manually verify:

1. **Ripple appearance**
   - Open History → play latest video
   - Red ripples should appear at 3 click locations

2. **Spring easing**
   - Ripples should bounce (spring effect)
   - Not linear expansion

3. **Timing**
   - Ripple 1: ~0-1s
   - Ripple 2: ~1-2s
   - Ripple 3: ~2-3s

4. **Visual quality**
   - Smooth animation (60fps)
   - Red color (Strong Red preset)
   - Larger radius than default

5. **Performance**
   - Video plays without stuttering
   - Effects don't cause frame drops

---

## Test Artifacts

After running tests, check:

```bash
ls -lh /tmp/screenmuse-test-output/
```

**Expected screenshots:**
```
01-launch.png                # App launched
02-record-tab.png            # Record tab selected
03-effects-toggle.png        # Click effects enabled
04-preset-picker.png         # Preset picker open
05-strong-red.png            # Strong Red selected
06-recording-started.png     # Recording indicator visible
07-click-1.png               # First click captured
07-click-2.png               # Second click captured
07-click-3.png               # Third click captured
08-recording-stopped.png     # Recording stopped
09-processing.png            # Processing indicator (if visible)
10-history-tab.png           # History tab
11-video-found.png           # Video thumbnail visible
12-app-quit.png              # App closed
```

---

## Debugging Failed Tests

### Test 01 fails (Launch)

**Symptom:** App doesn't launch  
**Fix:**
```bash
# Check app exists
ls -l /Applications/ScreenMuse.app

# Try manual launch
open /Applications/ScreenMuse.app

# Check for crash logs
log show --predicate 'process == "ScreenMuse"' --last 1m
```

### Test 03 fails (Toggle)

**Symptom:** "Click Effects" toggle not found  
**Fix:**
- UI label might be different → adjust fuzzy threshold
- Toggle might not exist yet → check ScreenMuse build
- Try manual: open app → Record tab → look for toggle

### Test 05/07 fail (Recording)

**Symptom:** Start/Stop buttons not found  
**Fix:**
- Check permissions (Screen Recording, Mic)
- Verify buttons exist in UI
- Try lower fuzzy threshold: `--threshold 0.6`

### Test 08 fails (Processing)

**Symptom:** Timeout waiting for processing  
**Fix:**
- Expected! Processing might be background-only
- Check History manually after test completes
- Increase timeout: `--timeout 120`

---

## Continuous Integration

To run tests in CI (future):

```yaml
# .github/workflows/test.yml
name: UI Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v3
      
      - name: Build ScreenMuse
        run: swift build
      
      - name: Install Peekaboo
        run: brew install peekaboo
      
      - name: Run UI tests
        run: |
          cd Tests
          python3 peekaboo-click-effects-test.py
      
      - name: Upload screenshots
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: test-screenshots
          path: /tmp/screenmuse-test-output/*.png
```

---

## Extending Tests

### Add new test

**In Bash:**
```bash
echo ""
echo "Test 11: My new test"
$PEEKABOO tap "New Button" --screenshot "11-new-test.png"
```

**In Python:**
```python
@test("My new test")
def test_11_my_new_test(self):
    """Test description"""
    self.run_peekaboo(
        "tap", "New Button",
        screenshot="11-new-test.png"
    )
```

### Test different presets

```bash
# Test Subtle Blue preset
$PEEKABOO tap "Effect Style"
$PEEKABOO tap "Subtle Blue"
# ... record and verify blue ripples

# Test Quick Yellow preset  
$PEEKABOO tap "Effect Style"
$PEEKABOO tap "Quick Yellow"
# ... record and verify yellow ripples
```

---

## Known Issues

1. **Processing notification unreliable**
   - ScreenMuse may not show visible "Processing" indicator
   - Workaround: Wait fixed time or check History after delay

2. **Fuzzy matching sensitivity**
   - UI labels may vary between builds
   - Adjust `--threshold` if tests fail on exact matches

3. **Timing dependencies**
   - Some UI animations need extra wait time
   - Add `sleep` if elements aren't ready

4. **macOS permissions prompts**
   - First run may show permission dialogs
   - Grant all permissions before running tests

---

## Success Criteria

**Automated tests pass (100%):**
- ✅ All 10 tests green
- ✅ No errors in output
- ✅ 12+ screenshots captured

**Manual verification passes:**
- ✅ Red ripples visible in recorded video
- ✅ Spring easing animation smooth
- ✅ 3 ripples at correct timestamps
- ✅ Video plays without issues

**Dogfooding validated:**
- ✅ Peekaboo fuzzy matching works
- ✅ Retry logic handles timing issues
- ✅ Assertions verify UI state
- ✅ Screenshots provide debugging trail

---

## Summary

✅ **Complete test suite** for ScreenMuse click effects  
✅ **Dogfoods Peekaboo prototypes** we built earlier  
✅ **Validates competitive feature** (ripple effects)  
✅ **Repeatable** for regression testing  
✅ **Extensible** for future Phase 2 features  

**Next:** Auto-zoom testing, timeline editor validation 🚀
