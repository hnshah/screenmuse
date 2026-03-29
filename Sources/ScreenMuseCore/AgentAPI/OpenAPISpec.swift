/// ScreenMuse OpenAPI 3.0 Specification
///
/// Stored as a raw JSON string — easier to validate and maintain than
/// nested Swift dictionary literals. Edit this file, validate with any
/// JSON linter (e.g. `python3 -m json.tool < OpenAPISpec.swift` won't work,
/// but paste the string into jsonlint.com or run `node -e "JSON.parse(...)"`).
///
/// Served at GET /openapi.
enum OpenAPISpec {
    static let json = """
    {
      "openapi": "3.0.3",
      "info": {
        "title": "ScreenMuse Agent API",
        "version": "1.5",
        "description": "macOS screen recorder REST API for AI agents and automation workflows. Pairs with Peekaboo for full capture + automation coverage.",
        "contact": { "url": "https://github.com/hnshah/screenmuse" },
        "license": { "name": "MIT" }
      },
      "servers": [
        { "url": "http://localhost:7823", "description": "Local ScreenMuse instance" }
      ],
      "paths": {
        "/start": {
          "post": {
            "summary": "Start recording",
            "description": "Start a screen recording session. Optionally record a specific window, region, or quality level.",
            "requestBody": {
              "content": {
                "application/json": {
                  "schema": {
                    "type": "object",
                    "properties": {
                      "name":         { "type": "string", "description": "Recording name/label" },
                      "quality":      { "type": "string", "enum": ["low","medium","high","max"], "default": "medium" },
                      "window_title": { "type": "string", "description": "Record a specific window by title" },
                      "window_pid":   { "type": "integer", "description": "Record a specific window by process ID" },
                      "region":       { "type": "object", "description": "Record a screen region", "properties": { "x": {"type":"number"}, "y": {"type":"number"}, "width": {"type":"number"}, "height": {"type":"number"} } },
                      "audio_source": { "type": "string", "description": "system (default), none, or app name for app-only audio" },
                      "webhook":      { "type": "string", "format": "uri", "description": "POST to this URL when recording stops" }
                    }
                  }
                }
              }
            },
            "responses": { "200": { "description": "Recording started" }, "409": { "description": "Already recording" } }
          }
        },
        "/stop": {
          "post": {
            "summary": "Stop recording",
            "description": "Stop the current recording and return the video file path.",
            "responses": { "200": { "description": "video_path, elapsed, metadata" }, "400": { "description": "Not recording" } }
          }
        },
        "/pause":   { "post": { "summary": "Pause current recording" } },
        "/resume":  { "post": { "summary": "Resume paused recording" } },
        "/chapter": {
          "post": {
            "summary": "Add chapter marker",
            "requestBody": { "content": { "application/json": { "schema": { "properties": { "name": { "type": "string" } }, "required": ["name"] } } } }
          }
        },
        "/note": {
          "post": {
            "summary": "Add timestamped annotation to the recording log",
            "requestBody": { "content": { "application/json": { "schema": { "properties": { "text": { "type": "string" } }, "required": ["text"] } } } }
          }
        },
        "/highlight": { "post": { "summary": "Flag next click for highlight effect" } },
        "/screenshot": { "post": { "summary": "Capture a full-screen screenshot", "description": "Returns the file path to the saved PNG." } },
        "/frame": { "post": { "summary": "Capture frame with recording context metadata" } },
        "/thumbnail": {
          "post": {
            "summary": "Extract still frame from video at timestamp",
            "requestBody": { "content": { "application/json": { "schema": { "properties": {
              "source": { "type": "string", "default": "last" },
              "time":   { "type": "number", "description": "Seconds (default: middle of video)" },
              "scale":  { "type": "integer", "default": 800 },
              "format": { "type": "string", "enum": ["jpeg","png"], "default": "jpeg" },
              "quality":{ "type": "integer", "minimum": 0, "maximum": 100, "default": 85 }
            } } } } }
          }
        },
        "/ocr": {
          "post": {
            "summary": "OCR the screen or an image file",
            "description": "Uses Apple Vision framework — no API key, no internet, runs locally. Returns full_text and bounding boxes.",
            "requestBody": { "content": { "application/json": { "schema": { "properties": {
              "source":         { "type": "string", "default": "screen", "description": "screen or absolute path to image" },
              "level":          { "type": "string", "enum": ["accurate","fast"], "default": "accurate" },
              "lang":           { "type": "string", "description": "Language hint e.g. en, ja" },
              "full_text_only": { "type": "boolean", "default": false }
            } } } } }
          }
        },
        "/export": {
          "post": {
            "summary": "Export recording as animated GIF or WebP",
            "requestBody": { "content": { "application/json": { "schema": { "properties": {
              "source": { "type": "string", "default": "last" },
              "format": { "type": "string", "enum": ["gif","webp"], "default": "gif" },
              "fps":    { "type": "integer", "default": 10 },
              "scale":  { "type": "integer", "default": 800 },
              "start":  { "type": "number" },
              "end":    { "type": "number" }
            } } } } }
          }
        },
        "/trim": {
          "post": {
            "summary": "Trim video to time range (stream copy — instant, no re-encode)",
            "requestBody": { "content": { "application/json": { "schema": { "properties": {
              "source": { "type": "string", "default": "last" },
              "start":  { "type": "number", "default": 0 },
              "end":    { "type": "number" }
            } } } } }
          }
        },
        "/speedramp": {
          "post": {
            "summary": "Auto-compress idle sections",
            "description": "Detects idle stretches (silence + no mouse movement) and speeds them up.",
            "requestBody": { "content": { "application/json": { "schema": { "properties": {
              "source":            { "type": "string", "default": "last" },
              "speed_factor":      { "type": "number", "default": 4 },
              "min_idle_seconds":  { "type": "number", "default": 2 }
            } } } } }
          }
        },
        "/crop": {
          "post": {
            "summary": "Crop a region from an existing recording",
            "requestBody": { "content": { "application/json": { "schema": {
              "required": ["region"],
              "properties": {
                "source":  { "type": "string", "default": "last" },
                "region":  { "type": "object", "required": ["width","height"], "properties": { "x": {"type":"number","default":0}, "y": {"type":"number","default":0}, "width": {"type":"number"}, "height": {"type":"number"} } },
                "quality": { "type": "string", "enum": ["low","medium","high","max"], "default": "medium" }
              }
            } } } }
          }
        },
        "/annotate": {
          "post": {
            "summary": "Burn text overlays into video at specific timestamps",
            "requestBody": { "content": { "application/json": { "schema": {
              "required": ["overlays"],
              "properties": {
                "source":   { "type": "string", "default": "last" },
                "overlays": { "type": "array", "items": { "type": "object", "required": ["text"], "properties": {
                  "text":             { "type": "string" },
                  "start":            { "type": "number", "default": 0 },
                  "end":              { "type": "number" },
                  "position":         { "type": "string", "enum": ["top","center","bottom"], "default": "bottom" },
                  "size":             { "type": "integer", "default": 32 },
                  "color":            { "type": "string", "default": "#FFFFFF" },
                  "background":       { "type": "string", "default": "#000000" },
                  "background_alpha": { "type": "number", "minimum": 0, "maximum": 1, "default": 0.6 }
                } } }
              }
            } } } }
          }
        },
        "/concat": {
          "post": {
            "summary": "Concatenate multiple recordings into one",
            "requestBody": { "content": { "application/json": { "schema": { "required": ["sources"], "properties": {
              "sources": { "type": "array", "items": { "type": "string" }, "description": "Array of video paths or 'last'" }
            } } } } }
          }
        },
        "/script": {
          "post": {
            "summary": "Run a batch sequence of ScreenMuse commands",
            "description": "Execute start/stop/pause/resume/chapter/note/highlight and sleep as a single API call.",
            "requestBody": { "content": { "application/json": { "schema": { "required": ["commands"], "properties": {
              "commands": { "type": "array", "items": { "type": "object", "properties": {
                "action": { "type": "string", "enum": ["start","stop","pause","resume","chapter","note","highlight"] },
                "sleep":  { "type": "number", "description": "Wait N seconds (no action key needed)" },
                "name":   { "type": "string" },
                "text":   { "type": "string" }
              } } }
            } } } } },
            "responses": {
              "200": { "description": "All steps completed successfully", "content": { "application/json": { "schema": { "type": "object", "properties": {
                "ok":        { "type": "boolean" },
                "steps_run": { "type": "integer" },
                "steps":     { "type": "array", "items": { "type": "object" } },
                "error":     { "type": "string", "nullable": true }
              } } } } },
              "400": { "description": "Invalid request (empty or missing commands array)" },
              "500": { "description": "A step failed during execution" }
            }
          }
        },
        "/upload/icloud": {
          "post": {
            "summary": "Upload recording to iCloud Drive",
            "requestBody": { "content": { "application/json": { "schema": { "properties": { "source": { "type": "string", "default": "last" } } } } } }
          }
        },
        "/start/pip": { "post": { "summary": "Start picture-in-picture dual-window recording" } },
        "/window/focus": {
          "post": {
            "summary": "Bring an application window to the front",
            "requestBody": { "content": { "application/json": { "schema": { "required": ["app"], "properties": { "app": { "type": "string", "description": "App name or bundle ID" } } } } } }
          }
        },
        "/window/position": { "post": { "summary": "Set window position and size" } },
        "/window/hide-others": { "post": { "summary": "Hide all windows except one app" } },
        "/timeline": { "get": { "summary": "Get structured session timeline", "description": "Returns chapters, notes, and highlights as structured JSON." } },
        "/recordings": { "get": { "summary": "List all recordings in ~/Movies/ScreenMuse/ with metadata" } },
        "/recording":  { "delete": { "summary": "Delete a recording by filename or absolute path" } },
        "/stream": {
          "get": {
            "summary": "SSE live frame stream",
            "description": "Server-Sent Events stream. Each event contains a base64-encoded JPEG frame.",
            "parameters": [
              { "name": "fps",    "in": "query", "schema": { "type": "integer", "default": 2 } },
              { "name": "scale",  "in": "query", "schema": { "type": "integer", "default": 1280 } },
              { "name": "format", "in": "query", "schema": { "type": "string",  "default": "jpeg" } },
              { "name": "quality","in": "query", "schema": { "type": "integer", "default": 80 } }
            ]
          }
        },
        "/stream/status":          { "get": { "summary": "SSE stream health — active clients and frames sent" } },
        "/system/clipboard":       { "get": { "summary": "Get current clipboard contents" } },
        "/system/active-window":   { "get": { "summary": "Get frontmost window info (app, title, bounds)" } },
        "/system/running-apps":    { "get": { "summary": "List all running applications with names and bundle IDs" } },
        "/status":    { "get": { "summary": "Current recording state, elapsed time, chapters" } },
        "/windows":   { "get": { "summary": "List all on-screen windows" } },
        "/logs":      { "get": { "summary": "Query recent log entries from the ring buffer", "parameters": [
          { "name": "limit",    "in": "query", "schema": { "type": "integer", "default": 200 } },
          { "name": "level",    "in": "query", "schema": { "type": "string", "enum": ["debug","info","warning","error"] } },
          { "name": "category", "in": "query", "schema": { "type": "string" } }
        ] } },
        "/report":  { "get": { "summary": "Human-readable session report with usage timeline and warnings" } },
        "/version": { "get": { "summary": "Server version, build info, and full endpoint list" } },
        "/openapi": { "get": { "summary": "This OpenAPI 3.0 specification" } },
        "/health":  { "get": { "summary": "Liveness probe — listener state, version, permissions. No auth required. Returns {ok, listener, port, permissions, warning?}.", "security": [] } },
        "/debug":   { "get": { "summary": "Internal debug snapshot — request count, session state, job queue, log buffer size" } },
        "/record":  {
          "post": {
            "summary": "Start recording and stop after a fixed duration",
            "description": "Convenience endpoint: starts recording, waits for duration, stops, returns result.",
            "requestBody": { "content": { "application/json": { "schema": {
              "properties": {
                "duration": { "type": "number", "description": "Recording duration in seconds (required)" },
                "name": { "type": "string" },
                "quality": { "type": "string", "enum": ["low", "medium", "high", "max"] }
              },
              "required": ["duration"]
            } } } }
          }
        },
        "/frames": {
          "post": {
            "summary": "Extract multiple frames from a video at regular intervals",
            "requestBody": { "content": { "application/json": { "schema": {
              "properties": {
                "source": { "type": "string", "description": "Video path or 'last'" },
                "count":  { "type": "integer", "default": 10 },
                "format": { "type": "string", "enum": ["jpeg", "png"], "default": "jpeg" },
                "scale":  { "type": "integer", "default": 1280 }
              }
            } } } }
          }
        },
        "/validate": {
          "post": {
            "summary": "Validate a video file — check for real content vs black/empty recording",
            "requestBody": { "content": { "application/json": { "schema": {
              "required": ["checks"],
              "properties": {
                "source": { "type": "string", "description": "Video path or 'last'", "default": "last" },
                "checks": { "type": "array", "description": "Non-empty array of validation checks to run", "items": { "type": "object", "required": ["type"], "properties": {
                  "type":     { "type": "string", "enum": ["duration", "frame_count", "no_black_frames", "text_at"], "description": "Check type" },
                  "min":      { "type": "number", "description": "Minimum value (for duration, frame_count)" },
                  "max":      { "type": "number", "description": "Maximum value (for duration)" },
                  "time":     { "type": "number", "description": "Timestamp in seconds (for text_at)" },
                  "expected": { "type": "string", "description": "Expected text to find (for text_at)" }
                } } }
              }
            } } } }
          }
        },
        "/script/batch": {
          "post": {
            "summary": "Run multiple named scripts in sequence",
            "requestBody": { "content": { "application/json": { "schema": {
              "required": ["scripts"],
              "properties": {
                "scripts": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "name": { "type": "string" },
                      "commands": { "type": "array", "items": { "type": "object" } }
                    }
                  }
                },
                "continue_on_error": { "type": "boolean", "default": false }
              }
            } } } },
            "responses": {
              "200": { "description": "All scripts completed successfully", "content": { "application/json": { "schema": { "type": "object", "properties": {
                "ok":          { "type": "boolean" },
                "scripts_run": { "type": "integer" },
                "scripts":     { "type": "array", "items": { "type": "object" } }
              } } } } },
              "400": { "description": "Invalid request (empty or missing scripts array)" },
              "500": { "description": "One or more scripts failed during execution" }
            }
          }
        },
        "/sessions": { "get": { "summary": "List all named recording sessions with metadata" } },
        "/jobs": { "get": { "summary": "List all background async jobs and their status" } }
      }
    }
    """
}
