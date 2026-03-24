# Agent Features Plan — ScreenMuse

*Planned: 2026-03-24 | Status: designing*

Three features that make ScreenMuse genuinely useful for agents operating autonomously.
Ordered by build priority. Each is self-contained and testable independently.

---

## Feature 1: GIF / WebP Export (`POST /export`)

### Why
Agents producing demos almost always want a shareable, embeddable artifact — not just an MP4.
A GIF drops into a PR comment, a tweet, a Notion doc, a Slack message with zero friction.
An MP4 needs a player. A GIF just plays.

### API Contract

```
POST /export
Content-Type: application/json

{
  // Required: which video to export
  "source": "last"                  // "last" = lastVideoURL, or absolute path

  // Optional: format (default gif)
  "format": "gif" | "webp" | "mp4"

  // Optional: output quality / size
  "fps": 10,                        // default 10 for gif, 24 for webp/mp4
  "scale": 800,                     // max width in px (height auto, preserves AR)
  "quality": "medium"               // low / medium / high (affects palette/quantization)

  // Optional: time range (trim at export time)
  "start": 0.0,                     // seconds, default 0
  "end": null,                      // seconds, default = full duration

  // Optional: output path
  "output": "/path/to/out.gif"      // default = same dir as source, auto-named
}
```

Response (200):
```json
{
  "path": "/Users/Vera/Movies/ScreenMuse/recording.gif",
  "format": "gif",
  "size": 2457600,
  "size_mb": 2.34,
  "width": 800,
  "height": 600,
  "duration": 12.5,
  "fps": 10,
  "frames": 125
}
```

Error responses:
- 400: `{"error": "unsupported format", "code": "UNSUPPORTED_FORMAT", "supported": ["gif", "webp", "mp4"]}`
- 404: `{"error": "no video available", "code": "NO_VIDEO", "suggestion": "Record something first, or pass 'source' with a file path"}`
- 500: `{"error": "export failed: ...", "code": "EXPORT_FAILED"}`

### Implementation Plan

**GIF path (primary):**
1. Load source video with `AVAsset`
2. Use `AVAssetImageGenerator` to extract frames at the target FPS (e.g. 1 frame per 100ms for 10fps)
3. Downscale each `CGImage` to `scale` width using `CIImage` + `CILanczosScaleTransform`
4. Build animated GIF using `CGImageDestination` with `kUTTypeGIF` + per-frame delay metadata
5. Save and return path

**WebP path:**
- Same frame extraction as GIF
- Use `CGImageDestination` with `kUTTypeWebP` (macOS 14+ supports WebP natively)
- WebP is ~30% smaller than GIF at same quality

**Key implementation detail — GIF palette:**
- Use `kCGImagePropertyGIFDictionary` / `kCGImagePropertyGIFDelayTime` per frame
- For quality=high: 256 colors, no dithering reduction
- For quality=medium: 256 colors (default)
- For quality=low: 128 colors (smaller file)

**New file:** `Sources/ScreenMuseCore/Export/GIFExporter.swift`

```swift
public final class GIFExporter {
    public struct Config {
        public var fps: Int = 10
        public var scale: Int = 800
        public var quality: Quality = .medium
        public var timeRange: ClosedRange<Double>? = nil  // nil = full video
        public enum Quality { case low, medium, high }
    }

    public func export(sourceURL: URL, outputURL: URL, config: Config,
                       progress: ((Double) -> Void)? = nil) async throws -> ExportResult
}
```

**Wire to ScreenMuseServer:** new `case ("POST", "/export"):` handler

**Storage:** output goes to `~/Movies/ScreenMuse/Exports/` by default

### Test Cases for Vera
1. `curl -X POST localhost:7823/export -d '{}'` — exports last recording as GIF at defaults
2. `curl -X POST localhost:7823/export -d '{"fps":5,"scale":640}'` — smaller, faster GIF
3. `curl -X POST localhost:7823/export -d '{"format":"webp","quality":"high"}'`
4. `curl -X POST localhost:7823/export -d '{"start":2.5,"end":15.0}'` — trimmed GIF
5. `curl -X POST localhost:7823/export -d '{"source":"/path/to/specific.mp4"}'`
6. Verify GIF plays correctly in browser / Finder preview
7. Verify no-recording-yet returns 404 with helpful message

---

## Feature 2: Trim (`POST /trim`)

### Why
Every demo recording has dead time: the 3 seconds before you start, the pause after you
finish typing. Agents can't fix that today without leaving the API. Trim lets them cut
the final video to exactly what they want — one curl command.

### API Contract

```
POST /trim
Content-Type: application/json

{
  // Required: time range
  "start": 3.5,         // seconds from beginning (default 0)
  "end": 45.0,          // seconds from beginning (default = full duration)

  // Optional: which video (default = last recording)
  "source": "last" | "/absolute/path.mp4",

  // Optional: output path (default = source + ".trimmed.mp4" in same dir)
  "output": "/path/to/trimmed.mp4",

  // Optional: re-encode or stream copy
  "reencode": false     // false = fast stream copy (no quality loss), true = re-encode
}
```

Response (200):
```json
{
  "path": "/Users/Vera/Movies/ScreenMuse/recording.trimmed.mp4",
  "original_duration": 58.4,
  "trimmed_duration": 41.5,
  "start": 3.5,
  "end": 45.0,
  "size": 18874368,
  "size_mb": 18.0
}
```

Error responses:
- 400: `{"error": "start must be < end", "code": "INVALID_RANGE"}`
- 400: `{"error": "end (60.0) exceeds video duration (45.2)", "code": "OUT_OF_RANGE", "duration": 45.2}`
- 404: `{"error": "no video available", "code": "NO_VIDEO"}`

### Implementation Plan

**Fast path (stream copy — default, `reencode: false`):**
- Use `AVAssetExportSession` with `AVAssetExportPresetPassthrough`
- Set `export.timeRange = CMTimeRange(start: startCMTime, duration: durationCMTime)`
- Passthrough = no re-encode, near-instantaneous, zero quality loss
- Caveat: for H.264, the trim point snaps to the nearest keyframe. Vera should know this.

**Re-encode path (`reencode: true`):**
- Use `AVAssetExportSession` with `AVAssetExportPresetHighestQuality`
- Same time range — but this re-encodes, so it's frame-accurate and slower

**New file:** `Sources/ScreenMuseCore/Export/VideoTrimmer.swift`

```swift
public final class VideoTrimmer {
    public struct Config {
        public var start: Double     // seconds
        public var end: Double?      // nil = end of video
        public var reencode: Bool = false
    }

    public func trim(sourceURL: URL, outputURL: URL, config: Config,
                     progress: ((Double) -> Void)? = nil) async throws -> TrimResult
}
```

**Wire to ScreenMuseServer:** new `case ("POST", "/trim"):` handler

**Important edge case — trim after effects:**
The `lastVideoURL` on `ScreenMuseServer` points to the effects-composited video (the `.processed.mp4`).
Trim should operate on THAT file (the final output), not the raw recording.

### Test Cases for Vera
1. `curl -X POST localhost:7823/trim -d '{"start":3,"end":30}'`
2. `curl -X POST localhost:7823/trim -d '{"start":0,"end":10}'` — first 10 seconds
3. `curl -X POST localhost:7823/trim -d '{"start":5}'` — trim only the beginning
4. `curl -X POST localhost:7823/trim -d '{"end":20}'` — trim only the end
5. `curl -X POST localhost:7823/trim -d '{"start":5,"end":4}'` — should return 400
6. `curl -X POST localhost:7823/trim -d '{"end":9999}'` — out of range, should return 400
7. Verify trimmed file duration with ffprobe
8. Verify trim on a paused/resumed recording (multiple segments)

---

## Feature 3: Speed Ramp (`POST /speedramp`)

### Why
A 5-minute typing demo has a lot of slow moments. Speed ramp automatically finds idle
stretches (no cursor movement, no keystrokes) and speeds them up — making the video
watchable without any manual editing. The result feels like a professional screen recording,
not a raw capture.

This is the one feature that can't be done manually without a video editor. It's where the
agent data (cursor events, keystroke events captured during recording) actually pays off.

### API Contract

```
POST /speedramp
Content-Type: application/json

{
  // Optional: which video
  "source": "last" | "/path/to.mp4",

  // Optional: speed settings
  "idle_threshold_sec": 2.0,    // stretches of inactivity longer than this get ramped
                                // default 2.0s
  "idle_speed": 4.0,            // multiplier for idle sections (default 4x)
  "active_speed": 1.0,          // multiplier for active sections (default 1x, no change)

  // Optional: transition
  "ramp_duration": 0.3,         // seconds to ease in/out of speed change (default 0.3s)

  // Optional: output
  "output": "/path/to/ramped.mp4"
}
```

Response (200):
```json
{
  "path": "/Users/Vera/Movies/ScreenMuse/recording.ramped.mp4",
  "original_duration": 312.0,
  "output_duration": 87.4,
  "compression_ratio": 3.57,
  "idle_sections": 8,
  "idle_total_seconds": 224.6,
  "active_sections": 9,
  "active_total_seconds": 87.4
}
```

### Implementation Plan

**Activity detection (uses agent event data):**
The `RecordingManager` / `CursorTracker` / `KeyboardMonitor` capture events during recording.
The `ScreenMuseServer` has access to `coordinator` (RecordViewModel) which holds these event streams.

When `/speedramp` is called on `lastVideoURL`, we:
1. Query the event timeline from `RecordViewModel`: cursor positions + keystroke timestamps
2. Segment the timeline into `active` (events present) and `idle` (no events for > threshold) windows
3. If no agent event data available (e.g. externally provided video): use audio energy as a proxy
   (analyze audio amplitude — silence = idle)

**Video time-mapping with AVFoundation:**
- `AVMutableComposition` with `scaleTimeRange(_:toDuration:)` to compress idle sections
- Each idle section: `composition.scaleTimeRange(idleRange, toDuration: idleRange.duration / idleSpeed)`
- This modifies the composition timeline without re-encoding the video track
- Then export with `AVAssetExportPresetHighestQuality`

**Transition ramping:**
- At the boundary of each speed change, insert a short `ramp_duration` section that linearly interpolates speed
- Implemented via multiple small `scaleTimeRange` calls on the ramp window, each slightly different speed
- Creates a smooth acceleration/deceleration feel instead of a jarring jump cut

**New files:**
- `Sources/ScreenMuseCore/Export/SpeedRamper.swift` — the composition + export logic
- `Sources/ScreenMuseCore/Export/ActivityAnalyzer.swift` — event → active/idle segmentation

```swift
public final class ActivityAnalyzer {
    public struct Segment {
        public let start: Double     // seconds
        public let end: Double
        public let isIdle: Bool
    }

    // From agent event data
    public func analyze(cursorEvents: [CursorEvent], keystrokeEvents: [KeystrokeEvent],
                        duration: Double, idleThreshold: Double) -> [Segment]

    // Fallback: audio energy analysis
    public func analyzeFromAudio(asset: AVAsset, idleThreshold: Double) async throws -> [Segment]
}

public final class SpeedRamper {
    public struct Config {
        public var idleThresholdSec: Double = 2.0
        public var idleSpeed: Double = 4.0
        public var activeSpeed: Double = 1.0
        public var rampDuration: Double = 0.3
    }

    public func ramp(sourceURL: URL, outputURL: URL, segments: [ActivityAnalyzer.Segment],
                     config: Config, progress: ((Double) -> Void)? = nil) async throws -> SpeedRampResult
}
```

**Wire to ScreenMuseServer:** new `case ("POST", "/speedramp"):` handler
- Pass `coordinator?.lastEventData` (cursor + keystroke events) to `ActivityAnalyzer`
- If no event data → fallback to audio analysis

### Test Cases for Vera
1. `curl -X POST localhost:7823/speedramp` — default settings on last recording
2. `curl -X POST localhost:7823/speedramp -d '{"idle_speed":8.0}'` — more aggressive
3. `curl -X POST localhost:7823/speedramp -d '{"idle_threshold_sec":0.5}'` — speed up shorter pauses
4. `curl -X POST localhost:7823/speedramp -d '{"idle_speed":1.0}'` — noop, verify original duration preserved
5. Record a 2-min typing demo with deliberate pauses, verify output duration is < 60s
6. Verify output video plays smoothly (no jarring speed jumps)
7. Verify `idle_sections` count matches observed pauses in the recording

---

## Build Order

| # | Feature | New Files | API Endpoint | Est. Complexity |
|---|---------|-----------|--------------|-----------------|
| 1 | **GIF/WebP Export** | `GIFExporter.swift` | `POST /export` | Medium — CGImageDestination API is straightforward |
| 2 | **Trim** | `VideoTrimmer.swift` | `POST /trim` | Low — AVAssetExportSession passthrough is 30 lines |
| 3 | **Speed Ramp** | `SpeedRamper.swift` + `ActivityAnalyzer.swift` | `POST /speedramp` | High — composition time mapping + event analysis |

**Rationale for this order:**
- Trim is architecturally simplest but built second because GIF is higher agent value
- Speed ramp is last because it depends on the event data pipeline being solid
- Each is independently shippable and testable by Vera

---

## Shared Infrastructure Needed

All three features share a common pattern. Before building #1, create:

**`Sources/ScreenMuseCore/Export/ExportHelpers.swift`**
```swift
/// Resolve "last" | "/path/to/file.mp4" → URL, with error if not found
func resolveSourceVideo(source: String?, lastVideoURL: URL?) throws -> URL

/// Build output URL for an export operation (auto-named in ~/Movies/ScreenMuse/Exports/)  
func buildOutputURL(source: URL, suffix: String, ext: String) -> URL

/// Load AVAsset and verify it has a video track, return duration
func loadVideoAsset(url: URL) async throws -> (AVAsset, Double)
```

This avoids copy-pasting the same resolution + error handling across all three endpoints.

---

*Next step: build Feature 1 (GIF Export). Trim and Speed Ramp follow in sequence.*
