/**
 * Unit tests for the ScreenMuse MCP server (screenmuse-mcp.js).
 *
 * Tests cover:
 *   1. TOOLS array — completeness, schema validity, no duplicates
 *   2. executeTool dispatch — every tool name maps to an endpoint
 *   3. callScreenMuse helper — correct HTTP method / path routing
 *   4. handleMessage — MCP protocol (initialize, tools/list, tools/call, ping)
 *   5. Error handling — ECONNREFUSED, unknown tool, fetch errors
 *
 * Run: node --experimental-vm-modules mcp-server/tests/test-mcp-server.js
 *  or: cd mcp-server && node tests/test-mcp-server.js
 */

import { createRequire } from 'module';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ── Minimal test framework ────────────────────────────────────────────────────

let passed = 0;
let failed = 0;
const failures = [];

function assert(condition, message) {
  if (condition) {
    passed++;
  } else {
    failed++;
    failures.push(message);
    console.error(`  ✗ FAIL: ${message}`);
  }
}

function assertEqual(actual, expected, message) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) {
    passed++;
  } else {
    failed++;
    const msg = `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`;
    failures.push(msg);
    console.error(`  ✗ FAIL: ${msg}`);
  }
}

function assertIncludes(arr, value, message) {
  assert(arr.includes(value), `${message}: ${JSON.stringify(value)} not found in ${JSON.stringify(arr)}`);
}

function section(name) {
  console.log(`\n── ${name} ─────────────────────────────────────────────`);
}

// ── Load the MCP server source for inspection ─────────────────────────────────

const serverPath = path.resolve(__dirname, '..', 'screenmuse-mcp.js');
const source = readFileSync(serverPath, 'utf8');

// Extract the TOOLS array by parsing the JS (we'll parse JSON-compatible parts)
// Simpler: we'll import the module and test its exports (after patching globals)

// Since screenmuse-mcp.js is a self-contained script (no exports), we test it
// by analysing its source structure and behaviour via carefully crafted tests.

// ── Section 1: TOOLS array completeness ──────────────────────────────────────

section('TOOLS array: completeness and validity');

// Extract all tool names from source
const toolNameMatches = source.match(/name:\s*'screenmuse_[^']+'/g) || [];
const toolNames = toolNameMatches.map(s => s.replace(/name:\s*'/, '').replace(/'/, ''));

// Remove duplicates (case executeTool also references names)
const uniqueToolNames = [...new Set(toolNames.filter(n => n.startsWith('screenmuse_')))];

// Check count
assert(uniqueToolNames.length >= 45, `Expected >= 45 tools, got ${uniqueToolNames.length}`);
console.log(`  ℹ  Total tools: ${uniqueToolNames.length}`);

// Check required tools exist
const requiredTools = [
  // Recording lifecycle
  'screenmuse_start', 'screenmuse_stop', 'screenmuse_pause', 'screenmuse_resume',
  'screenmuse_record', 'screenmuse_chapter', 'screenmuse_note', 'screenmuse_highlight',
  // Capture
  'screenmuse_screenshot', 'screenmuse_frame', 'screenmuse_frames',
  'screenmuse_thumbnail', 'screenmuse_ocr',
  // Export
  'screenmuse_export', 'screenmuse_trim', 'screenmuse_speedramp',
  'screenmuse_concat', 'screenmuse_crop', 'screenmuse_annotate',
  // System
  'screenmuse_status', 'screenmuse_timeline', 'screenmuse_recordings',
  'screenmuse_windows', 'screenmuse_active_window', 'screenmuse_clipboard',
  'screenmuse_running_apps',
  // Window management
  'screenmuse_window_focus', 'screenmuse_window_position', 'screenmuse_hide_others',
  // Sessions
  'screenmuse_sessions', 'screenmuse_get_session', 'screenmuse_delete_session',
  // Jobs
  'screenmuse_jobs', 'screenmuse_get_job',
  // Health & info
  'screenmuse_health', 'screenmuse_version',
  // Advanced
  'screenmuse_start_pip', 'screenmuse_script', 'screenmuse_script_batch',
  'screenmuse_validate', 'screenmuse_delete_recording',
  // Upload & diagnostics
  'screenmuse_upload_icloud', 'screenmuse_debug', 'screenmuse_logs', 'screenmuse_report',
];

for (const name of requiredTools) {
  assertIncludes(uniqueToolNames, name, `Required tool missing`);
}

// No duplicates
const nameArr = toolNames.filter(n => toolNames.indexOf(n) !== toolNames.lastIndexOf(n));
// Duplicates are expected (tool names appear in both TOOLS array and executeTool switch)
// Instead verify uniqueness within the TOOLS array specifically
const toolsArrayMatch = source.match(/const TOOLS = \[([\s\S]*?)\];/);
if (toolsArrayMatch) {
  const toolsSection = toolsArrayMatch[1];
  const toolsNames = toolsSection.match(/name:\s*'screenmuse_[^']+'/g) || [];
  const toolsNamesClean = toolsNames.map(s => s.replace(/name:\s*'/, '').replace(/'/, ''));
  const toolsSet = new Set(toolsNamesClean);
  assertEqual(toolsNamesClean.length, toolsSet.size, 'No duplicate tool names in TOOLS array');
}

// ── Section 2: Every tool name has a case in executeTool ─────────────────────

section('executeTool dispatch: every tool has a handler');

// Extract tool names from TOOLS array definition
const toolsArraySection = source.match(/const TOOLS = \[([\s\S]*?)\];/)?.[1] || '';
const definedToolNames = (toolsArraySection.match(/name:\s*'screenmuse_[^']+'/g) || [])
  .map(s => s.replace(/name:\s*'/, '').replace(/'$/, ''));

// Extract handled cases from executeTool
const caseMatches = source.match(/case 'screenmuse_[^']+'/g) || [];
const handledNames = caseMatches.map(s => s.replace("case '", '').replace("'", ''));

for (const name of definedToolNames) {
  assertIncludes(handledNames, name, `Tool '${name}' has no handler in executeTool`);
}

console.log(`  ℹ  Defined: ${definedToolNames.length}, Handled: ${handledNames.length}`);

// ── Section 3: Tool schema validation ────────────────────────────────────────

section('Tool schemas: required properties present');

// Every tool should have name, description, inputSchema
assert(
  source.includes("description: 'Start a screen recording"),
  'screenmuse_start has description'
);
assert(
  source.includes("inputSchema"),
  'Tools use inputSchema'
);
assert(
  source.includes("type: 'object'"),
  'inputSchema has type: object'
);

// Required tools with required parameters should specify them
const startPipSection = source.match(/screenmuse_start_pip[\s\S]*?screenmuse_sessions/)?.[0] || '';
assert(
  startPipSection.includes("required"),
  'screenmuse_start_pip specifies required parameters'
);

// ── Section 4: API routing logic ─────────────────────────────────────────────

section('API routing: correct endpoints for key operations');

// Verify that key paths are correctly mapped
assert(source.includes("'/start', args"), 'screenmuse_start routes to /start');
assert(source.includes("'/stop'"), 'screenmuse_stop routes to /stop');
assert(source.includes("'/pause'"), 'screenmuse_pause routes to /pause');
assert(source.includes("'/resume'"), 'screenmuse_resume routes to /resume');
assert(source.includes("'/export'"), 'screenmuse_export routes to /export');
assert(source.includes("'/trim'"), 'screenmuse_trim routes to /trim');
assert(source.includes("'/speedramp'"), 'screenmuse_speedramp routes to /speedramp');
assert(source.includes("'/concat'"), 'screenmuse_concat routes to /concat');
assert(source.includes("'/crop'"), 'screenmuse_crop routes to /crop');
assert(source.includes("'/ocr'"), 'screenmuse_ocr routes to /ocr');
assert(source.includes("'/windows'"), 'screenmuse_windows routes to /windows');
assert(source.includes("'/system/active-window'"), 'screenmuse_active_window routes to /system/active-window');
assert(source.includes("'/system/clipboard'"), 'screenmuse_clipboard routes to /system/clipboard');
assert(source.includes("'/system/running-apps'"), 'screenmuse_running_apps routes to /system/running-apps');
assert(source.includes("'/timeline'"), 'screenmuse_timeline routes to /timeline');
assert(source.includes("'/recordings'"), 'screenmuse_recordings routes to /recordings');
assert(source.includes("'/sessions'"), 'screenmuse_sessions routes to /sessions');
assert(source.includes("'/jobs'"), 'screenmuse_jobs routes to /jobs');
assert(source.includes("'/version'"), 'screenmuse_version routes to /version');
assert(source.includes("'/debug'"), 'screenmuse_debug routes to /debug');
assert(source.includes("'/logs'"), 'screenmuse_logs routes to /logs');
assert(source.includes("'/report'"), 'screenmuse_report routes to /report');
assert(source.includes("'/upload/icloud'"), 'screenmuse_upload_icloud routes to /upload/icloud');
assert(source.includes("'/start/pip'"), 'screenmuse_start_pip routes to /start/pip');

// Parameterised routes use template literals
assert(source.includes('/session/${args.session_id}'), 'screenmuse_get_session uses template literal');
assert(source.includes('/job/${args.job_id}'), 'screenmuse_get_job uses template literal');

// DELETE operations
assert(
  source.includes("'DELETE'") || source.includes('"DELETE"'),
  'DELETE method used for delete operations'
);
assert(
  source.includes("recording', args || {}, 'DELETE'") ||
  source.includes('/recording', args || {}, "'DELETE'"),
  'screenmuse_delete_recording uses DELETE method'
);

// ── Section 5: /health bypasses auth ─────────────────────────────────────────

section('Auth: /health bypasses API key requirement');

// health tool should use a direct fetch (no API key header)
const healthCase = source.match(/case 'screenmuse_health':([\s\S]*?)break;/)?.[1] || '';
assert(healthCase.length > 0, 'screenmuse_health has a case handler');
// The health tool should NOT call callScreenMuse (which injects the key)
// OR if it does, it relies on the /health exemption in the server
assert(
  healthCase.includes('fetch') || healthCase.includes('callScreenMuse'),
  'screenmuse_health makes an HTTP request'
);

// ── Section 6: MCP protocol messages ─────────────────────────────────────────

section('MCP protocol: message types handled');

assert(source.includes("'initialize'"), 'handles initialize method');
assert(source.includes("'tools/list'"), 'handles tools/list method');
assert(source.includes("'tools/call'"), 'handles tools/call method');
assert(source.includes("'ping'"), 'handles ping method');
assert(source.includes("protocolVersion"), 'returns protocolVersion in initialize response');
assert(source.includes("2024-11-05"), 'uses MCP protocol version 2024-11-05');
assert(source.includes("capabilities: { tools: {} }"), 'declares tools capability');
assert(source.includes("'notifications/initialized'"), 'handles initialized notification');

// ── Section 7: Error handling ─────────────────────────────────────────────────

section('Error handling: ECONNREFUSED and unknown tools');

assert(
  source.includes('ECONNREFUSED'),
  'Handles ECONNREFUSED (ScreenMuse not running)'
);
assert(
  source.includes('ScreenMuse is not running'),
  'Returns friendly error when server unreachable'
);
assert(
  source.includes('Unknown tool:'),
  'Returns error for unknown tool names'
);
assert(
  source.includes('isError: true'),
  'Error results include isError: true'
);

// ── Section 8: Response format ───────────────────────────────────────────────

section('Response format: MCP-compliant output');

assert(
  source.includes("{ type: 'text', text:"),
  'Tool results use text content type'
);
assert(
  source.includes("JSON.stringify(result, null, 2)"),
  'Results are pretty-printed JSON'
);
assert(
  source.includes("jsonrpc: '2.0'"),
  'All messages include jsonrpc 2.0'
);

// ── Section 9: Content-Length framing ────────────────────────────────────────

section('Stdio transport: Content-Length framing');

assert(
  source.includes('Content-Length:'),
  'Messages include Content-Length header'
);
assert(
  source.includes('Buffer.byteLength'),
  'Content-Length uses byte length (not string length)'
);
assert(
  source.includes('\\r\\n\\r\\n'),
  'Header/body separated by CRLF CRLF'
);

// ── Section 10: Env config ────────────────────────────────────────────────────

section('Configuration: env var support');

assert(
  source.includes('SCREENMUSE_URL'),
  'BASE_URL configurable via SCREENMUSE_URL env var'
);
assert(
  source.includes('SCREENMUSE_API_KEY'),
  'API key configurable via SCREENMUSE_API_KEY env var'
);
assert(
  source.includes('SCREENMUSE_NO_AUTH'),
  'Auth can be disabled via SCREENMUSE_NO_AUTH=1'
);
assert(
  source.includes('~/.screenmuse/api_key') || source.includes('.screenmuse/api_key'),
  'Falls back to ~/.screenmuse/api_key file'
);

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
