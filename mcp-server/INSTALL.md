# Installing screenmuse-mcp

## Option 1: npx (no install needed)

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "screenmuse": {
      "command": "npx",
      "args": ["screenmuse-mcp"],
      "env": {
        "SCREENMUSE_API_KEY": "your-key-here"
      }
    }
  }
}
```

## Option 2: Global install

```bash
npm install -g screenmuse-mcp
screenmuse-mcp
```

## Option 3: Direct path (clone the repo)

```bash
git clone https://github.com/hnshah/screenmuse
node /path/to/screenmuse/mcp-server/screenmuse-mcp.js
```

## API Key

ScreenMuse auto-generates an API key on first launch. Find it at:
```bash
cat ~/.screenmuse/api_key
```

Set it in your MCP server config via `SCREENMUSE_API_KEY` env var.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SCREENMUSE_URL` | `http://localhost:7823` | ScreenMuse server URL |
| `SCREENMUSE_API_KEY` | (none) | API key (from `~/.screenmuse/api_key`) |
