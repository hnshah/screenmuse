# ScreenMuse — Backlog

Last updated: 2026-04-04 (post Sprint 3 with Oatis)

---

## Queue (priority order)

### 🔴 High

| # | Task | Notes |
|---|------|-------|
| 1 | **POST /browser** — headless Playwright recording | Huge cross-platform surface area. Agents need browser recording too. npm install playwright, expose via HTTP API. |
| 2 | **POST /narrate** — AI narration of recordings | After recording, generate timestamped narration + chapter suggestions via vision LLM (Claude/GPT-4o). Frames extraction already exists. |
| 3 | **Request ID in all responses** | Add `"request_id"` to every JSON response for distributed tracing. Requires threading reqID through sendResponse (~146 call sites — non-trivial). |
| 4 | **Continuous capture / monitor mode** | Long-running passive capture saving only on interesting events. Competes with Screenpipe's core value prop. High storage management complexity. |

### 🟡 Medium

| # | Task | Notes |
|---|------|-------|
| 5 | **POST /diff** — recording comparison | Compare two recordings, return structured diff: which regions changed, when, how much. For visual regression and monitoring use cases. |
| 6 | **POST /publish** — multi-destination export | Publish to S3, Cloudflare R2, Notion, GitHub gist, Slack. Start with Slack (iCloud already done). |
| 7 | **SCContentSharingPicker integration** | Permission-free recording for specific windows using macOS 15 system picker. Eliminates first-run friction. |
| 8 | ~~**Pagination tests for /recordings**~~ | ✅ Done (Sprint 3) — 22 tests in RecordingsPaginationTests.swift |

### 🟢 Low / Long-term

| # | Task | Notes |
|---|------|-------|
| 9 | **Swift 6 strict concurrency** | Both targets on `.swiftLanguageMode(.v5)`. Migrating would catch races at compile time. Major effort. |
| 10 | **Browser CI integration guide** | Playwright/Puppeteer users want HTTP-API-driven recording in CI. Document the pattern + Docker compose example. |
| 11 | **AI agent examples repo** | Claude Code, Cursor, and Codex integration examples showing end-to-end recording workflows. |

---

## Completed ✅

| Task | Sprint | Notes |
|------|--------|-------|
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
