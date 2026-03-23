# ScreenCaptureKit — WWDC Session Notes

Reference for ScreenMuse development. Extracted from Apple WWDC transcripts.

---

## WWDC22 10156 — "Meet ScreenCaptureKit"

### Key Frame Handling Rules (CRITICAL)

```swift
func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    // STEP 1: Always validate buffer
    guard sampleBuffer.isValid else { return }

    // STEP 2: Check frame status — THIS IS REQUIRED
    // .complete = new frame available
    // .idle = content unchanged, NO new IOSurface (still has pixel buffer but it's old)
    guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let attachments = attachmentsArray.first,
          let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
          let status = SCFrameStatus(rawValue: statusRawValue),
          status == .complete else { return }
    
    // STEP 3: Extract pixel buffer for video frames
    guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
    // ← use AVAssetWriterInputPixelBufferAdaptor.append(pixelBuffer, withPresentationTime:)
}
```

### SCContentFilter Types
- `.desktopIndependentWindow` — single window, follows across displays
- Display-based with included windows/apps
- Display-based with excluded apps (common: exclude self to avoid hall-of-mirrors)

### SCStreamConfiguration Properties
- `width`, `height` — output resolution in pixels
- `minimumFrameInterval` — `CMTime(value: 1, timescale: 60)` for 60fps
- `pixelFormat` — `kCVPixelFormatType_32BGRA` for display, YUV420 for encoding/streaming
- `capturesAudio` — enable system audio capture
- `sampleRate`, `channelCount` — audio config (48000, 2 for stereo)
- `showsCursor` — include cursor in frame output
- `queueDepth` — surface pool size (3–8, default 3, **recommended 5 for performance**)

### Audio Filtering
- Audio is always filtered at **app level** — you can't filter per-window
- Single window filter captures audio from the entire app that owns the window

### Starting the Stream
```swift
stream = SCStream(filter: filter, configuration: config, delegate: self)
try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoQueue)
try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
stream.startCapture()
```

---

## WWDC22 10155 — "Take ScreenCaptureKit to the Next Level"

### Per-Frame Metadata (from CMSampleBuffer attachments)

```swift
// Dirty rects — where new content is vs previous frame (for efficient encoding)
let dirtyRects = attachments[SCStreamFrameInfo.dirtyRects] as? [CGRect]

// Content rect — region of interest in the output frame
let contentRect = attachments[SCStreamFrameInfo.contentRect] as? [String: Any]

// Content scale — how much content was scaled to fit
let contentScale = attachments[SCStreamFrameInfo.contentScale] as? Double

// Scale factor — display's logical → physical pixel ratio
let scaleFactor = attachments[SCStreamFrameInfo.scaleFactor] as? Double
```

### Correct Display of Captured Content
1. Crop using `contentRect`
2. Scale up by dividing `contentScale`
3. Compare `scaleFactor` of source vs target display — if mismatch, scale accordingly

### queueDepth Rules (critical for performance)
- To avoid delayed frames: process each frame within `minimumFrameInterval`
- To avoid frame loss: release surfaces back to pool before `minimumFrameInterval × (queueDepth - 1)` expires
- **queueDepth = 5** recommended for streaming/recording use cases

### Live Stream Configuration Updates (no restart needed)
```swift
try await stream.updateConfiguration(newConfig)
try await stream.updateContentFilter(newFilter)
```

### Window Picker with Live Preview
- Create one `SCStream` per window with `desktopIndependentWindow` filter
- Thumbnail config: ~284×182, 5fps, BGRA, queueDepth=3, no cursor/audio
- ScreenCaptureKit handles many concurrent streams efficiently (GPU-backed)

### Single Window Capture Behavior
- Full window content always captured, even when occluded or off-screen
- Window moving to another display: still captured
- Window minimized: stream **pauses** and resumes on restore
- Child/popup windows: NOT included (use app-level filter if you want them)
- Output always offset at top-left corner

### Display-Based Filters
- `includeWindows`: only specified windows in output; new windows NOT auto-included
- `includeApplications`: all windows from app auto-included (including new/child windows)
- `excludeApplications`: all windows from app removed; new windows from excluded app also removed
- `exceptWindows`: cherry-pick windows back from an excluded app

---

## WWDC23 10136 — "What's New in ScreenCaptureKit"

### SCScreenshotManager (macOS 14+)
One-shot screenshot without creating an SCStream:

```swift
// CGImage output (easy to integrate with existing code)
let cgImage = try await SCScreenshotManager.captureImage(
    contentFilter: filter,
    configuration: config
)

// CMSampleBuffer output (more pixel format options)
let sampleBuffer = try await SCScreenshotManager.captureSampleBuffer(
    contentFilter: filter,
    configuration: config
)
```

- Uses same `SCContentFilter` + `SCStreamConfiguration` as streaming
- Fully async — returns when screenshot is ready
- Same filtering capabilities as live streaming
- CGWindowListCreateImage is now deprecated — migrate to this

### SCContentSharingPicker (macOS 14+)
System-level picker for stream content selection:

```swift
let picker = SCContentSharingPicker.shared
picker.add(self)  // add as observer
picker.isActive = true

// Present system picker
picker.present(for: stream, using: .multipleWindows)

// Delegate gets called with new SCContentFilter
func contentSharingPicker(_ picker: SCContentSharingPicker, 
                           didUpdateWith filter: SCContentFilter, 
                           for stream: SCStream?) {
    // Apply to running stream without restart
    try await stream?.updateContentFilter(filter)
}
```

Config per stream:
```swift
var config = SCContentSharingPickerConfiguration()
config.allowedPickingModes = [.singleWindow, .multipleWindows, .singleApplication]
config.excludedBundleIDs = ["com.myapp.capture"]  // exclude self
config.allowsRepicking = false  // lock stream content
picker.setConfiguration(config, for: stream)
```

### Presenter Overlay
- Auto-available when app uses ScreenCaptureKit + camera together
- Appear in Video menu bar
- Callback: `SCStreamDelegate.outputEffectDidStart(_:running:)`
- When overlay active: `AVCaptureSession` stops sending camera frames (camera goes to overlay)
- Optimize: hide camera tile in your UI, adjust A/V sync

---

## ScreenMuse Implementation Status vs WWDC Recommendations

| Feature | Status | Notes |
|---------|--------|-------|
| `sampleBuffer.isValid` check | ✅ `527f9e4` | |
| `SCFrameStatus.complete` check | ✅ `527f9e4` | Was the 0-byte bug root cause |
| `AVAssetWriterInputPixelBufferAdaptor` | ✅ `4905b90` | Production-verified pattern |
| `queueDepth = 5` | ✅ `527f9e4` | |
| `SCScreenshotManager` endpoint | ✅ `d3a3a8d` | `POST /screenshot`, macOS 14+ |
| Per-frame dirty rects | 🔜 | Future: efficient encoding |
| `updateConfiguration` (live quality adjust) | 🔜 | Future: dynamic quality |
| `SCContentSharingPicker` | 🔜 | Future: app picker integration |
| Presenter Overlay detection | 🔜 | Future: video conferencing |
| Window picker with live preview | 🔜 | Future: window selection UI |

---

## Deprecated APIs to Avoid
- `CGWindowListCreateImage` → use `SCScreenshotManager.captureImage`
- `CGDisplayStream` → use `SCStream`
- `CGWindowList` → use `SCShareableContent`
