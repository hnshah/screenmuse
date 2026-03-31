/**
 * Unit tests for the ScreenMuse Node.js TypeScript client (src/index.ts).
 *
 * Since the TypeScript source can't be compiled in environments without
 * @types/node, these tests analyse the source to verify:
 *   1. All expected methods are declared
 *   2. All expected interface types are defined
 *   3. API key loading logic is correct
 *   4. HTTP method/path routing is correct per method
 *   5. Body construction logic for key methods
 *   6. Default parameter handling
 *
 * Run: node clients/node/tests/test-client.js
 *   or (on macOS with built dist/): node -e "require('./dist').ScreenMuse" && node tests/test-client.js
 */

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const srcPath = path.resolve(__dirname, '..', 'src', 'index.ts');
const source = readFileSync(srcPath, 'utf8');

// ── Minimal test framework ────────────────────────────────────────────────────

let passed = 0;
let failed = 0;
const failures = [];

function assert(condition, message) {
  if (condition) { passed++; }
  else { failed++; failures.push(message); console.error(`  ✗ FAIL: ${message}`); }
}

function section(name) {
  console.log(`\n── ${name} ─────────────────────────────────────────────`);
}

// ── Section 1: Interface definitions ─────────────────────────────────────────

section('Interfaces: all expected types defined');

const expectedInterfaces = [
  'RecordingStatus',
  'RecordingResult',
  'ExportResult',
  'TrimResult',
  'StartResult',
  'HealthResult',
  'ScreenMuseOptions',
  // New interfaces added in latest update
  'OcrResult',
  'SpeedRampResult',
  'ConcatResult',
  'CropResult',
  'AnnotateResult',
  'ThumbnailResult',
  'FramesResult',
  'FrameResult',
  'WindowInfo',
  'ActiveWindowResult',
  'ClipboardResult',
  'RunningApp',
  'TimelineResult',
  'RecordingInfo',
  'SessionInfo',
  'VersionResult',
  'ValidateResult',
];

for (const iface of expectedInterfaces) {
  assert(
    source.includes(`export interface ${iface}`) || source.includes(`interface ${iface}`),
    `Interface ${iface} is defined`
  );
}

console.log(`  ℹ  Checked ${expectedInterfaces.length} interfaces`);

// ── Section 2: Method declarations ───────────────────────────────────────────

section('Methods: all expected async methods declared');

const expectedMethods = [
  // Pre-existing
  'async health',
  'async start',
  'async stop',
  'async pause',
  'async resume',
  'async status',
  'async markChapter',
  'async addNote',
  'async highlightNextClick',
  'async screenshot',
  'async export',
  'async trim',
  'async record',
  // New methods
  'async ocr',
  'async speedramp',
  'async concat',
  'async crop',
  'async annotate',
  'async thumbnail',
  'async frames',
  'async frame',
  'async validate',
  'async windows',
  'async focusWindow',
  'async positionWindow',
  'async hideOthers',
  'async activeWindow',
  'async clipboard',
  'async runningApps',
  'async timeline',
  'async recordings',
  'async deleteRecording',
  'async sessions',
  'async getSession',
  'async deleteSession',
  'async version',
];

for (const method of expectedMethods) {
  assert(source.includes(method), `Method '${method}' is declared`);
}

console.log(`  ℹ  Checked ${expectedMethods.length} methods`);

// ── Section 3: HTTP routing ───────────────────────────────────────────────────

section('HTTP routing: correct endpoints mapped');

const routeChecks = [
  ['/health', 'health endpoint'],
  ['/start"', 'start endpoint'],
  ['/stop"', 'stop endpoint'],
  ['/pause"', 'pause endpoint'],
  ['/resume"', 'resume endpoint'],
  ['/status"', 'status endpoint'],
  ['/chapter"', 'chapter endpoint'],
  ['/note"', 'note endpoint'],
  ['/highlight"', 'highlight endpoint'],
  ['/screenshot"', 'screenshot endpoint'],
  ['/export"', 'export endpoint'],
  ['/trim"', 'trim endpoint'],
  ['/speedramp"', 'speedramp endpoint'],
  ['/concat"', 'concat endpoint'],
  ['/crop"', 'crop endpoint'],
  ['/annotate"', 'annotate endpoint'],
  ['/ocr"', 'ocr endpoint'],
  ['/thumbnail"', 'thumbnail endpoint'],
  ['/frames"', 'frames endpoint'],
  ['/frame"', 'frame endpoint'],
  ['/validate"', 'validate endpoint'],
  ['/windows"', 'windows endpoint'],
  ['/window/focus"', 'window focus endpoint'],
  ['/window/position"', 'window position endpoint'],
  ['/window/hide-others"', 'window hide-others endpoint'],
  ['/system/active-window"', 'active window endpoint'],
  ['/system/clipboard"', 'clipboard endpoint'],
  ['/system/running-apps"', 'running apps endpoint'],
  ['/timeline"', 'timeline endpoint'],
  ['/recordings"', 'recordings endpoint'],
  ['/recording"', 'delete recording endpoint'],
  ['/sessions"', 'sessions endpoint'],
  ['/version"', 'version endpoint'],
];

for (const [path, desc] of routeChecks) {
  assert(source.includes(path), `Correct path for ${desc}: "${path}"`);
}

// Parameterised paths
assert(
  source.includes('`/session/${sessionId}`'),
  'getSession uses template literal /session/${sessionId}'
);
assert(
  source.includes('`/session/${sessionId}`'),
  'deleteSession uses template literal /session/${sessionId}'
);

// ── Section 4: HTTP method correctness ────────────────────────────────────────

section('HTTP methods: GET vs POST vs DELETE correctly used');

// GET endpoints
assert(source.includes('"GET", "/status"'), 'status uses GET');
assert(source.includes('"GET", "/windows"'), 'windows uses GET');
assert(source.includes('"GET", "/timeline"'), 'timeline uses GET');
assert(source.includes('"GET", "/recordings"'), 'recordings uses GET');
assert(source.includes('"GET", "/sessions"'), 'sessions uses GET');
assert(source.includes('"GET", "/version"'), 'version uses GET');
assert(source.includes('"GET", "/system/active-window"'), 'activeWindow uses GET');
assert(source.includes('"GET", "/system/clipboard"'), 'clipboard uses GET');
assert(source.includes('"GET", "/system/running-apps"'), 'runningApps uses GET');

// POST endpoints
assert(source.includes('"POST", "/start"'), 'start uses POST');
assert(source.includes('"POST", "/stop"'), 'stop uses POST');
assert(source.includes('"POST", "/chapter"'), 'markChapter uses POST');
assert(source.includes('"POST", "/export"'), 'export uses POST');
assert(source.includes('"POST", "/trim"'), 'trim uses POST');
assert(source.includes('"POST", "/ocr"'), 'ocr uses POST');
assert(source.includes('"POST", "/validate"'), 'validate uses POST');
assert(source.includes('"POST", "/speedramp"'), 'speedramp uses POST');
assert(source.includes('"POST", "/concat"'), 'concat uses POST');
assert(source.includes('"POST", "/crop"'), 'crop uses POST');
assert(source.includes('"POST", "/annotate"'), 'annotate uses POST');

// DELETE endpoints
assert(source.includes('"DELETE", "/recording"'), 'deleteRecording uses DELETE');
assert(
  source.includes('"DELETE", `/session/${') || source.includes('"DELETE"') && source.includes('/session/'),
  'deleteSession uses DELETE'
);

// ── Section 5: Body construction for key methods ──────────────────────────────

section('Body construction: optional params only included when set');

// start() should conditionally include fields — check source broadly
assert(source.includes('if (options.name) body.name'), 'start() conditionally includes name');
assert(source.includes('if (options.quality) body.quality'), 'start() conditionally includes quality');
assert(source.includes('body.window_title'), 'start() maps windowTitle → window_title');

// trim() required params
assert(source.includes('start: options.start'), 'trim() always includes start');
assert(source.includes('end: options.end'), 'trim() always includes end');
assert(source.includes('fast_copy') || source.includes('fastCopy'), 'trim() handles fast_copy');

// crop() required params
assert(source.includes('x: options.x'), 'crop() includes x');
assert(source.includes('width: options.width'), 'crop() includes width');

// concat sources
assert(source.includes('sources: options.sources'), 'concat() includes sources array');

// deleteRecording includes filename in body
assert(
  source.includes('{ filename }') || source.includes('"filename"'),
  'deleteRecording includes filename in body'
);

// ── Section 6: API key handling ───────────────────────────────────────────────

section('API key: loading and header injection');

assert(source.includes('SCREENMUSE_API_KEY'), 'Reads SCREENMUSE_API_KEY env var');
assert(source.includes('SCREENMUSE_NO_AUTH'), 'Supports SCREENMUSE_NO_AUTH=1');
assert(source.includes('.screenmuse/api_key'), 'Falls back to ~/.screenmuse/api_key file');
assert(source.includes('X-ScreenMuse-Key'), 'Injects X-ScreenMuse-Key header');
assert(source.includes('apiKey?: string'), 'ScreenMuseOptions.apiKey is optional');

// health() should bypass auth (fetches without headers)
const healthMethod = source.match(/async health[\s\S]*?return r\.json\(\)/)?.[0] || '';
assert(
  healthMethod.includes('this.baseUrl') && !healthMethod.includes('this.headers()'),
  'health() uses direct fetch without auth headers'
);

// ── Section 7: record() convenience ──────────────────────────────────────────

section('record(): start → fn() → stop → optional export');

const recordMethod = source.match(/async record\([\s\S]*?return result;\s*\}/)?.[0] || '';
assert(recordMethod.includes('await this.start'), 'record() calls start()');
assert(recordMethod.includes('await fn()'), 'record() calls fn()');
assert(recordMethod.includes('await this.stop'), 'record() calls stop()');
assert(recordMethod.includes('options.gif'), 'record() checks gif option');
assert(recordMethod.includes('await this.export'), 'record() calls export() when gif=true');
assert(recordMethod.includes('gif_path'), 'record() adds gif_path to result');

// ── Section 8: TypeScript type annotations ────────────────────────────────────

section('TypeScript: return types and interface usage');

assert(source.includes('Promise<OcrResult>'), 'ocr() returns Promise<OcrResult>');
assert(source.includes('Promise<SpeedRampResult>'), 'speedramp() returns Promise<SpeedRampResult>');
assert(source.includes('Promise<ConcatResult>'), 'concat() returns Promise<ConcatResult>');
assert(source.includes('Promise<CropResult>'), 'crop() returns Promise<CropResult>');
assert(source.includes('Promise<AnnotateResult>'), 'annotate() returns Promise<AnnotateResult>');
assert(source.includes('Promise<ThumbnailResult>'), 'thumbnail() returns Promise<ThumbnailResult>');
assert(source.includes('Promise<FramesResult>'), 'frames() returns Promise<FramesResult>');
assert(source.includes('Promise<FrameResult>'), 'frame() returns Promise<FrameResult>');
assert(source.includes('Promise<WindowInfo[]>'), 'windows() returns Promise<WindowInfo[]>');
assert(source.includes('Promise<ActiveWindowResult>'), 'activeWindow() returns Promise<ActiveWindowResult>');
assert(source.includes('Promise<ClipboardResult>'), 'clipboard() returns Promise<ClipboardResult>');
assert(source.includes('Promise<RunningApp[]>'), 'runningApps() returns Promise<RunningApp[]>');
assert(source.includes('Promise<TimelineResult>'), 'timeline() returns Promise<TimelineResult>');
assert(source.includes('Promise<RecordingInfo[]>'), 'recordings() returns Promise<RecordingInfo[]>');
assert(source.includes('Promise<SessionInfo[]>'), 'sessions() returns Promise<SessionInfo[]>');
assert(source.includes('Promise<SessionInfo>'), 'getSession() returns Promise<SessionInfo>');
assert(source.includes('Promise<VersionResult>'), 'version() returns Promise<VersionResult>');
assert(source.includes('Promise<ValidateResult>'), 'validate() returns Promise<ValidateResult>');

// ── Summary ───────────────────────────────────────────────────────────────────

console.log(`\n${'─'.repeat(60)}`);
console.log(`Results: ${passed} passed, ${failed} failed`);

if (failures.length > 0) {
  console.error('\nFailures:');
  failures.forEach((f, i) => console.error(`  ${i + 1}. ${f}`));
  process.exit(1);
} else {
  console.log('All tests passed ✓');
}
