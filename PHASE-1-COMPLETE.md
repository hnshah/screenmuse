# Phase 1: Foundation & Debugging ✅

**Goal:** Solid debugging, logging, and reliability before building features

## What Was Added

### New Endpoints

#### `GET /logs/download`
**Purpose:** One-click download of all logs for bug reports  
**Returns:** ZIP file containing:
- All log files from `~/Movies/ScreenMuse/Logs/`
- System info snapshot (macOS version, app version, permissions, save directory)
- Recent session metadata

**Usage:**
```bash
curl http://localhost:7823/logs/download -o screenmuse-logs.zip
```

**Use case:** User reports a bug → send them this URL → get complete diagnostic package

---

#### `GET /performance`
**Purpose:** Real-time performance monitoring  
**Returns:** JSON with:
- App memory usage (MB)
- Physical memory total (GB)
- Thread count
- Disk space available (GB)
- System uptime
- Recording state & duration

**Usage:**
```bash
curl http://localhost:7823/performance | jq '.'
```

**Use case:** Debug performance issues, detect memory leaks, monitor resource usage

---

### Already Existing (Verified)

#### `GET /logs`
**Purpose:** Recent log entries from ring buffer  
**Params:** `?limit=N`, `?level=error|warning|info|debug`, `?category=recording|server|etc`

**Usage:**
```bash
curl "http://localhost:7823/logs?limit=20&level=error"
```

---

#### `GET /report`
**Purpose:** Clean session report for bug reports  
**Returns:** Human-readable summary of current/last session

---

#### `GET /debug`
**Purpose:** Quick debug snapshot  
**Returns:** Save directory, recent recordings, server state

---

## Implementation Details

### Logs ZIP Creation
- Uses macOS built-in `/usr/bin/zip` command
- Creates temporary directory with all logs
- Adds `system-info.json` with diagnostic data
- Returns file via HTTP with proper `Content-Disposition` header

### Performance Metrics
- Uses `mach_task_basic_info` for memory usage
- Thread count via `task_threads`
- Disk space via `URLResourceValues.volumeAvailableCapacity`
- No external dependencies - pure macOS APIs

### Error Handling
- `structuredError()` already provides actionable error messages
- Returns error code + suggestion for common failures:
  - `PERMISSION_DENIED` → Grant Screen Recording permission
  - `WINDOW_NOT_FOUND` → Use `GET /windows` to list available
  - `DISK_FULL` → Free up space

---

## Testing Requirements

**Before testing, the app needs:**
1. Screen Recording permission granted
2. Fresh build with new endpoints
3. Running on port 7823

**Test script:**
```bash
# 1. Performance metrics
curl http://localhost:7823/performance | jq '.'

# 2. Recent logs
curl "http://localhost:7823/logs?limit=10"

# 3. Download logs
curl http://localhost:7823/logs/download -o test-logs.zip
unzip -l test-logs.zip

# 4. Session report
curl http://localhost:7823/report
```

---

## What's Next

**Phase 1 complete!** Foundation is solid:
- ✅ Comprehensive logging system
- ✅ Easy log download for bug reports
- ✅ Real-time performance monitoring
- ✅ Actionable error messages
- ✅ Clean session reports

**Ready for Phase 2: Smart Recording** 🚀

- AI script generator
- Smart zoom/pan
- Automated mistake detection
- Scene transitions
- Auto-editing

---

**Commit:** `4d38164` - feat: Phase 1 debugging endpoints  
**Branch:** `feature/showcase-examples`  
**Files changed:** `Sources/ScreenMuseCore/AgentAPI/ScreenMuseServer.swift`
