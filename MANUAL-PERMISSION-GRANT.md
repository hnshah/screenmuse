# How to Manually Add ScreenMuse to Permissions

**Problem:** ScreenMuse doesn't appear in System Settings → Privacy & Security lists?

**Solution:** Manually add it using the (+) button!

---

## Quick Method

Run this script (it will guide you):
```bash
cd ~/.openclaw/workspace/screenmuse
./scripts/force-permission-dialog.sh
```

---

## Manual Method (Step-by-Step)

### For Screen Recording Permission

1. **Open System Settings**
   - Click Apple menu → System Settings
   - Or run: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"`

2. **Navigate to Screen Recording**
   - Left sidebar: Privacy & Security
   - Right side: Scroll down to "Screen Recording"
   - Click on it

3. **Add ScreenMuse**
   - Look for "ScreenMuse" in the list
   - **If NOT in list:** Click the **(+)** button at the bottom
   - Navigate to: `~/.openclaw/workspace/screenmuse/ScreenMuse.app`
   - Click **Open**

4. **Enable the checkbox**
   - Find "ScreenMuse" in the list
   - Enable the checkbox next to it
   - You might see a dialog asking to quit the app - click "Quit & Reopen"

5. **Relaunch**
   ```bash
   open ~/.openclaw/workspace/screenmuse/ScreenMuse.app
   ```

---

### For Accessibility Permission (Optional)

Same steps, but:
- Go to: Privacy & Security → **Accessibility**
- Add ScreenMuse.app the same way

**Note:** Accessibility is only needed if you want keystroke overlays and keyboard tracking. Screen Recording is the essential one.

---

## Troubleshooting

### "I don't see a (+) button"

**macOS 13+:** The button might be hidden. Try:
1. Click anywhere in the app list area
2. Look at the very bottom of the window
3. There should be a small (+) and (-) button

**Alternative:** Use the lock icon:
1. Click the 🔒 lock icon (bottom left)
2. Enter your password
3. The (+) button should appear

### "ScreenMuse appears but is grayed out"

The app might have been denied before. Try:
1. Remove it from the list (select it, click (-) button)
2. Quit ScreenMuse completely: `pkill -9 ScreenMuse`
3. Rebuild: `./scripts/build-cli.sh --only`
4. Launch and try again: `open ScreenMuse.app`

### "I added it but server still doesn't start"

Check the logs:
```bash
tail -50 ~/Movies/ScreenMuse/Logs/screenmuse-$(date +%Y-%m-%d).log
```

Look for:
- ✅ "NWListener started on port 7823" - good!
- ❌ "Screen Recording permission NOT granted" - permission issue
- ❌ "applicationDidFinishLaunching" but no server start - check for errors

### "The app crashes when I launch it"

Check if Screen Recording permission was actually granted:
```bash
# Launch the app
open ~/.openclaw/workspace/screenmuse/ScreenMuse.app

# Wait 3 seconds
sleep 3

# Test server
curl http://localhost:7823/status
```

If you get `curl: (7) Failed to connect` → permission issue  
If you get JSON response → it's working!

---

## Why Doesn't It Auto-Appear?

macOS only adds apps to the permission lists when they:
1. Are properly signed (we do this now!)
2. Have a stable bundle ID (we have: `ai.noats.screenmuse`)
3. Actually REQUEST the permission (done via `SCShareableContent` API)

The request happens automatically when ScreenMuse launches, but sometimes macOS gets confused if:
- The app was previously denied with a different bundle ID
- The app was rebuilt many times (old TCC entries conflict)
- SIP (System Integrity Protection) cached old permissions

**The manual (+) button method ALWAYS works!** ✅

---

## Verification

Once added and enabled, test:

```bash
# Should return JSON with recording:false
curl http://localhost:7823/status

# Should show performance metrics
curl http://localhost:7823/performance | jq '.'

# Should list available windows
curl http://localhost:7823/windows | jq '.windows | length'
```

If all three work → **YOU'RE DONE!** 🎉

---

## Still Having Issues?

Share the output of:

```bash
# 1. Check bundle ID
codesign -d -vvv ~/.openclaw/workspace/screenmuse/ScreenMuse.app 2>&1 | grep Identifier

# 2. Check logs
tail -30 ~/Movies/ScreenMuse/Logs/screenmuse-$(date +%Y-%m-%d).log

# 3. Check process
ps aux | grep ScreenMuse | grep -v grep
```

And I'll help debug!
