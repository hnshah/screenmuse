# ScreenMuse

The most advanced macOS screen recorder, screenshot, and screencast tool.
Native Swift + ScreenCaptureKit + on-device AI (coming in Phase 3).

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later

Note: macOS 14 is required because ScreenMuse uses `SCScreenshotManager`, which was introduced in macOS 14.

## How to Build

```bash
git clone https://github.com/hnshah/screenmuse
cd screenmuse
open Package.swift
```

Xcode will open the Swift Package. Press Cmd+R to build and run.

On first launch, macOS will prompt for screen recording permission. Grant it to enable capture features.

## Features (Phase 1 - Current)

- Full screen, window, and region screenshots via ScreenCaptureKit
- Screen recording to MP4 with system audio and microphone
- Cursor position and click tracking (foundation for Phase 2 AI zoom)
- Clean SwiftUI interface with Capture, Record, and History tabs
- Proper permissions handling for screen capture and microphone

## Planned Features

**Phase 2: Effects and Editing**
- Auto-zoom on click
- Cursor animations (smooth path, motion blur, click ripple)
- Timeline editor with trim and speed controls
- Real-time and post-recording annotations
- Scrolling screenshots
- Device frames (iPhone, Mac)

**Phase 3: AI Layer (on-device, private)**
- On-device transcription via Whisper (Core ML)
- Edit by transcript: delete words to cut video
- Filler word removal (um, uh, like)
- AI smart zoom based on cursor intent

**Phase 4: Polish and Sharing**
- MP4, GIF, WebP export
- Shareable links via Cloudflare R2
- Webcam overlay
- Background customization

## Tech Stack

- Swift 6.0 + SwiftUI
- ScreenCaptureKit (Apple native screen capture, macOS 14+)
- AVFoundation (H.264 video encoding, AAC audio)
- Core ML (coming in Phase 3)

## Architecture

```
ScreenMuse/
├── Sources/
│   ├── ScreenMuseApp/          # SwiftUI app target
│   │   ├── Views/              # CaptureView, RecordView, HistoryView
│   │   └── ViewModels/         # CaptureViewModel, RecordViewModel
│   └── ScreenMuseCore/         # Library (reusable core)
│       ├── Capture/            # ScreenshotManager
│       ├── Recording/          # RecordingManager, CursorTracker, RecordingConfig
│       └── Permissions/        # PermissionsManager
```

## Status

Phase 1 scaffold complete. All core APIs wired. Next: compile on macOS 14, iterate on build errors, then Phase 2 effects.
