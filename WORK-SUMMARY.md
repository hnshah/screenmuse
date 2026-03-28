# ScreenMuse Work Summary

Phase 0 (P1-P6) and Phase 1 (1A-1D) completed and pushed to `main`.

## P1: Fix 65KB body limit on HTTP receive

**File:** `Sources/ScreenMuseCore/AgentAPI/ScreenMuseServer.swift`

Replaced the single-shot `connection.receive(maximumLength: 65536)` with a chunk
accumulation loop. The new implementation:

- Reads headers to find `Content-Length`
- Accumulates body chunks (up to 65536 bytes each) until Content-Length is satisfied
- Rejects requests exceeding a 4MB hard cap with HTTP 413
- Falls through immediately for requests with no Content-Length (GET, DELETE)
- Added 401/413 to the status text mapping in `sendResponse`

**Commit:** `fix: P1 - fix 65KB body limit on HTTP receive`

---

## P2: Implement POST /script/batch

**Files:**
- `Sources/ScreenMuseCore/AgentAPI/Server+Media.swift` — new `handleScriptBatch` handler
- `Sources/ScreenMuseCore/AgentAPI/ScreenMuseServer.swift` — route added
- `Sources/ScreenMuseCore/AgentAPI/Server+System.swift` — endpoint added to version list

Runs multiple named scripts in sequence. Each script contains a `commands` array
processed identically to `/script`. Returns per-script results with name, ok, steps_run,
steps, and error. Stops on first script failure unless `continue_on_error: true`.

**Commit:** `feat: P2 - implement POST /script/batch endpoint`

---

## P3: Template tests -> real tests

**New files (3 test files, 27 test functions):**
- `Tests/ScreenMuseCoreTests/RecordingConfigTests.swift` (10 tests)
  - Quality bitrate mapping (low through max)
  - Bitrates are monotonically increasing
  - Raw value round-trip for all Quality cases
  - Invalid raw value returns nil
  - Config defaults (audio, fps, quality)
  - AudioSource equality checks

- `Tests/ScreenMuseCoreTests/ServerStateTests.swift` (8 tests)
  - Chapter accumulation and ordering
  - Session notes accumulation
  - Highlight flag toggling
  - Session highlights accumulation
  - isRecording state transitions
  - Session ID/name lifecycle

- `Tests/ScreenMuseCoreTests/SpeedRampConfigValidationTests.swift` (9 tests)
  - idle_speed / active_speed clamping bounds
  - ActivityAnalyzer with no events (single active segment)
  - ActivityAnalyzer with zero duration
  - Adjacent idle segment merging
  - Short gaps classified as active
  - VideoTrimmer config reencode toggle
  - SpeedRampResult compression ratio

All tests are pure logic — no I/O, no running server required.

**Commit:** `test: P3 - add 27 real tests from template patterns`

---

## P4: Complete MCP server (8 new tools)

**Files:**
- `mcp-server/screenmuse-mcp.js` — 8 new tool definitions + execution cases
- `mcp-server/package.json` — new file
- `mcp-server/README.md` — updated

New tools added:
1. `screenmuse_record` — POST /record (one-shot record with duration)
2. `screenmuse_speedramp` — POST /speedramp
3. `screenmuse_concat` — POST /concat
4. `screenmuse_crop` — POST /crop
5. `screenmuse_annotate` — POST /annotate
6. `screenmuse_script` — POST /script
7. `screenmuse_script_batch` — POST /script/batch
8. `screenmuse_highlight` — POST /highlight

Also:
- API key support: reads `SCREENMUSE_API_KEY` env var, adds `X-ScreenMuse-Key` header
- Version bumped from 1.3.0 to 1.6.0
- package.json: name=screenmuse-mcp, version=1.6.0, type=module, engines.node>=18
- README updated with all 26 tools, API key instructions, batch script example

**Commit:** `feat: P4 - complete MCP server with 8 new tools`

---

## P5: Auth auto-generate

**File:** `Sources/ScreenMuseCore/AgentAPI/ScreenMuseServer.swift`

New `loadOrGenerateAPIKey()` method called from `start()`. Priority order:
1. `~/.screenmuse/api_key` file (read and trim whitespace)
2. `SCREENMUSE_API_KEY` env var (legacy support)
3. `SCREENMUSE_NO_AUTH=1` env var (explicit opt-out, apiKey = nil)
4. Auto-generate UUID, write to `~/.screenmuse/api_key`, create directory if needed

Prints key source to console on startup.

**Commit:** `feat: P5 - auto-generate API key on first launch`

---

## P6: Router refactor with MARK comments

**File:** `Sources/ScreenMuseCore/AgentAPI/ScreenMuseServer.swift`

Conservative documentation/organization refactor:
- ASCII art route table header with instructions for adding new routes
- MARK comments for each category: Recording, Export, Stream, Window, System, Media & Batch
- Updated file header to list all 6 route groups with their extension files
- Consistent column alignment across all route entries

No functional changes.

**Commit:** `refactor: P6 - organize router with MARK comments per category`

---

## Phase 1A: Async Job Queue

**New file:** `Sources/ScreenMuseCore/AgentAPI/JobQueue.swift`
**Modified:** `ScreenMuseServer.swift`, `Server+Export.swift`, `Server+Media.swift`, `Server+System.swift`

Added lightweight async job system for long-running endpoints. When `"async": true`
is passed in the request body, the endpoint returns 202 immediately with a job ID.
Clients poll `GET /job/:id` for status.

- `JobQueue` actor: thread-safe job tracking with create/setRunning/complete/fail/cleanup
- `dispatchAsync` helper: wraps any handler for async execution using a dummy NWConnection
  mapped to a job ID — `sendResponse` routes results to JobQueue instead of the wire
- New routes: `GET /job/:id`, `GET /jobs` (added to router and version endpoint list)
- Async dispatch added to 8 endpoints: `/export`, `/speedramp`, `/concat`, `/frames`,
  `/crop`, `/ocr`, `/validate`, `/annotate`
- 202 status code added to `sendResponse` status text mapping

**Commit:** `feat: Phase1A - async job queue`

---

## Phase 1B: Test Coverage to 70%

**New files (5 test files, 61 new tests — total: 13 files, ~115 tests):**

- `Tests/ScreenMuseCoreTests/ExportConfigTests.swift` (16 tests)
  - GIFExporter.Config defaults (fps=10, scale=800, quality=.medium, format=.gif)
  - Format raw value round-trip (gif, webp) + invalid returns nil
  - Quality color counts (low=128, medium/high=256)
  - Quality raw value round-trip + invalid
  - File extensions, config mutation

- `Tests/ScreenMuseCoreTests/JobQueueTests.swift` (13 tests)
  - Job creation (unique IDs, 8-char prefix, pending status, endpoint stored)
  - Status transitions (running, completed with result, failed with error)
  - List (returns all, sorted descending), get (nonexistent returns nil)
  - Cleanup (removes old completed, keeps running)
  - Dictionary representation

- `Tests/ScreenMuseCoreTests/TimelineTests.swift` (10 tests)
  - Chapter ordering by time, non-negative timestamps
  - Note timestamp accuracy (within 0.01s), text preservation
  - Multiple highlight accumulation, order preserved
  - Event count calculation (chapters + notes + highlights)
  - Empty timeline, chapter name variants (empty, unicode)

- `Tests/ScreenMuseCoreTests/ResponseFormatTests.swift` (13 tests)
  - Error response structure (error key, optional code/suggestion)
  - Status code mapping (200, 202, 400, 404, 409, 413, 500)
  - structuredError for PermissionDenied, NotRecording, WindowNotFound, unknown
  - ExportResult and TrimResult asDictionary
  - TrimError and SpeedRampError description strings

- `Tests/ScreenMuseCoreTests/AuthTests.swift` (9 tests)
  - API key nil = no auth required
  - Matching key passes, mismatched fails, empty fails, case-sensitive
  - /health and OPTIONS skip auth, normal endpoints do not
  - Header name lowercasing

All tests are pure logic — no I/O, no running server.

**Commit:** `test: Phase1B - test coverage to 70% with 5 new test files`

---

## Phase 1C: Webhook Retries

**File:** `Sources/ScreenMuseCore/AgentAPI/ScreenMuseServer.swift`
**New file:** `Tests/ScreenMuseCoreTests/WebhookTests.swift`

Replaced single fire-and-forget webhook with retry logic:
- Up to 3 attempts with exponential backoff: 0s, 2s, 8s
- Success (2xx HTTP status) stops retrying immediately
- Non-2xx and network errors trigger next retry
- Final failure logged at error level
- Backoff array exposed as `static let webhookBackoffSeconds` for testability

WebhookTests.swift (8 tests):
- Backoff array has 3 entries, first is immediate (0s), order is exponential
- Retry simulation: success on attempt 1 stops, success on attempt 2 stops, all fail exhausts 3
- Nil webhook URL does nothing (guard test)

**Commit:** `feat: Phase1C - webhook retries with exponential backoff`

---

## Phase 1D: npx Install for MCP Server

**Files:**
- `mcp-server/package.json` — added `repository` field, updated description/keywords
- `mcp-server/INSTALL.md` — new file with 3 install options
- `README.md` — MCP section updated with npx as primary install method

Install options documented:
1. npx (no install): `"command": "npx", "args": ["screenmuse-mcp"]` in claude_desktop_config.json
2. Global install: `npm install -g screenmuse-mcp`
3. Direct path: clone repo and run with node

INSTALL.md includes API key discovery (`~/.screenmuse/api_key`) and env var reference.

**Commit:** `feat: Phase1D - npx install for MCP server`
