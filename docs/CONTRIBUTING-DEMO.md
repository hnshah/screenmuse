# Generating the Hero GIF

The hero GIF in the README is generated from `docs/demo.tape` using [VHS](https://github.com/charmbracelet/vhs), a tool that turns tape scripts into terminal GIFs.

## Prerequisites

1. **macOS** with Screen Recording permission granted to ScreenMuse
2. **ScreenMuse server** running on `localhost:7823`
3. **VHS** installed:
   ```bash
   brew install vhs
   ```
   VHS also requires `ffmpeg` and `ttyd`, which Homebrew installs automatically.

## Generate the GIF

Start the server, then run the tape:

```bash
# Terminal 1 — start the server
./scripts/dev-run.sh

# Terminal 2 — generate the GIF
vhs docs/demo.tape
```

This produces `docs/demo.gif`.

## Preview and verify

Open the GIF to check it looks right:

```bash
open docs/demo.gif
```

You should see four curl commands executing in sequence: `/start`, `/chapter`, `/stop`, and `/export`, each with realistic JSON responses.

## Updating the tape

Edit `docs/demo.tape` to change the recording. The VHS tape syntax is straightforward:

- `Type "text"` — types text into the terminal
- `Type@50ms "text"` — types at a specific speed
- `Enter` — presses Enter
- `Sleep 2s` — pauses
- `Hide` / `Show` — hides/shows commands from the output

See the [VHS documentation](https://github.com/charmbracelet/vhs#vhs) for the full command reference.

## Activating the GIF in the README

Once you have a `docs/demo.gif` you are happy with, update `README.md` by replacing the code-block placeholder with the image tag:

```markdown
![ScreenMuse Demo](docs/demo.gif)
```

The HTML comments in the README mark exactly where to make this swap.

## Troubleshooting

**"connection refused" errors in the GIF output**
The server is not running. Start it with `./scripts/dev-run.sh` and wait for the `Listening on port 7823` message before running `vhs`.

**GIF is too large (>5 MB)**
Lower the framerate or dimensions in `demo.tape`:
```
Set Framerate 15
Set Width 900
Set Height 450
```

**Fonts look wrong**
VHS uses your system fonts. Install a monospace font like JetBrains Mono and add `Set FontFamily "JetBrains Mono"` to the tape file.
