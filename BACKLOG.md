# ScreenMuse — Backlog

Last updated: 2026-04-11 (Sprint 4 hardening plan on `claude/analyze-repo-RKrj5`)

---

## State of the repo (one-paragraph audit)

28 test files under `Tests/ScreenMuseCoreTests/`, covering auth, HTTP integration,
job queue, pagination, timeline, QA, speedramp, webhook, and OpenAPI drift.
`ScreenMuseCore` has 12 subdirectories and `AgentAPI` exposes 47 routes.
Only 2 TODO/FIXME markers remain in `Sources/` (both benign UI previews).
`ScreenMuseServer.swift` is 832 lines of dispatch + helpers + route table;
`Server+Export.swift` is 836 lines. `request_id` is already threaded through
every response body *and* every log line (embedded as `[\(reqID)]` at call
sites). The Sprint 4 focus is the next wave of agent-facing endpoints and
durability hardening — not a test-coverage emergency.

---

## Queue (priority order)

### 🔴 High — Sprint 4

| # | Task | Notes |
|---|------|-------|
| 1 | **POST /browser** — headless Playwright recording | Node subprocess runner installed on-demand under `~/.screenmuse/playwright-runner/`. User POSTs `{url, script?, duration, width, height, headless}` → we spawn Node+Playwright, record the window, return a stop response. Keeps the Swift binary dependency-free. |
| 2 | **POST /narrate** — AI narration of recordings | Timestamped narration + chapter suggestions via vision LLM. Providers: Anthropic Claude, OpenAI, and **Ollama (local, default)** for zero-cost agent loops. Uses `ActivityAnalyzer` for smart frame sampling, runs through `JobQueue`. |
| 3 | **Disk-space guard + `GET /metrics`** | Pre-flight check in `RecordingManager.startRecording` and `JobQueue` that refuses if free disk < configurable N GB. Prometheus-format `/metrics` endpoint surfaces `active_recordings`, `jobs_queued`, `disk_free_bytes`, `http_requests_total`. |

### 🟡 Medium — Sprint 4

| # | Task | Notes |
|---|------|-------|
| 4 | **POST /publish** — multi-destination export | `Publisher` protocol, one file per destination: Slack (webhook + file upload), GitHub gist, S3/R2 (presigned PUT). iCloud stays as the reference implementation. |
| 5 | **SCContentSharingPicker integration** | Permission-free recording for specific windows on macOS 15+. Eliminates first-run TCC friction. Feature-flagged behind `@available(macOS 15, *)`, ScreenCaptureKit fallback on macOS 14. |
| 6 | **Resilience tests** | Kill mid-recording → `/recordings` marks corrupted; 50× concurrent `/start` → exactly-one wins, 49 get 409; disk-full during export → clean failure, no orphans. |

### 🟢 Low / Long-term

| # | Task | Notes |
|---|------|-------|
| 7 | **Continuous capture / monitor mode** | Competes directly with Screenpipe. High storage-management complexity. Deferred unless a real customer pulls — the agent-first thesis is more focused. |
| 8 | **Swift 6 strict concurrency migration** | Core + App + CLI on `.swiftLanguageMode(.v5)`; MCP already on v6. See "Swift 6 migration plan" below for the staged approach. |
| 9 | **Browser CI integration guide** | Doc `/browser` + Playwright CI patterns with Docker compose example. |
| 10 | **AI agent examples repo** | Claude Code, Cursor, and Codex end-to-end recording workflows. |

---

## Swift 6 migration plan

Everything shipped in **Sprint 4** is already Swift-6-clean by construction.
The blockers are all pre-Sprint-4 code. Migrate in this order so each step
is independently revertible and ships without flag-days:

### Step 1 — Split Config + System into a leaf target (low risk)
Files already Sendable-safe and free of circular imports:
- `Sources/ScreenMuseCore/Config/ScreenMuseConfig.swift` — single `Codable: Sendable` struct
- `Sources/ScreenMuseCore/System/DiskSpaceGuard.swift` — pure-logic `Sendable` struct
- `Sources/ScreenMuseCore/Capture/ContentSharingPicker.swift` — `Sendable` wrappers, no state
- `Sources/ScreenMuseCore/Publish/*.swift` — all `Sendable` structs + `Publisher` protocol
- `Sources/ScreenMuseCore/Narration/*.swift` — all `Sendable` structs, one mock-holding class
- `Sources/ScreenMuseCore/Browser/RunnerScript.swift` — static strings only

**Approach:** extract these into a new `ScreenMuseFoundation` target on
`.swiftLanguageMode(.v6)`. `ScreenMuseCore` depends on it. Zero changes to
the files themselves — they already conform.

### Step 2 — MetricsRegistry + JobQueue actors (already clean)
- `Sources/ScreenMuseCore/AgentAPI/MetricsRegistry.swift` — actor
- `Sources/ScreenMuseCore/AgentAPI/JobQueue.swift` — actor with `@unchecked Sendable` Job struct

Neither file needs work. The blocker is that they live in the same target
as the non-Sendable ScreenMuseServer, so a Swift 6 flip of the full target
would require ScreenMuseServer to be migrated first.

### Step 3 — Recording pipeline (medium risk)
- `Sources/ScreenMuseCore/Recording/RecordingManager.swift`
- `Sources/ScreenMuseCore/Recording/PiPRecordingManager.swift`
- `Sources/ScreenMuseCore/Recording/CursorTracker.swift`
- `Sources/ScreenMuseCore/Recording/KeyboardMonitor.swift`

Each of these needs careful Sendable audits because they span
`SCStream` delegate callbacks (non-Sendable Apple APIs) and `@MainActor`
state. Expect `@preconcurrency` imports, some `@unchecked Sendable` on
wrapper structs that hold non-Sendable Apple types, and new actors around
frame buffers.

### Step 4 — Export pipeline (medium risk)
- `Sources/ScreenMuseCore/Export/*.swift`

Mostly pure transforms (VideoTrimmer, VideoCropper, SpeedRamper). Risk
is in `ActivityAnalyzer` which currently mutates shared state — needs to
become an actor or have its state thread through `@MainActor`.

### Step 5 — ScreenMuseServer (highest risk)
- `Sources/ScreenMuseCore/AgentAPI/ScreenMuseServer.swift` (832 lines)
- All `Server+*.swift` extensions

Already `@MainActor`, so most of the compiler complaints will come from
the `NWConnection` state handlers (currently `@retroactive @unchecked
Sendable`), the `@Sendable` closures passed to `connection.receive`, and
the `jobConnections` map lookups that happen inside `sendResponse`.
This is the real refactoring work — do it with compiler feedback, not
speculation.

### Step 6 — Flip the target
Once steps 3–5 compile cleanly under Swift 6 strict mode, flip
`.swiftLanguageMode(.v5)` → `.v6` on `ScreenMuseCore`, then on
`ScreenMuseApp` and `ScreenMuseCLI`. CI catches any remaining warnings.

### What NOT to do
- **Do not** run a big-bang migration. The codebase has ~11k lines of
  pre-Sprint-4 code and no compiler feedback without a macOS build.
- **Do not** remove `@preconcurrency import ScreenCaptureKit` — Apple's
  SCStream delegates genuinely have Sendable issues in their upstream
  SDK that aren't ours to fix.
- **Do not** migrate `RecordingCoordinating` protocol until
  `RecordViewModel` (in ScreenMuseApp) is ready — it's the bridge
  between targets and a rename there is a multi-file refactor.

---

## Completed ✅

| Task | Sprint | Notes |
|------|--------|-------|
| **Request ID in every response + every log line** | Sprint 3 | Auto-injected via `sendResponse`; embedded as `[\(reqID)]` at every log call site |
| **POST /qa** (video quality analysis) | Sprint 3 | `QAReport` JSON with 5 quality checks |
| **POST /diff** (video structural diff) | Sprint 3 | Metadata delta — duration, size, bitrate, resolution, fps, codec |
| Auth / API key (`X-ScreenMuse-Key`) | Prior sprints | Complete + auto-generated |
| 65KB body limit → streaming accumulation | Prior sprints | `accumulateBody()` + 4MB cap |
| Region bounds validation | Prior sprints | validateRegion() helper |
| `/script/batch` endpoint | Prior sprints | Full implementation + tests |
| `POST /record` convenience endpoint | Prior sprints | Complete with duration validation |
| Swift 6 guard-let in stateUpdateHandlers | Prior sprints | fd leak fix (#13) |
| Script injection security | Prior sprints | SECURITY.md + hardening (#18) |
| Codable request/response types (top 5) | Prior sprints | APITypes.swift |
| Job progress streaming | Prior sprints | /job/{id} + SSE (#24) |
| Homebrew formula + RELEASING.md | Prior sprints | packages/homebrew/screenmuse.rb (#25) |
| HTTP integration tests | Prior sprints | 43 tests, port 7825 (#5) |
| TypeScript client type fixes | Prior sprints | All types match API (#19) |
| Permission UX improvements | Prior sprints | Auto-detect + clear error messages (#20) |
| Native Swift MCP server | Prior sprints | Sources/ScreenMuseMCP/ (#23) |
| Background export (GIF/speedramp/concat) | Prior sprints | Task.detached (#49) |
| API versioning header | Prior sprints | X-ScreenMuse-Version (#50) |
| OpenAPI spec drift CI check | Prior sprints | OpenAPISpecDriftTests.swift (#47) |
| SwiftLint baseline | Prior sprints | .swiftlint.yml (#48) |
| Troubleshooting README section | Prior sprints | (#51) |
| resolveSourceURL helper | Prior sprints | Deduplicated 7 handlers (#46) |
| Pre-existing test fixes | Prior sprints | 4 failures resolved (#61) |
| **Config file tests** | 2026-04-04 | 18 tests for ScreenMuseConfig |
| **Codable types: trim/speedramp/chapter/highlight/note** | 2026-04-04 | APITypes.swift |
| **Python client: full API coverage** | 2026-04-04 | +10 methods, +15 tests |
| **Node/TS client: full API coverage** | 2026-04-04 | +10 methods, +20 test assertions |
| **Pagination on GET /recordings** | 2026-04-04 | ?limit=N&offset=N&sort=desc |
| **OpenAPI spec audit** | 2026-04-04 | 47/47 paths match router |
| **POST /record + /script/batch HTTP tests** | 2026-04-04 | Dispatch table coverage |

---

## Competitive Landscape (2026-04)

- **Screenpipe**: Passive continuous capture as MCP server. Main differentiation vs ScreenMuse.
- **Mux agentic recording**: Browser-based, AI narration focus.
- **Community MCP tools**: Screenshot + narration + inspection in one MCP tool call.

ScreenMuse's edge: **macOS native quality + full API surface + Swift MCP server** — no Node.js dependency.
