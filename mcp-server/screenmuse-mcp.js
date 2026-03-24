#!/usr/bin/env node
/**
 * ScreenMuse MCP Server
 *
 * Exposes ScreenMuse's recording and export API as MCP tools so
 * Claude Desktop, Cursor, and any MCP-compatible agent can use it directly.
 *
 * Pairs naturally with Peekaboo:
 *   Peekaboo = screenshot + GUI automation (see and interact)
 *   ScreenMuse = recording + video pipeline (capture and export)
 *
 * Prerequisites:
 *   1. ScreenMuse.app running on the same Mac (launches the HTTP server on port 7823)
 *   2. Node.js 18+
 *
 * Install in Claude Desktop (~/Library/Application Support/Claude/claude_desktop_config.json):
 *   {
 *     "mcpServers": {
 *       "screenmuse": {
 *         "command": "node",
 *         "args": ["/path/to/screenmuse/mcp-server/screenmuse-mcp.js"]
 *       }
 *     }
 *   }
 *
 * Install in Cursor (settings.json mcpServers):
 *   "screenmuse": { "command": "node", "args": ["/path/to/screenmuse/mcp-server/screenmuse-mcp.js"] }
 */

import { readFileSync } from 'fs';
import { createServer } from 'http';

const BASE_URL = process.env.SCREENMUSE_URL || 'http://localhost:7823';

// ── MCP Protocol Helpers ───────────────────────────────────────────────────

function writeMessage(obj) {
  const json = JSON.stringify(obj);
  process.stdout.write(`Content-Length: ${Buffer.byteLength(json)}\r\n\r\n${json}`);
}

async function callScreenMuse(path, body = null, method = null) {
  const { default: fetch } = await import('node-fetch').catch(() => ({ default: globalThis.fetch }));
  const isGet = body === null && !method;
  const m = method || (body !== null ? 'POST' : 'GET');
  const opts = { method: m, headers: { 'Content-Type': 'application/json' } };
  if (body !== null) opts.body = JSON.stringify(body);
  const res = await (fetch || globalThis.fetch)(`${BASE_URL}${path}`, opts);
  return res.json();
}

// ── Tool Definitions ───────────────────────────────────────────────────────

const TOOLS = [
  {
    name: 'screenmuse_start',
    description: 'Start a screen recording. Optionally record a specific window, region, or quality level. Supports webhooks.',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Recording name/label (default: auto-generated)' },
        quality: { type: 'string', enum: ['low', 'medium', 'high', 'max'], description: 'Video quality (default: medium)' },
        window_title: { type: 'string', description: 'Record a specific window (e.g. "Google Chrome")' },
        region: {
          type: 'object',
          description: 'Record a specific screen region',
          properties: { x: { type: 'number' }, y: { type: 'number' }, width: { type: 'number' }, height: { type: 'number' } }
        },
        audio_source: { type: 'string', description: '"system" (default), "none", or app name for app-only audio' },
        webhook: { type: 'string', description: 'URL to POST to when recording stops' }
      }
    }
  },
  {
    name: 'screenmuse_stop',
    description: 'Stop the current recording. Returns the video file path.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'screenmuse_pause',
    description: 'Pause the current recording.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'screenmuse_resume',
    description: 'Resume a paused recording.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'screenmuse_chapter',
    description: 'Add a named chapter marker at the current recording timestamp.',
    inputSchema: {
      type: 'object',
      required: ['name'],
      properties: { name: { type: 'string', description: 'Chapter name (e.g. "Step 3: Configure settings")' } }
    }
  },
  {
    name: 'screenmuse_note',
    description: 'Add a timestamped annotation to the recording log.',
    inputSchema: {
      type: 'object',
      required: ['text'],
      properties: { text: { type: 'string', description: 'Note text' } }
    }
  },
  {
    name: 'screenmuse_screenshot',
    description: 'Capture a full-screen screenshot and return the file path.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'screenmuse_ocr',
    description: 'Read text from the screen or an image file using Apple Vision (no API key needed, runs locally).',
    inputSchema: {
      type: 'object',
      properties: {
        source: { type: 'string', description: '"screen" (default) or absolute path to an image file' },
        level: { type: 'string', enum: ['accurate', 'fast'], description: 'Recognition quality (default: accurate)' },
        full_text_only: { type: 'boolean', description: 'Return only full_text, omit bounding boxes (default: false)' }
      }
    }
  },
  {
    name: 'screenmuse_export',
    description: 'Export the last recording as an animated GIF or WebP.',
    inputSchema: {
      type: 'object',
      properties: {
        format: { type: 'string', enum: ['gif', 'webp'], description: 'Output format (default: gif)' },
        fps: { type: 'integer', description: 'Frames per second (default: 10)' },
        scale: { type: 'integer', description: 'Max width in pixels (default: 800)' },
        start: { type: 'number', description: 'Start time in seconds' },
        end: { type: 'number', description: 'End time in seconds' }
      }
    }
  },
  {
    name: 'screenmuse_trim',
    description: 'Trim the last recording to a time range (stream copy — near instant, no re-encode).',
    inputSchema: {
      type: 'object',
      properties: {
        start: { type: 'number', description: 'Start time in seconds (default: 0)' },
        end: { type: 'number', description: 'End time in seconds (default: end of video)' }
      }
    }
  },
  {
    name: 'screenmuse_thumbnail',
    description: 'Extract a still frame from a recording at a specific timestamp.',
    inputSchema: {
      type: 'object',
      properties: {
        time: { type: 'number', description: 'Timestamp in seconds (default: middle of video)' },
        scale: { type: 'integer', description: 'Max width in pixels (default: 800)' },
        format: { type: 'string', enum: ['jpeg', 'png'], description: 'Image format (default: jpeg)' }
      }
    }
  },
  {
    name: 'screenmuse_status',
    description: 'Get the current recording status — whether recording is active, elapsed time, chapters.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'screenmuse_timeline',
    description: 'Get the structured timeline of the current/last session: chapters, notes, and highlights.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'screenmuse_recordings',
    description: 'List all recordings in ~/Movies/ScreenMuse/ with file metadata.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'screenmuse_window_focus',
    description: 'Bring an application window to the front.',
    inputSchema: {
      type: 'object',
      required: ['app'],
      properties: { app: { type: 'string', description: 'App name (e.g. "Google Chrome") or bundle ID' } }
    }
  },
  {
    name: 'screenmuse_active_window',
    description: 'Get information about the currently focused window (app name, title, position, size).',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'screenmuse_clipboard',
    description: 'Get the current clipboard contents.',
    inputSchema: { type: 'object', properties: {} }
  },
  {
    name: 'screenmuse_running_apps',
    description: 'List all running applications with their names and bundle IDs.',
    inputSchema: { type: 'object', properties: {} }
  }
];

// ── Tool Execution ─────────────────────────────────────────────────────────

async function executeTool(name, args) {
  try {
    let result;

    switch (name) {
      case 'screenmuse_start':         result = await callScreenMuse('/start', args || {}); break;
      case 'screenmuse_stop':          result = await callScreenMuse('/stop', {}); break;
      case 'screenmuse_pause':         result = await callScreenMuse('/pause', {}); break;
      case 'screenmuse_resume':        result = await callScreenMuse('/resume', {}); break;
      case 'screenmuse_chapter':       result = await callScreenMuse('/chapter', { name: args.name }); break;
      case 'screenmuse_note':          result = await callScreenMuse('/note', { text: args.text }); break;
      case 'screenmuse_screenshot':    result = await callScreenMuse('/screenshot', {}); break;
      case 'screenmuse_ocr':           result = await callScreenMuse('/ocr', args || {}); break;
      case 'screenmuse_export':        result = await callScreenMuse('/export', args || {}); break;
      case 'screenmuse_trim':          result = await callScreenMuse('/trim', args || {}); break;
      case 'screenmuse_thumbnail':     result = await callScreenMuse('/thumbnail', args || {}); break;
      case 'screenmuse_status':        result = await callScreenMuse('/status', null); break;
      case 'screenmuse_timeline':      result = await callScreenMuse('/timeline', null); break;
      case 'screenmuse_recordings':    result = await callScreenMuse('/recordings', null); break;
      case 'screenmuse_window_focus':  result = await callScreenMuse('/window/focus', { app: args.app }); break;
      case 'screenmuse_active_window': result = await callScreenMuse('/system/active-window', null); break;
      case 'screenmuse_clipboard':     result = await callScreenMuse('/system/clipboard', null); break;
      case 'screenmuse_running_apps':  result = await callScreenMuse('/system/running-apps', null); break;
      default:
        return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true };
    }

    return {
      content: [{ type: 'text', text: JSON.stringify(result, null, 2) }]
    };
  } catch (err) {
    // ScreenMuse not running or unreachable
    const isConnectionError = err.code === 'ECONNREFUSED' || err.message?.includes('fetch');
    if (isConnectionError) {
      return {
        content: [{
          type: 'text',
          text: `ScreenMuse is not running. Launch ScreenMuse.app on your Mac, then try again.\n(Expected at ${BASE_URL})`
        }],
        isError: true
      };
    }
    return {
      content: [{ type: 'text', text: `Error: ${err.message}` }],
      isError: true
    };
  }
}

// ── MCP Message Loop ───────────────────────────────────────────────────────

let buffer = '';

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;

  while (true) {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd === -1) break;

    const headers = buffer.slice(0, headerEnd);
    const lengthMatch = headers.match(/Content-Length:\s*(\d+)/i);
    if (!lengthMatch) { buffer = buffer.slice(headerEnd + 4); continue; }

    const length = parseInt(lengthMatch[1]);
    const bodyStart = headerEnd + 4;
    if (buffer.length < bodyStart + length) break;

    const body = buffer.slice(bodyStart, bodyStart + length);
    buffer = buffer.slice(bodyStart + length);

    try {
      const msg = JSON.parse(body);
      handleMessage(msg);
    } catch (e) {
      // ignore malformed messages
    }
  }
});

async function handleMessage(msg) {
  const { id, method, params } = msg;

  if (method === 'initialize') {
    writeMessage({
      jsonrpc: '2.0', id,
      result: {
        protocolVersion: '2024-11-05',
        capabilities: { tools: {} },
        serverInfo: { name: 'screenmuse', version: '1.3.0' }
      }
    });
    return;
  }

  if (method === 'tools/list') {
    writeMessage({ jsonrpc: '2.0', id, result: { tools: TOOLS } });
    return;
  }

  if (method === 'tools/call') {
    const { name, arguments: args } = params;
    const result = await executeTool(name, args);
    writeMessage({ jsonrpc: '2.0', id, result });
    return;
  }

  if (method === 'notifications/initialized') return;
  if (method === 'ping') {
    writeMessage({ jsonrpc: '2.0', id, result: {} });
    return;
  }

  // Unknown method
  if (id !== undefined) {
    writeMessage({
      jsonrpc: '2.0', id,
      error: { code: -32601, message: `Method not found: ${method}` }
    });
  }
}

process.stdin.on('end', () => process.exit(0));
