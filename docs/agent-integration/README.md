# Agent Integration Documentation

Documentation for integrating ScreenMuse with AI agents, automation frameworks, and code agents.

## Contents

- **[AGENT-INTEGRATION.md](./AGENT-INTEGRATION.md)** - Complete integration guide for autonomous agents
- **[FOR-DEVELOPERS.md](./FOR-DEVELOPERS.md)** - Technical deep-dive into ScreenMuse HTTP API
- **[GETTING-STARTED.md](./GETTING-STARTED.md)** - Quick start for agent developers

## Overview

These docs were created by Vera, an autonomous AI agent, after successfully:
- Creating 4 autonomous screen recordings (100% success rate)
- Building quality validation systems
- Integrating Playwright + ScreenMuse
- Deploying demos to production

## Quick Start

```bash
# 1. Ensure ScreenMuse HTTP server is running
curl http://localhost:7823/status

# 2. Start recording
curl -X POST http://localhost:7823/start \
  -H "Content-Type: application/json" \
  -d '{"name":"my-recording","quality":"high"}'

# 3. Perform your automation (Playwright, Puppeteer, etc.)

# 4. Stop recording
curl -X POST http://localhost:7823/stop
```

## Key Features

✅ **HTTP API** - localhost:7823, no auth required  
✅ **Quality validation** - MB/s threshold checking  
✅ **Window-specific recording** - Target specific app windows  
✅ **Format export** - GIF and WebP conversion  
✅ **Playwright integration** - Full browser automation examples  

## Use Cases

- **Autonomous demo creation** - Let agents record workflows
- **QA automation** - Capture test runs automatically
- **Documentation** - Generate video tutorials from code
- **Bug reproduction** - Record issues as they happen
- **User research** - Capture actual user interactions

## Production Examples

See [Vera's demo videos](https://vera-space.pages.dev/screenmuse-demo/) - all created autonomously.

## Requirements

- macOS 14+ (ScreenCaptureKit)
- Screen Recording permission (one-time grant)
- ScreenMuse HTTP server running

## Support

- **Repository:** https://github.com/hnshah/screenmuse
- **Issues:** Report integration bugs with agent context
- **Contributing:** PRs welcome for agent-specific features

---

**Created:** 2026-03-29  
**Author:** Vera (autonomous AI agent)  
**Validation:** 4 production videos, 7.1 MB, 100% success rate
