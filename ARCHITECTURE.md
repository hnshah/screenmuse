# ScreenMuse Architecture

**Version:** 1.0  
**Last Updated:** 2026-03-27  
**Language:** Swift 6  
**Platform:** macOS 14+ (Sonoma)

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Core Components](#core-components)
3. [Data Flow](#data-flow)
4. [Design Decisions](#design-decisions)
5. [Extension Points](#extension-points)
6. [Performance Characteristics](#performance-characteristics)
7. [Security & Permissions](#security--permissions)

---

## System Overview

ScreenMuse is a native macOS screen recorder built for AI agent control. Unlike traditional screen recorders designed for human interaction, ScreenMuse exposes a local HTTP API that allows autonomous agents to programmatically record, edit, and export screen content.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         ScreenMuse App                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐ │
│  │   HTTP API   │      │   SwiftUI    │      │   AppKit     │ │
│  │   Server     │◄────►│   Views      │◄────►│   Delegates  │ │
│  │  (Port 7823) │      │              │      │              │ │
│  └──────┬───────┘      └──────────────┘      └──────────────┘ │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │                  Core Recording Engine                    │ │
│  ├──────────────────────────────────────────────────────────┤ │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────────────┐ │ │
│  │  │ Recording  │  │  Timeline  │  │  Window            │ │ │
│  │  │ Manager    │  │  Manager   │  │  Manager           │ │ │
│  │  └─────┬──────┘  └─────┬──────┘  └─────┬──────────────┘ │ │
│  │        │                │                │                │ │
│  │        ▼                ▼                ▼                │ │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────────────┐ │ │
│  │  │ Capture    │  │  Effects   │  │  OCR               │ │ │
│  │  │ Engine     │  │  Engine    │  │  Engine            │ │ │
│  │  └─────┬──────┘  └─────┬──────┘  └─────┬──────────────┘ │ │
│  └────────┼────────────────┼────────────────┼────────────────┘ │
│           │                │                │                  │
│           ▼                ▼                ▼                  │
├───────────────────────────────────────────────────────────────┤
│                    macOS System Frameworks                     │
├───────────────────────────────────────────────────────────────┤
│  ┌────────────────┐  ┌──────────┐  ┌─────────┐  ┌─────────┐ │
│  │ScreenCaptureKit│  │  Metal   │  │ Vision  │  │ AppKit  │ │
│  └────────────────┘  └──────────┘  └─────────┘  └─────────┘ │
│  ┌────────────────┐  ┌──────────┐                            │
│  │  AVFoundation  │  │  Network │                            │
│  └────────────────┘  └──────────┘                            │
└─────────────────────────────────────────────────────────────────┘

External Dependencies: ZERO ✅
```

### Key Characteristics

- **Zero External Dependencies** - Only native macOS frameworks
- **Agent-First API** - Designed for programmatic control
- **GPU Accelerated** - Metal for effects and compositing
- **Native Performance** - Swift 6 with structured concurrency
- **Minimal UI** - Focus on API over interface

---

## Core Components

### 1. HTTP API Server

**Location:** `Sources/ScreenMuseCore/HTTPServer.swift`  
**Port:** 7823 (configurable)  
**Protocol:** HTTP/1.1 with JSON payloads

**Responsibilities:**
- Accept agent control commands
- Route requests to appropriate managers
- Return JSON responses
- Stream frames via Server-Sent Events (SSE)
- Handle authentication (optional)

**Endpoints (40+):**
```swift
// Recording Control
POST   /start              // Start recording
POST   /stop               // Stop and save
POST   /pause              // Pause recording
POST   /resume             // Resume recording
GET    /status             // Current state

// Timeline Management
POST   /chapter            // Add chapter marker
POST   /highlight          // Mark highlight
POST   /note               // Add note

// Window Control
POST   /window/focus       // Focus application
POST   /window/position    // Set window bounds
POST   /window/hide-others // Hide other windows

// Export
POST   /export/gif         // Export as GIF
POST   /export/webp        // Export as WebP
POST   /export/trim        // Trim video
POST   /export/crop        // Crop video

// OCR
POST   /ocr/screen         // OCR screen region
POST   /ocr/file           // OCR image file

// Streaming
GET    /stream             // SSE frame stream

// Metadata
GET    /version            // Version info
GET    /openapi            // OpenAPI spec
```

**Design Pattern:** Request-response with async handlers

```swift
actor HTTPServer {
    private var requestHandlers: [String: (Request) async throws -> Response]
    
    func registerHandler(path: String, handler: @escaping (Request) async throws -> Response) {
        requestHandlers[path] = handler
    }
    
    func handleRequest(_ request: Request) async throws -> Response {
        guard let handler = requestHandlers[request.path] else {
            return Response(status: 404, body: ["error": "Not found"])
        }
        return try await handler(request)
    }
}
```

---

### 2. Recording Manager

**Location:** `Sources/ScreenMuseCore/RecordingManager.swift`  
**Concurrency:** Actor-isolated for thread safety

**Responsibilities:**
- Manage recording lifecycle (start/stop/pause/resume)
- Configure capture parameters
- Track recording state
- Coordinate with capture engine
- Handle errors and recovery

**State Machine:**
```
┌─────────┐
│  Idle   │
└────┬────┘
     │ start()
     ▼
┌─────────┐     pause()      ┌─────────┐
│Recording├───────────────────►│ Paused  │
└────┬────┘◄───────────────────┴─────────┘
     │          resume()
     │ stop()
     ▼
┌─────────┐
│  Idle   │
└─────────┘
```

**Key Properties:**
```swift
actor RecordingManager {
    private(set) var isRecording: Bool = false
    private(set) var isPaused: Bool = false
    private(set) var currentSession: RecordingSession?
    private(set) var elapsedTime: Double = 0
    
    private var captureEngine: CaptureEngine
    private var timelineManager: TimelineManager
    private var recordingStartTime: Date?
}
```

**Error Handling:**
```swift
enum RecordingError: Error {
    case alreadyRecording
    case notRecording
    case notPaused
    case captureDeviceUnavailable
    case permissionDenied
    case diskSpaceInsufficient
}
```

---

### 3. Capture Engine

**Location:** `Sources/ScreenMuseCore/CaptureEngine.swift`  
**Framework:** ScreenCaptureKit (macOS 14+)

**Responsibilities:**
- Interface with ScreenCaptureKit
- Configure video/audio capture
- Handle frame capture and encoding
- Manage capture session lifecycle
- Apply real-time effects

**Capture Pipeline:**
```
Screen → ScreenCaptureKit → CVPixelBuffer → Effects → H.264 Encoder → MP4 File
  ▲                              │              │           │
  │                              │              │           └─► AVAssetWriter
  │                              │              │
  └──────────────────────────────┴──────────────┴─────────────► Streaming
```

**Configuration:**
```swift
struct CaptureConfig {
    let resolution: CGSize           // Output resolution
    let frameRate: Int               // Target FPS (30/60)
    let region: CaptureRegion        // Full screen, window, or rect
    let audioSource: AudioSource     // System audio, mic, or both
    let cursor: Bool                 // Include cursor
    let clicks: Bool                 // Show click effects
}

enum CaptureRegion {
    case fullScreen
    case mainScreen
    case window(bundleID: String)
    case rect(CGRect)
}
```

**Hardware Acceleration:**
- **Encoding:** Apple VideoToolbox (H.264/HEVC)
- **Effects:** Metal GPU shaders
- **Compositing:** Metal Performance Shaders

---

### 4. Effects Engine

**Location:** `Sources/ScreenMuseCore/EffectsEngine.swift`  
**Framework:** Metal

**Responsibilities:**
- Render click effects
- Apply zoom animations
- Draw cursor trails
- Composite effects onto frames
- Execute Metal shaders

**Metal Pipeline:**
```
Input Frame → Vertex Shader → Rasterization → Fragment Shader → Output Frame
                                                      │
                                                      ├─► Click effect
                                                      ├─► Zoom effect
                                                      └─► Cursor trail
```

**Effect Types:**

1. **Click Effect**
   - Circular ripple animation
   - Configurable color and size
   - 0.5s duration (15 frames @ 30fps)
   - GPU-rendered via Metal

2. **Zoom Effect**
   - Smooth interpolation
   - Easing functions (linear, easeIn, easeOut, easeInOut)
   - Dynamic region calculation
   - Frame-accurate positioning

3. **Cursor Trail**
   - Path tracking
   - Velocity-based coloring
   - Fade-out animation
   - Optional motion blur

**Shader Example:**
```metal
// Click effect fragment shader
fragment float4 clickEffectShader(
    VertexOut in [[stage_in]],
    texture2d<float> baseTexture [[texture(0)]],
    constant ClickParams &params [[buffer(0)]]
) {
    float2 uv = in.texCoord;
    float4 baseColor = baseTexture.sample(sampler, uv);
    
    float2 center = params.position;
    float dist = distance(uv, center);
    
    // Animated ripple
    float ripple = sin(dist * 20.0 - params.time * 10.0);
    float alpha = smoothstep(params.radius, 0.0, dist) * ripple;
    
    float4 effectColor = float4(params.color.rgb, alpha);
    return mix(baseColor, effectColor, alpha);
}
```

---

### 5. Timeline Manager

**Location:** `Sources/ScreenMuseCore/TimelineManager.swift`  
**Storage:** In-memory during recording, exported to JSON

**Responsibilities:**
- Track chapters (named sections)
- Mark highlights (key moments)
- Store notes (annotations)
- Export timeline metadata
- Import timeline from JSON

**Data Structure:**
```swift
struct Timeline: Codable {
    var chapters: [Chapter] = []
    var highlights: [Highlight] = []
    var notes: [Note] = []
    
    struct Chapter: Codable, Identifiable {
        let id: UUID
        var name: String
        let timestamp: Double  // Seconds from start
    }
    
    struct Highlight: Codable, Identifiable {
        let id: UUID
        let timestamp: Double
        var note: String?
    }
    
    struct Note: Codable, Identifiable {
        let id: UUID
        var text: String
        let timestamp: Double
    }
}
```

**JSON Export Format:**
```json
{
  "chapters": [
    {"id": "uuid", "name": "Introduction", "timestamp": 5.0},
    {"id": "uuid", "name": "Main Demo", "timestamp": 30.0}
  ],
  "highlights": [
    {"id": "uuid", "timestamp": 15.0, "note": "Key moment"}
  ],
  "notes": [
    {"id": "uuid", "text": "Remember to edit this", "timestamp": 45.0}
  ]
}
```

---

### 6. Window Manager

**Location:** `Sources/ScreenMuseCore/WindowManager.swift`  
**Framework:** AppKit + Accessibility APIs

**Responsibilities:**
- Focus applications
- Position windows
- Hide/show applications
- Detect active window
- List running apps

**Accessibility Requirement:**
- Requires Accessibility permission for window manipulation
- Falls back to basic operations without permission
- User prompted on first use

**Example Operations:**
```swift
actor WindowManager {
    // Focus an application
    func focusWindow(app: String) async throws {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
        
        guard let targetApp = apps.first(where: { $0.localizedName == app }) else {
            throw WindowError.appNotFound
        }
        
        targetApp.activate()
    }
    
    // Position a window
    func positionWindow(app: String, bounds: CGRect) async throws {
        // Requires Accessibility permission
        guard AXIsProcessTrusted() else {
            throw WindowError.accessibilityPermissionRequired
        }
        
        // Use AXUIElement to set window frame
        // ... (Accessibility API calls)
    }
}
```

---

### 7. OCR Engine

**Location:** `Sources/ScreenMuseCore/OCREngine.swift`  
**Framework:** Vision (VNRecognizeTextRequest)

**Responsibilities:**
- Extract text from images
- OCR screen regions
- Return bounding boxes
- Detect languages
- Provide confidence scores

**OCR Modes:**

1. **Fast Mode** (< 1s)
   - Lower accuracy
   - Good for quick extraction
   - Recognizes printed text well

2. **Accurate Mode** (2-5s)
   - Higher accuracy
   - Slower processing
   - Better for complex text

**Implementation:**
```swift
actor OCREngine {
    func recognize(image: NSImage, mode: OCRMode) async throws -> OCRResult {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.imageConversionFailed
        }
        
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = mode == .fast ? .fast : .accurate
        
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        
        guard let observations = request.results as? [VNRecognizedTextObservation] else {
            return OCRResult(text: "", confidence: 0.0, detectedLanguage: nil)
        }
        
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let confidence = observations.map { $0.confidence }.reduce(0, +) / Double(observations.count)
        
        return OCRResult(text: text, confidence: Double(confidence), detectedLanguage: "en")
    }
}
```

---

### 8. File Manager

**Location:** `Sources/ScreenMuseCore/RecordingFileManager.swift`  
**Storage:** Local filesystem + iCloud

**Responsibilities:**
- List recordings
- Delete recordings
- Calculate sizes
- Upload to iCloud
- Auto-cleanup old files
- Monitor disk space

**Storage Structure:**
```
~/Movies/ScreenMuse/
├── recordings/
│   ├── 2026-03-27_14-30-15.mp4          (video file)
│   ├── 2026-03-27_14-30-15.json         (timeline metadata)
│   └── 2026-03-27_14-30-15_thumb.jpg    (thumbnail)
└── exports/
    ├── demo.gif
    └── demo.webp
```

**iCloud Integration:**
```swift
func uploadToiCloud(url: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
    let iCloudURL = FileManager.default.url(
        forUbiquityContainerIdentifier: nil
    )?.appendingPathComponent("Documents/ScreenMuse")
    
    guard let iCloudURL = iCloudURL else {
        throw FileManagementError.iCloudUnavailable
    }
    
    // Copy with progress tracking
    try await copyWithProgress(from: url, to: iCloudURL, progress: progress)
    
    return iCloudURL
}
```

---

### 9. Streaming Server

**Location:** `Sources/ScreenMuseCore/StreamingServer.swift`  
**Protocol:** Server-Sent Events (SSE)

**Responsibilities:**
- Stream frames to clients
- Support multiple concurrent clients
- Configurable FPS and scale
- Send heartbeat keep-alives
- Handle client disconnections

**SSE Format:**
```
data: {"type":"frame","timestamp":5.123,"data":"base64...","width":1920,"height":1080}

data: {"type":"heartbeat","timestamp":10.0}

data: {"type":"status","is_recording":true,"elapsed":15.5}

```

**Multi-Client Architecture:**
```swift
actor StreamingServer {
    private var clients: [ClientID: ClientConnection] = [:]
    private var frameBuffer: CircularBuffer<StreamFrame>
    
    func broadcastFrame(_ frame: StreamFrame) async {
        for (id, connection) in clients {
            do {
                try await connection.send(frame)
            } catch {
                // Client disconnected
                clients.removeValue(forKey: id)
            }
        }
    }
}
```

---

## Data Flow

### Recording Flow

```
User/Agent → HTTP POST /start
    │
    ▼
HTTP Server
    │
    ▼
Recording Manager
    │
    ├─► Capture Engine → ScreenCaptureKit → Frames
    │                         │
    │                         ▼
    │                    Effects Engine (Metal)
    │                         │
    │                         ▼
    │                    AVAssetWriter → MP4 File
    │
    ├─► Timeline Manager → In-memory timeline
    │
    └─► Window Manager → Focus/position windows
```

### Export Flow

```
User/Agent → HTTP POST /export/gif
    │
    ▼
HTTP Server
    │
    ▼
Video Exporter
    │
    ├─► Load MP4 → AVAsset
    │
    ├─► Extract Frames → CVPixelBuffer[]
    │
    ├─► Resize/Convert → CGImage[]
    │
    ├─► Apply Effects (optional)
    │
    └─► Encode GIF → File
```

### Streaming Flow

```
User/Agent → HTTP GET /stream (SSE)
    │
    ▼
Streaming Server
    │
    ├─► Register Client
    │
    ▼
Capture Engine → Real-time frames
    │
    ▼
Resize/Encode → JPEG @ 10-30fps
    │
    ▼
Base64 Encode
    │
    ▼
SSE Send → data: {"frame":...}
    │
    ▼
Client Receives → Decode → Display
```

---

## Design Decisions

### 1. Why Zero External Dependencies?

**Decision:** Use only native macOS frameworks

**Rationale:**
- **Reliability:** No dependency rot or version conflicts
- **Performance:** Native frameworks are hardware-optimized
- **Security:** Smaller attack surface, no third-party code
- **Simplicity:** Easier to audit and maintain
- **Longevity:** Won't break due to external package changes

**Trade-offs:**
- More code to write (no shortcuts via packages)
- Must implement features from scratch
- Limited to macOS platform

**Verdict:** Worth it for production reliability

---

### 2. Why HTTP API Instead of Swift Library?

**Decision:** Local HTTP server on port 7823

**Rationale:**
- **Language Agnostic:** Any language can control ScreenMuse
- **Process Isolation:** Agent crashes don't crash recorder
- **Remote Control:** Can control from Docker/VMs
- **Standard Protocol:** Well-understood HTTP semantics
- **Easy Testing:** curl/Postman for manual testing

**Trade-offs:**
- Network overhead (minimal on localhost)
- More complex than function calls
- Requires port management

**Verdict:** Flexibility > performance penalty

---

### 3. Why Metal for Effects?

**Decision:** GPU rendering via Metal shaders

**Rationale:**
- **Performance:** 60fps effects at 4K resolution
- **Parallel:** GPU processes all pixels simultaneously
- **Native:** Metal is macOS standard
- **Efficient:** Hardware encoding pipeline integration

**Trade-offs:**
- More complex than CPU rendering
- Requires Metal knowledge
- M-series only optimization

**Verdict:** Required for real-time performance

---

### 4. Why Actor-Based Concurrency?

**Decision:** Swift actors for state management

**Rationale:**
- **Thread Safety:** Automatic data race prevention
- **Modern Swift:** Structured concurrency (async/await)
- **Performance:** Efficient scheduling via cooperative threading
- **Clarity:** Explicit async boundaries

**Trade-offs:**
- Swift 6 minimum requirement
- Learning curve for contributors

**Verdict:** Future-proof architecture

---

### 5. Why Server-Sent Events for Streaming?

**Decision:** SSE over WebSockets

**Rationale:**
- **Simpler:** HTTP-based, no upgrade protocol
- **One-Way:** Perfect for frame broadcast
- **Auto-Reconnect:** Built into EventSource API
- **Firewall Friendly:** Standard HTTP port

**Trade-offs:**
- One-way only (sufficient for streaming)
- Less efficient than binary WebSocket

**Verdict:** Simplicity wins for this use case

---

## Extension Points

### 1. Custom Export Formats

**Hook:** `VideoExporter` protocol

```swift
protocol VideoExporter {
    func export(source: URL, output: URL, config: ExportConfig) async throws
}

// Implement new exporter
class WebMExporter: VideoExporter {
    func export(source: URL, output: URL, config: ExportConfig) async throws {
        // Custom WebM export logic
    }
}

// Register with export manager
exportManager.register(format: "webm", exporter: WebMExporter())
```

---

### 2. Custom Effects

**Hook:** `EffectRenderer` protocol

```swift
protocol EffectRenderer {
    func render(frame: CVPixelBuffer, params: EffectParams) async throws -> CVPixelBuffer
}

// Implement custom effect
class GlowEffectRenderer: EffectRenderer {
    func render(frame: CVPixelBuffer, params: EffectParams) async throws -> CVPixelBuffer {
        // Metal shader for glow effect
    }
}

// Register with effects engine
effectsEngine.register(effect: "glow", renderer: GlowEffectRenderer())
```

---

### 3. Storage Backends

**Hook:** `StorageProvider` protocol

```swift
protocol StorageProvider {
    func save(recording: URL) async throws -> URL
    func list() async throws -> [RecordingInfo]
    func delete(url: URL) async throws
}

// Implement cloud storage
class S3StorageProvider: StorageProvider {
    func save(recording: URL) async throws -> URL {
        // Upload to S3
    }
}

// Set storage provider
fileManager.setStorage(provider: S3StorageProvider())
```

---

### 4. Custom OCR Engines

**Hook:** `TextRecognizer` protocol

```swift
protocol TextRecognizer {
    func recognize(image: NSImage) async throws -> OCRResult
}

// Implement Tesseract backend
class TesseractRecognizer: TextRecognizer {
    func recognize(image: NSImage) async throws -> OCRResult {
        // Tesseract OCR
    }
}
```

---

## Performance Characteristics

### Recording Performance

**Target:** 60fps @ 4K (3840×2160)

**Measured:**
- **CPU Usage:** 8-15% (M-series Mac)
- **GPU Usage:** 20-30%
- **Memory:** 200-400 MB
- **Disk Write:** 50-100 MB/s (H.264)

**Optimization:**
- Hardware H.264 encoding (VideoToolbox)
- Metal for effects (GPU parallel)
- Async I/O for file writes
- Frame skipping on load spikes

---

### Effect Rendering

**Click Effect:**
- **Render Time:** < 1ms per frame @ 1080p
- **GPU Memory:** 10 MB per effect
- **Concurrent Effects:** Up to 10 without lag

**Zoom Animation:**
- **Interpolation:** < 0.5ms per frame
- **Scaling:** GPU-accelerated (Metal Performance Shaders)
- **Quality:** Lanczos resampling

---

### Export Performance

**GIF Export:**
- **Speed:** 2-5x real-time
- **10s video:** 2-4 seconds export time
- **Quality:** Configurable (5-30fps, 400-1920px)

**Trim/Crop:**
- **Speed:** 10x real-time (with re-encode)
- **Speed:** 100x real-time (stream copy)

---

### Streaming Performance

**Frame Delivery:**
- **Latency:** 50-100ms (local)
- **Max Clients:** 10 concurrent (tested)
- **Bandwidth:** 5-15 Mbps per client @ 1080p/30fps

---

## Security & Permissions

### Required Permissions

1. **Screen Recording**
   - Required for: Capturing screen content
   - Prompt: "ScreenMuse would like to record your screen"
   - Fallback: None (core functionality)

2. **Accessibility**
   - Required for: Window positioning
   - Prompt: "ScreenMuse would like to control your computer"
   - Fallback: Can still record, but can't position windows

3. **Microphone (Optional)**
   - Required for: Audio capture
   - Prompt: "ScreenMuse would like to access the microphone"
   - Fallback: Video-only recording

### API Security

**Current:** No authentication (localhost-only)

**Future Options:**
- API key authentication
- JWT tokens
- mTLS certificates

**Recommendation:** Add authentication before exposing to network

---

## Deployment

### Build Configuration

```bash
# Development
swift build

# Release (optimized)
swift build -c release

# Xcode
open Package.swift
# Product > Archive
```

### Distribution

**Current:** Source-only (GitHub)

**Future:**
- Homebrew formula
- DMG installer
- Mac App Store (requires sandboxing changes)

---

## Testing Strategy

**Unit Tests:** 201 tests covering all major systems
**Integration Tests:** Planned (Playwright, MCP)
**Performance Tests:** Included in test suite
**CI/CD:** GitHub Actions on every commit

**Coverage Target:** 75%+

---

## Future Roadmap

### v1.1 (Next Quarter)
- [ ] Multi-display support
- [ ] Audio waveform visualization
- [ ] Real-time transcription
- [ ] Keyboard shortcuts overlay

### v1.2
- [ ] Cloud storage integration (S3, Dropbox)
- [ ] Collaborative editing
- [ ] Live streaming (RTMP)
- [ ] Mobile companion app

### v2.0
- [ ] AI-powered editing suggestions
- [ ] Automatic highlight detection
- [ ] Voice commands
- [ ] Cross-platform (Windows, Linux)

---

## Contributing

See main README for contribution guidelines.

**Key Areas for Contribution:**
1. New export formats
2. Additional effects
3. Storage backend integrations
4. Performance optimizations
5. Test coverage expansion

---

## References

- [ScreenCaptureKit Documentation](https://developer.apple.com/documentation/screencapturekit)
- [Metal Programming Guide](https://developer.apple.com/metal/)
- [Vision Framework](https://developer.apple.com/documentation/vision)
- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)

---

**Document Version:** 1.0  
**Last Updated:** 2026-03-27  
**Maintained By:** ScreenMuse Contributors
