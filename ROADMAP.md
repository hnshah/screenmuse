# ScreenMuse Roadmap

Code quality audit and strategic roadmap. Generated 2026-03-28.

---

## Executive Summary

ScreenMuse is an impressive piece of engineering for its age (~5 days of development). It ships a fully-functional native macOS screen recorder with a 40+ endpoint HTTP API, CLI, MCP server, Playwright integration, Python/Node clients, and an OpenClaw skill. The core recording pipeline (ScreenCaptureKit + AVFoundation + Metal compositing) is solid and the API surface is remarkably complete.

**Where it stands today:** ScreenMuse is a working alpha that punches above its weight. An agent can record a demo, mark chapters, export a GIF, and share it — all via curl. The server extraction into 7 handler files was the right architectural move. Test coverage is growing. Auth and streaming body handling are in place.

**What's holding it back:** The gap between "works for the developer who built it" and "works for any agent that discovers it" is the critical delta. The README assumes prior context. Client libraries cover ~15% of the API surface. Tests only cover pure helper functions — zero integration coverage of the HTTP layer. The CI pipeline builds but doesn't run tests. Error handling is good in places and inconsistent in others.

**Strategic position:** ScreenMuse occupies a unique niche — no other tool offers agent-controlled screen recording with this API surface. The competitive moat is real, but only if the developer experience catches up to the capability.

---

## Audit Scorecard

### 1. README Quality — 7/10

**Strengths:**
- Clear one-liner: "The screen recorder built for AI agents"
- Complete API reference table with every endpoint
- Practical curl examples for basic usage
- Good "Pairing with Peekaboo" section showing ecosystem thinking
- Links to OpenAPI spec for machine-readable reference
- Dev-run.sh explanation of the TCC signing problem (excellent — this saves hours of debugging)

**Gaps:**
- No hero GIF or screenshot. A 3-second GIF showing `curl /start` -> screen recording -> `curl /stop` -> GIF output would immediately communicate what this does better than 50 lines of text
- No "What does the output look like?" section — show the JSON response from `/stop` so agents know what to expect
- No troubleshooting section for common failures (permission denied, port in use, no frames captured)
- The install instructions jump from `git clone` to `./scripts/dev-run.sh` with no mention of Xcode being required, Swift version requirements, or whether Homebrew is an option
- No "How agents should use this" narrative — explain the flow: health check -> start -> do stuff -> chapter -> stop -> export
- Missing version badge, license, and macOS version compatibility badge
- The `curl /openapi` suggestion is great but no one will try it unless they see the OpenAPI spec is actually useful

### 2. API Design — 8/10

**Strengths:**
- Consistent JSON request/response across all endpoints
- Sensible HTTP methods (POST for mutations, GET for reads, DELETE for deletions)
- "source": "last" convention is brilliant — agents don't need to track file paths between calls
- Region validation with `display_bounds` in error response helps agents self-correct
- Enriched `/stop` response with resolution, fps, size_mb, chapters, notes — agents get everything they need
- `/health` exempt from auth — correct for liveness probes
- CORS handling for browser-based agents
- `/record` convenience endpoint (start + wait + stop in one call) — exactly what agents want

**Gaps:**
- No request ID in responses. The server logs `[reqID]` but doesn't return it — agents can't correlate errors with server-side logs
- `/script` and `/script/batch` are command injection vectors. No sandboxing, no allowlist, no explanation of the security model. An agent with API access can `rm -rf /`. This must be documented as "local-only, trusted-agent" or removed
- Inconsistent error response shapes: some use `{"error": "...", "code": "..."}`, some use just `{"error": "..."}`, some add `"suggestion"`. Adopt a consistent schema everywhere
- No pagination on `/recordings` — will break with hundreds of files
- `/annotate` endpoint exists in the route table but `GET /annotate` was added in v1.4.0 changelog; the README documents `POST /annotate` — needs clarification
- No rate limiting or request timeout (NWListener-based server with no backpressure)
- `/openapi` spec is a static JSON string literal in `OpenAPISpec.swift` — will drift from reality as endpoints are added/changed. Should be generated from the route table or at minimum validated in CI
- No versioning strategy (no `/v1/` prefix, no `Accept-Version` header). Breaking changes will be silent

### 3. Code Architecture — 7/10

**Strengths:**
- Clean separation: `ScreenMuseCore` (library) / `ScreenMuseApp` (GUI) / `ScreenMuseCLI` (CLI) — three products from one Package.swift
- `RecordingCoordinating` protocol cleanly decouples the server from the UI layer — dependency injection without a DI framework
- Server handler extraction into 7 extension files (`Server+Recording`, `Server+Export`, etc.) — the dispatch table in `ScreenMuseServer.swift` is now ~60 lines
- `ServerHelpers.swift` extracts testable pure functions from the server — `checkAPIKey`, `validateRegion`, `validateRecordDuration`
- Structured logging with `ScreenMuseLogger` — categories, levels, ring buffer, file sink, usage log
- Export pipeline components (`GIFExporter`, `SpeedRamper`, `VideoTrimmer`, `VideoCropper`, `VideoConcatenator`) are clean, standalone, and well-documented with doc comments
- Each error enum has `LocalizedError` conformance with actionable messages

**Gaps:**
- `ScreenMuseServer` is `@MainActor` with a `NWListener` on `.main` queue. This means all HTTP request handling blocks the main thread. For a GUI app, long-running exports (GIF generation, speed ramp) will freeze the UI. The server should dispatch work to background actors/queues
- HTTP parsing is hand-rolled: splitting on `\r\n`, manual Content-Length parsing, manual header extraction. This works but is fragile — e.g., doesn't handle chunked transfer encoding, multipart, or UTF-8 BOM. Consider `swift-nio` or `Vapor` for the HTTP layer long-term
- The `nonisolated(unsafe)` workarounds in `RecordingManager` are a code smell. The comment explains why, but this is the kind of thing that causes subtle races. Swift 6 strict concurrency mode would catch these
- Duplicate code: the "resolve source URL" pattern (`sourceStr == "last" ? currentVideoURL : URL(fileURLWithPath: sourceStr)`) appears in `/export`, `/trim`, `/speedramp`, `/concat`, `/frames`, `/thumbnail`, `/crop` — 7 times. Extract a helper
- The `body: [String: Any]` parameter threading through every handler is untyped. A `Codable` request struct per endpoint would catch type errors at compile time instead of runtime
- `ScreenMuseCLI` duplicates the `Args` struct definition — the test file even has a comment acknowledging this. Move `Args` to `ScreenMuseCore` or create a shared internal target
- Hardcoded port 7823 in the server. The CLI supports `--port` but the server always binds to 7823. Should be configurable
- `sendResponse` silently drops errors if JSON serialization fails (the `guard let` just returns) — server closes connection with no response, which is worse than a 500

### 4. Test Coverage — 4/10

**Strengths:**
- Test target exists and is properly configured in Package.swift
- Tests for pure helper functions: `checkAPIKey` (12 tests), `validateRegion` (12 tests), `validateRecordDuration` (10 tests), `parseContentLength` (implied by ContentLengthParserTests)
- Config/result struct tests for `SpeedRamper`, `GIFExporter` (defaults, serialization, error messages)
- `MockRecordingCoordinator` demonstrates protocol-oriented testing
- `SpeedRampDataFlowTests` tests the activity analysis pipeline end-to-end with mock data
- `CLIArgsTests` covers the argument parser

**Gaps:**
- **Zero HTTP integration tests.** The core product is an HTTP API — none of the endpoints are tested via actual HTTP requests. This is the #1 testing gap
- **No test for the server route dispatch.** If a route is accidentally deleted from the switch statement, no test catches it
- **No test for error responses.** The carefully structured errors (`ALREADY_RECORDING`, `PERMISSION_DENIED`, etc.) are not verified by tests
- **No test for JSON serialization of API responses.** The `enrichedStopResponse()` output shape is not tested
- **CI doesn't run tests.** `build.yml` runs `swift build` but not `swift test`. The test target isn't even built in CI
- **No test for the MCP server.** The `screenmuse-mcp.js` has zero tests — no verification that tool definitions match the actual API
- **No test for the Python or Node.js clients.** Client libraries could break silently
- **Smoke test exists but is manual.** `test/api/smoke-test.sh` requires a running ScreenMuse instance — not CI-compatible
- **No test for body accumulation.** The streaming body fix (removing the 65KB limit) is untested — this is the kind of fix that regresses

### 5. Agent Client Quality (OpenClaw Skill) — 5/10

**Strengths:**
- `SKILL.md` is well-structured with clear "When to Use" section
- `auto_record_skill.sh` wrapping pattern is clever — wrap any command to auto-record it
- `screenmuse_helper.py` is zero-dependency (stdlib only) and returns JSON
- API endpoint table in the skill doc

**Gaps:**
- The skill only covers 5 of 40+ endpoints: start, stop, chapter, highlight, status. Missing: export, trim, speedramp, screenshot, ocr, record, frames, window management, recordings list
- `screenmuse_helper.py` doesn't support auth (`X-ScreenMuse-Key` header) — will fail when API key is configured
- `screenmuse_helper.py` timeout is 5 seconds — `/export` (GIF) and `/speedramp` can take 30+ seconds
- No error handling for common failures: ScreenMuse not running, permission denied, already recording
- The Python client (`clients/python/client.py`) requires `requests` as a dependency but has no `requirements.txt` and the `setup.py` doesn't list it
- Node.js client (`clients/node/src/index.ts`) has no `README.md`, no tests, and the `RecordingResult` type doesn't match the actual `/stop` response shape (it expects `metadata.session_id` but the API returns `session_id` at the top level)
- The MCP server doesn't support the `screenmuse_record` convenience endpoint, `screenmuse_speedramp`, `screenmuse_crop`, `screenmuse_concat`, `screenmuse_validate`, or `screenmuse_highlight`

### 6. Error Handling — 7/10

**Strengths:**
- Every `RecordingError` case has a human-readable message AND a machine-readable `code` field
- `"suggestion"` field in many error responses helps agents self-correct (e.g., "Call GET /windows to list available windows")
- `structuredError()` centralizes RecordingError -> JSON mapping
- 409 for "already recording" / "not recording" — correct HTTP semantics
- 413 for oversized request bodies with `max_bytes` in response
- 404 for "no video available" with explanation of what to do

**Gaps:**
- Not all error responses include `code`. Some just have `{"error": "..."}` — e.g., the 500 in `handleStop` when coordinator returns nil
- No error code catalog in docs — agents need to know all possible codes to handle them programmatically
- `/script` returns raw shell output on error with no structure — `{"error": "exit code 1: ..."}`
- Some 500 errors leak internal details: `"error": error.localizedDescription` can expose file paths, system state
- The auth 401 response doesn't include `WWW-Authenticate` header (HTTP standard for auth challenges)
- No distinction between client errors (4xx — agent did something wrong) and server errors (5xx — ScreenMuse broke) in several places. E.g., `/screenshot` returns 500 for "No display found" which is a server configuration issue, not a client error

### 7. Installation/Setup Experience — 5/10

**Strengths:**
- `dev-run.sh` handles the TCC signing problem — this is a huge quality-of-life improvement
- `reset-permissions.sh` exists for when things go wrong
- Package.swift works with both Xcode and swift build

**Gaps:**
- No Homebrew formula or cask. The only install method is `git clone` + build from source
- No pre-built binary releases on GitHub. An agent can't `curl -L | tar xz` to install
- No mention of Xcode being required (xcodebuild is the recommended build path)
- No mention of minimum Swift version (Package.swift says swift-tools-version: 6.0 but this isn't called out)
- `dev-run.sh` output is noisy (dumps build warnings) — could filter to just errors and the final success/failure
- No `Makefile` or `just` recipe for common operations (build, test, run, clean)
- No Docker support (not expected for a macOS app, but worth noting)
- First launch requires manually granting Screen Recording permission, then relaunching. This should be more prominent — a first-time user will think the app is broken
- No verification that ScreenMuse is actually running and ready to accept connections. An agent needs to poll `/health` but this isn't documented in the setup flow

### 8. Documentation Depth — 6/10

**Strengths:**
- README has a complete API reference table
- CHANGELOG is detailed and follows Keep a Changelog format
- BACKLOG.md shows active development planning
- `docs/AGENT_API.md` points to the live OpenAPI spec (good DRY approach)
- Implementation docs for effects features (`docs/implementation/*.md`) show engineering thought process
- `Tests/TESTING.md` is thorough for the Peekaboo UI testing approach

**Gaps:**
- No architecture doc explaining the component boundaries (ScreenMuseCore vs ScreenMuseApp vs CLI, RecordingCoordinating protocol, effects pipeline)
- No "How to add a new endpoint" guide for contributors
- No explanation of the recording pipeline: ScreenCaptureKit -> SCStream -> AVAssetWriter -> Effects compositor -> Final video
- `docs/AGENT_FEATURES_PLAN.md` and `docs/PHASE2_INTEGRATION_COMPLETE.md` are internal planning docs that shouldn't be in the repo (or should be in a wiki/archive)
- No API response examples in docs — agents need to know the exact JSON shape they'll get back from each endpoint
- No sequence diagram showing the typical agent workflow (health -> start -> chapter -> highlight -> stop -> export)
- The OpenAPI spec (`OpenAPISpec.swift`) is hand-maintained and almost certainly incomplete/outdated — no automated validation
- No migration guide for API breaking changes (there haven't been any yet, but the lack of versioning means this will bite eventually)

---

## Quick Wins (1-2 days each, highest impact)

### Q1. Hero GIF in README
Add a terminal recording (using asciinema or similar) showing:
```
$ curl -X POST localhost:7823/start -d '{"name":"demo"}'
{"session_id":"...","status":"recording"}
$ curl -X POST localhost:7823/chapter -d '{"name":"Step 1"}'
{"ok":true}
$ curl -X POST localhost:7823/stop
{"path":"/Users/.../demo.mp4","duration":8.2,"size_mb":1.4}
$ curl -X POST localhost:7823/export -d '{"format":"gif","scale":600}'
{"path":"/Users/.../demo.gif","frames":82,"size_mb":0.8}
```
Then embed the resulting GIF. Show the input (curl commands) and output (video) side by side. This alone will 3x the README's effectiveness.

### Q2. Add `swift test` to CI
Edit `.github/workflows/build.yml` to add:
```yaml
- name: Run tests
  run: swift test 2>&1
```
This is 2 lines. Right now tests can break silently because CI only builds.

### Q3. Request ID in HTTP responses
Add `"request_id": reqID` to every `sendResponse` call. Agents can include this in bug reports. The server already tracks `requestCount` — just thread it into responses.

### Q4. Consistent error response schema
Standardize every error to:
```json
{
  "error": "human-readable message",
  "code": "MACHINE_READABLE_CODE",
  "request_id": 42,
  "suggestion": "what to do about it (optional)"
}
```
Audit all `sendResponse` calls and ensure `code` is always present.

### Q5. Fix the Node.js client type mismatch
`RecordingResult` expects `metadata.session_id` but the actual API returns `session_id` at the top level. Update the TypeScript types to match reality.

### Q6. Add auth support to screenmuse_helper.py
Read `SCREENMUSE_API_KEY` env var and add `X-ScreenMuse-Key` header. 5 lines.

### Q7. Extract the "resolve source URL" helper
The pattern `sourceStr == "last" ? currentVideoURL : URL(fileURLWithPath: sourceStr)` appears 7 times. Extract:
```swift
func resolveSource(_ body: [String: Any], key: String = "source") -> URL? {
    let sourceStr = body[key] as? String ?? "last"
    return (sourceStr == "last") ? currentVideoURL : URL(fileURLWithPath: sourceStr)
}
```

---

## Medium Term (1-2 weeks)

### M1. HTTP Integration Tests
Create a test that starts a `ScreenMuseServer` instance, sends real HTTP requests, and validates responses. This is the single highest-value testing investment. Test:
- Route dispatch (every endpoint responds, unknown routes return 404)
- Auth enforcement (requests without key get 401, with key get through)
- Error response shapes (all errors have `code` field)
- `/version` endpoint count matches route table
- Body parsing (valid JSON, invalid JSON, empty body, oversized body)

Use `URLSession` as the test client talking to the NWListener. No need for Peekaboo or screen recording — just the HTTP layer.

### M2. OpenAPI Spec Validation
Either:
- (a) Generate the OpenAPI spec from the route table at build time, or
- (b) Add a test that fetches `/openapi`, parses it, and verifies every route in the switch statement appears in the spec

The spec will drift. This prevents it.

### M3. Expand MCP Server to Full Coverage
Add missing tools: `screenmuse_record`, `screenmuse_speedramp`, `screenmuse_crop`, `screenmuse_concat`, `screenmuse_validate`, `screenmuse_highlight`, `screenmuse_frames`. The MCP server covers ~50% of the API surface. Agents using Claude Desktop see an incomplete tool.

### M4. Agent Workflow Documentation
Write a `docs/AGENT_WORKFLOW.md` with:
1. Pre-flight: check `/health`, verify permissions
2. Recording flow: `/start` -> `/chapter` (repeat) -> `/highlight` -> `/stop`
3. Post-processing: `/speedramp` -> `/export` with examples
4. Error recovery: what to do when each error code appears
5. Complete JSON response examples for every endpoint

### M5. Configurable Server Port
Make the server port configurable via:
- `SCREENMUSE_PORT` environment variable
- `ScreenMuseServer.shared.start(port: 7823)` parameter
- Fall back to 7823 as default

### M6. Release Binary via GitHub Actions
Add a release workflow that:
1. Builds a signed `.app` bundle via xcodebuild
2. Notarizes it with Apple
3. Uploads as a GitHub Release artifact
4. Updates a Homebrew cask formula

This removes the "build from source" requirement for users.

### M7. First-Run Experience
When ScreenMuse launches without Screen Recording permission:
1. Show a clear message explaining what to do
2. Open System Settings to the correct pane
3. After permission is granted, auto-detect and start the server
4. Log the `/health` URL so agents know ScreenMuse is ready

Currently, first launch silently fails to capture frames with no user-facing explanation.

### M8. Python Client Modernization
- Add `requirements.txt` with `requests`
- Add auth support (`api_key` parameter, `X-ScreenMuse-Key` header)
- Add methods for: `export()`, `trim()`, `speedramp()`, `screenshot()`, `ocr()`, `record(duration)`, `recordings()`, `window_focus(app)`
- Add a `timeout` parameter (default 60s for export operations)
- Add type hints via `py.typed` marker

---

## Long Term (Strategic)

### L1. Swift 6 Strict Concurrency
Migrate from `.swiftLanguageMode(.v5)` to strict Swift 6 concurrency. The `nonisolated(unsafe)` workarounds in `RecordingManager` are race condition risks. This is a significant effort but eliminates a class of bugs.

### L2. Replace Hand-Rolled HTTP with swift-nio or Vapor
The NWListener + manual HTTP parsing works but doesn't support:
- Chunked transfer encoding
- Proper HTTP/1.1 keep-alive
- Request timeouts
- Backpressure / rate limiting
- Middleware (auth, logging, CORS as middleware instead of inline)

Moving to `swift-nio` (low-level) or `Vapor` (batteries-included) would be a significant rewrite but would eliminate the HTTP parsing surface area.

### L3. Typed Request/Response with Codable
Replace `body: [String: Any]` with `Codable` structs per endpoint:
```swift
struct StartRequest: Codable {
    var name: String?
    var windowTitle: String?
    var quality: String?
    var region: Region?
    var webhook: String?
}
```
This catches type errors at compile time, generates documentation, and enables automatic OpenAPI spec generation.

### L4. MCP Server Swift Port
Replace `screenmuse-mcp.js` with a native Swift MCP server. Eliminates the Node.js runtime dependency and keeps the project pure Swift. The MCP protocol is simple enough (JSON-RPC over stdio) that this is feasible.

### L5. Plugin Architecture for Effects
The effects pipeline (click effects, auto-zoom, cursor animation, keystroke overlay) is currently hardcoded. A plugin architecture would let users add custom effects. This is relevant once ScreenMuse has enough users to warrant extensibility.

### L6. Streaming Export Progress
`/export` and `/speedramp` can take 30+ seconds. Return immediately with a `job_id`, then expose:
- `GET /job/{id}` — status, progress percentage
- SSE stream for real-time progress updates
- Webhook callback on completion

This prevents agents from blocking on long-running operations.

---

## GitHub Issues to Open

### Issue 1: `POST /script` is a command injection vector
**Title:** `POST /script` allows arbitrary command execution with no sandboxing
**Description:** The `/script` and `/script/batch` endpoints execute arbitrary shell commands with the permissions of the ScreenMuse process. Any agent (or attacker on the same network if auth is not configured) can run `rm -rf /` or exfiltrate data. This needs either: (a) removal, (b) an allowlist of permitted commands, (c) explicit documentation that this is intentional for local-only trusted-agent use, or (d) sandboxing via `sandbox-exec` or similar.
**Labels:** security, high-priority

### Issue 2: CI should run `swift test`
**Title:** Add `swift test` to GitHub Actions workflow
**Description:** `.github/workflows/build.yml` only runs `swift build`. The test target (`ScreenMuseCoreTests`) has 60+ test cases that are never executed in CI. Tests can break silently.
**Labels:** testing, quick-win

### Issue 3: Add HTTP integration tests for the API layer
**Title:** HTTP integration test suite for ScreenMuseServer
**Description:** The test suite covers pure helper functions (auth, validation, arg parsing) but zero HTTP endpoints. Need a test harness that starts a ScreenMuseServer instance, sends real HTTP requests via URLSession, and validates response status codes, JSON shapes, and error codes. Priority endpoints: route dispatch (all routes respond), auth enforcement, error response consistency, `/version` endpoint count.
**Labels:** testing, medium-effort

### Issue 4: OpenAPI spec drifts from actual endpoints
**Title:** OpenAPI spec (`OpenAPISpec.swift`) is hand-maintained and will drift
**Description:** The OpenAPI JSON is a static string literal. When endpoints are added or changed, the spec must be manually updated. It's already potentially out of date (e.g., `/record`, `/health`, `/validate`, `/frames` may or may not be in the spec). Options: (a) generate from route table, (b) CI test that validates spec matches routes, (c) at minimum, a comment in the file listing what to update.
**Labels:** documentation, api

### Issue 5: Node.js client TypeScript types don't match API
**Title:** `RecordingResult` type in clients/node doesn't match actual `/stop` response
**Description:** The TypeScript interface expects `metadata.session_id` but the actual API returns `session_id`, `path`, `duration`, `size_mb`, etc. at the top level. The `RecordingResult` and `RecordingStatus` types need to match the real response shapes.
**Labels:** bug, clients

### Issue 6: Add hero GIF to README
**Title:** Add a terminal demo GIF showing the full agent workflow
**Description:** The README has great text content but no visual demonstration. A 10-second GIF showing: `curl /start` -> screen recording indicator -> `curl /stop` -> `curl /export` -> resulting GIF would immediately communicate what ScreenMuse does. Use VHS (https://github.com/charmbracelet/vhs) or asciinema + svg-term for a crisp terminal recording.
**Labels:** documentation, quick-win

### Issue 7: Server port should be configurable
**Title:** Make server port configurable via env var / parameter
**Description:** The server always binds to port 7823. The CLI supports `--port` when connecting, but the server itself has no way to change the port. Add `SCREENMUSE_PORT` env var support and a `start(port:)` parameter. This enables running multiple instances and avoids port conflicts.
**Labels:** enhancement, medium-effort

### Issue 8: First-run permission UX needs improvement
**Title:** Improve first-run experience when Screen Recording permission is missing
**Description:** On first launch, ScreenMuse silently fails to capture frames. The user needs to: (1) grant Screen Recording permission in System Settings, (2) relaunch the app. This is documented in the README but not in the app itself. The app should detect the missing permission, show a clear message, offer to open System Settings, and auto-detect when permission is granted.
**Labels:** ux, medium-effort

### Issue 9: MCP server missing 8+ tools
**Title:** Expand MCP server to cover full API surface
**Description:** The MCP server (`mcp-server/screenmuse-mcp.js`) exposes 18 tools but the API has 40+ endpoints. Missing: `screenmuse_record` (convenience), `screenmuse_speedramp`, `screenmuse_crop`, `screenmuse_concat`, `screenmuse_validate`, `screenmuse_frames`, `screenmuse_highlight`, `screenmuse_window_position`, `screenmuse_hide_others`, `screenmuse_delete_recording`, `screenmuse_script`. Claude Desktop users see an incomplete tool.
**Labels:** enhancement, mcp

### Issue 10: `/script/batch` documented but may not exist
**Title:** Verify `/script/batch` endpoint implementation matches documentation
**Description:** `POST /script/batch` is documented in README, AGENT_API.md, and the v1.4.0 changelog, but BACKLOG.md item #4 says it "doesn't exist." Need to verify: if implemented, test it; if not, either implement or remove from docs. Documented-but-nonexistent endpoints are worse than missing features.
**Labels:** bug, documentation

---

## Score Summary

| Area | Score | Key Gap |
|------|-------|---------|
| README Quality | 7/10 | No hero GIF, no troubleshooting section |
| API Design | 8/10 | No request ID in responses, `/script` is unsandboxed |
| Code Architecture | 7/10 | Main-thread server, hand-rolled HTTP, duplicate source-resolution code |
| Test Coverage | 4/10 | Zero HTTP integration tests, CI doesn't run tests |
| Agent Client Quality | 5/10 | Clients cover ~15% of API, types don't match, no auth support |
| Error Handling | 7/10 | Inconsistent error shapes, no error code catalog |
| Installation/Setup | 5/10 | Build from source only, no pre-built binaries, first-run UX gap |
| Documentation Depth | 6/10 | No architecture doc, no response examples, no workflow guide |

**Weighted Overall: 6.1/10** — Solid foundation, needs polish for production agent use.
