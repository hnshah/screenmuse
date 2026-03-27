# ScreenMuse — Backlog

Queued 2026-03-27 after post-review sprint planning with Hiten.
Tracks 1-3 (router extraction, speedramp fix, Swift tests) are in active work on branch `refactor/router-speedramp-tests`.

---

## Queue (priority order)

### 🔴 High

| # | Task | File(s) | Notes |
|---|------|---------|-------|
| 1 | **Auth / API key** | `ScreenMuseServer.swift` (new router) | Port 7823, no auth, CORS wide open. Add `X-ScreenMuse-Key` header check in router — ~20 lines. Configurable via env var or plist. Essential before any demo/LAN exposure. |
| 2 | **65KB body limit** | `ScreenMuseServer.swift` `receiveRequest()` | `maximumLength: 65536` silently truncates large `/concat` sources or `/annotate` overlays. Needs streaming accumulation loop — receive chunks until delimiter, not one-shot. |
| 3 | **Region bounds validation** | `/start` handler | Region larger than display or with negative coords fails silently or corrupts. Add guard against `SCDisplay` bounds in `/start`. ~10 lines. |

### 🟡 Medium

| # | Task | File(s) | Notes |
|---|------|---------|-------|
| 4 | **`/script/batch` endpoint** | `Server+Media.swift` | Documented in `AGENT_API.md`, README, and v1.4.0 changelog but doesn't exist. Either implement (accept array of script configs, return array of results) or remove from docs. |
| 5 | **`POST /record` convenience endpoint** | `Server+Recording.swift` | `{name, duration_seconds}` → chains start → sleep → stop internally. Agents that just want "record 30 seconds" shouldn't need two API calls. |

### 🟢 Low / Long-term

| # | Task | File(s) | Notes |
|---|------|---------|-------|
| 6 | **Swift 6 concurrency migration** | All `ScreenMuseCore` | Both targets on `.swiftLanguageMode(.v5)`. The `nonisolated(unsafe)` workarounds are a code smell. Migrating to strict concurrency would catch races at compile time. Major effort — do after test coverage exists. |
| 7 | **MCP server Swift port** | `mcp-server/screenmuse-mcp.js` | Node.js in an otherwise pure Swift project. Adds a runtime dep. Long-term nice-to-have, not urgent. |

---

## Completed (from review sprint)

| # | Task | Branch | Status |
|---|------|--------|--------|
| T1 | Router extraction (7 handler extension files) | `refactor/router-speedramp-tests` | ⏳ in progress |
| T2 | Speedramp data flow fix + `analysis_method` in response | `refactor/router-speedramp-tests` | ⏳ in progress |
| T3 | Swift test target + SpeedRamper/VideoTrimmer/flow tests | `refactor/router-speedramp-tests` | ⏳ in progress |
| B1 | `GET /health` endpoint | `refactor/router-speedramp-tests` | ⏳ in progress |
| B2 | `OPTIONS` preflight handler | `refactor/router-speedramp-tests` | ⏳ in progress |
| B3 | PiP `/stop` enriched response | `refactor/router-speedramp-tests` | ⏳ in progress |
