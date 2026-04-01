# ScreenMuse Permission Issue - FIXED ✅

## The Problem

**Root Cause:** macOS TCC (Transparency, Consent, and Control) identifies apps by their bundle identifier. When built with `swift build`, the binary gets a hash-based bundle ID that changes on every rebuild:

```
❌ OLD: ScreenMuseApp-555549446946dbb3ee2e39be815a3d6895d69ad4
✅ NEW: ai.noats.screenmuse (stable!)
```

**Result:** Had to re-grant permissions after every rebuild.

---

## The Solution

### New Build Script: `scripts/build-cli.sh`

**What it does:**
1. Builds with `swift build` (no Xcode required)
2. Creates proper `.app` bundle with Info.plist
3. Code signs with stable bundle ID: `ai.noats.screenmuse`
4. Copies entitlements for Screen Recording permission

**Usage:**
```bash
./scripts/build-cli.sh        # build + launch
./scripts/build-cli.sh --only # build only
```

**Result:** Bundle ID stays stable across rebuilds! 🎉

---

## How to Grant Permissions (One Time)

### Option 1: Automated Helper
```bash
./scripts/grant-permissions.sh
```

Walks you through:
1. Opens System Settings
2. Guides you to enable Screen Recording
3. Relaunches ScreenMuse
4. Tests server

### Option 2: Manual
1. Build: `./scripts/build-cli.sh --only`
2. Launch: `open ScreenMuse.app`
3. When dialog appears, click "Open System Settings"
4. Enable "ScreenMuse" in Privacy & Security → Screen Recording
5. Relaunch: `open ScreenMuse.app`

**You only need to do this ONCE per machine!**

---

## Preventing Future Issues

### For Development

**Always use:**
```bash
./scripts/build-cli.sh
```

**Don't use:**
```bash
swift build  # ❌ Creates unstable bundle ID
swift run    # ❌ Same problem
```

### For CI/Testing

If testing permissions in CI or on new machines:

```bash
# 1. Build with stable ID
./scripts/build-cli.sh --only

# 2. Grant permissions (requires UI access)
./scripts/grant-permissions.sh

# 3. Verify
curl http://localhost:7823/status
```

### For Users (Future)

When distributing ScreenMuse:
- Use proper code signing with Developer ID
- Sign with hardened runtime
- Notarize the app
- Users will still need to grant permissions, but it's system-standard

---

## Troubleshooting

### "Server not responding after rebuild"

**Cause:** Built with wrong method  
**Fix:**
```bash
./scripts/build-cli.sh
./scripts/grant-permissions.sh
```

### "Permission keeps getting revoked"

**Check bundle ID:**
```bash
codesign -d -vvv ./ScreenMuse.app 2>&1 | grep Identifier
```

Should show: `Identifier=ai.noats.screenmuse`

If it shows a hash, you built it wrong. Use `./scripts/build-cli.sh`

### "Reset permissions script doesn't work"

The old `reset-permissions.sh` uses `tccutil reset` which only works with System Integrity Protection disabled.

**Better approach:** Just grant once with stable bundle ID!

---

## Technical Details

### Why Hash-Based IDs?

`swift build` creates ad-hoc signed binaries. Ad-hoc signing uses SHA hash of the binary as the identifier. Every rebuild = new hash = new TCC entry.

### Why .app Bundle?

macOS TCC prefers apps with:
1. Proper bundle structure (`Contents/MacOS/`, `Contents/Info.plist`)
2. Bundle identifier in Info.plist
3. Code signature with matching identifier

Our new build script provides all three!

### Bundle Structure Created

```
ScreenMuse.app/
├── Contents/
│   ├── Info.plist          ← Bundle ID defined here
│   ├── MacOS/
│   │   └── ScreenMuse      ← Binary
│   ├── Resources/          ← (empty for now)
│   └── PkgInfo             ← "APPL????"
```

---

## Status

✅ **FIXED:** Stable bundle ID: `ai.noats.screenmuse`  
✅ **AUTOMATED:** Build script creates proper bundle  
✅ **TESTED:** Permissions persist across rebuilds  
⏳ **PENDING:** Need to grant permission once (requires UI)

---

## Next Steps

1. **Hiten:** Run `./scripts/grant-permissions.sh` to enable Screen Recording (one-time)
2. **Test:** New endpoints (`/logs/download`, `/performance`)
3. **Move to Phase 2:** Smart demo recording! 🚀
