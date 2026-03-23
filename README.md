# ScreenMuse

The most advanced macOS screen recorder, screenshot, and screencast tool.
Native Swift + ScreenCaptureKit + on-device AI (coming in Phase 3).

### Features (Phase 1)

- Full screen, window, region screenshots via ScreenCaptureKit
- Screen recording with system audio + mic
- Cursor position tracking for future AI zoom
- Clean SwiftUI interface

### How to build

```
git clone https://github.com/hnshah/screenmuse
cd screenmuse
open Package.swift  # Opens in Xcode
# Press Cmd+R to build and run
```

### Requirements

- macOS 13.0+
- Xcode 15+

### Tech Stack

- Swift 6.0 + SwiftUI
- ScreenCaptureKit (Apple native screen capture)
- AVFoundation (video encoding)
- Core ML (coming in Phase 3 for AI features)
