# Security Model

## `/script` Endpoint

The `POST /script` endpoint is a **recording automation script runner**, not an arbitrary script execution engine. Despite the name, it does **not** execute AppleScript, shell commands, or `osascript`.

It accepts a JSON array of commands, each dispatched through a strict switch-case allowlist:

| Action      | Description                            |
|-------------|----------------------------------------|
| `start`     | Start a screen recording               |
| `stop`      | Stop the current recording             |
| `pause`     | Pause the current recording            |
| `resume`    | Resume a paused recording              |
| `chapter`   | Add a named chapter marker             |
| `note`      | Add a timestamped text annotation      |
| `highlight` | Flag the next click for visual effect  |
| `sleep`     | Wait for a specified number of seconds |

Any action not in this list is rejected with an error. String inputs (`name`, `text`, `window_title`) are validated to reject strings exceeding 500 characters or containing null bytes / control characters.

The `POST /script/batch` endpoint is identical in scope to `/script` — it accepts a named array of scripts, each of which follows the same command allowlist. It does not provide any additional execution surface.

**Exposure risk:** If port 7823 is reachable by untrusted clients without authentication, they could trigger screen recordings or export operations. They cannot execute arbitrary code on the host. Mitigations:
- Always run with `SCREENMUSE_API_KEY` set (enabled by default when a key is configured).
- Keep the server bound to `127.0.0.1` (the default) unless you have a specific need for network access.
- Never expose port 7823 directly to the internet.

## Authentication

All HTTP endpoints require an API key unless explicitly disabled.

- **`SCREENMUSE_API_KEY`** environment variable: set this to a secret string before launching ScreenMuse.
- **`~/.screenmuse/api_key`** file: alternative to the env var; the file contents are used as the key.
- **`SCREENMUSE_NO_AUTH=1`**: disables authentication entirely (development only).

Requests must include the key in the `X-ScreenMuse-Key` header. Requests without a valid key receive a `401 Unauthorized` response.

## Network Binding

By default, ScreenMuse binds to **`127.0.0.1` (localhost only)** on port `7823`. This means the API is not accessible from other machines on the network.

If you change the bind address to `0.0.0.0` or a network interface, ensure:
1. `SCREENMUSE_API_KEY` is set to a strong, random value.
2. A firewall or reverse proxy restricts access to trusted clients.

## Known Limitations

- **No TLS**: The HTTP server does not support HTTPS. For remote access, place it behind a TLS-terminating reverse proxy.
- **Single-user**: There is no multi-user or role-based access control. The API key grants full access to all endpoints.
- **Screen Recording permissions**: ScreenMuse requires macOS Screen Recording permission. This is a system-level grant, not per-endpoint.

## Reporting Vulnerabilities

If you discover a security vulnerability, please open a GitHub issue or contact the maintainers directly. Do not disclose vulnerabilities publicly before a fix is available.
