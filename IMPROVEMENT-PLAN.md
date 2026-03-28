# ScreenMuse Improvement Plan

**Created:** 2026-03-27  
**Goal:** Take ScreenMuse from 7.8/10 → 9.5/10  
**Timeline:** 3 weeks  
**Priority:** Testing + Code Hygiene

---

## 🎯 CURRENT STATE:

**Strengths:**
- ✅ Zero external dependencies (11/10!)
- ✅ Native Swift 6, modern patterns
- ✅ GPU-accelerated (Metal)
- ✅ Agent-first API (40+ endpoints)
- ✅ Rich integrations (Playwright, MCP)

**Critical Issues:**
- ❌ **ZERO tests** (11,379 LOC untested!)
- ⚠️ No linter/formatter
- ⚠️ No CI/CD
- ⚠️ Missing architecture docs

**Current Score:** 7.8/10  
**Target Score:** 9.5/10

---

## 📋 IMPROVEMENT ROADMAP:

### **Week 1: Emergency Test Coverage** (Priority 1)

**Goal:** Cover critical paths with 20 tests

**Test Categories:**

#### 1. Recording Lifecycle (5 tests)
```swift
// Tests/ScreenMuseCoreTests/RecordingLifecycleTests.swift

import XCTest
@testable import ScreenMuseCore

final class RecordingLifecycleTests: XCTestCase {
    
    func testStartRecording() async throws {
        // Arrange
        let manager = RecordingManager()
        let config = RecordingConfig(name: "test")
        
        // Act
        try await manager.startRecording(config: config)
        
        // Assert
        XCTAssertTrue(manager.isRecording)
        XCTAssertNotNil(manager.currentSession)
    }
    
    func testStopRecording() async throws {
        // Arrange
        let manager = RecordingManager()
        try await manager.startRecording(config: RecordingConfig(name: "test"))
        
        // Act
        let url = try await manager.stopRecording()
        
        // Assert
        XCTAssertFalse(manager.isRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    
    func testPauseResumeRecording() async throws {
        // Arrange
        let manager = RecordingManager()
        try await manager.startRecording(config: RecordingConfig(name: "test"))
        
        // Act
        try await manager.pauseRecording()
        XCTAssertTrue(manager.isPaused)
        
        try await manager.resumeRecording()
        XCTAssertFalse(manager.isPaused)
    }
    
    func testConcurrentStartPrevention() async throws {
        // Arrange
        let manager = RecordingManager()
        try await manager.startRecording(config: RecordingConfig(name: "test"))
        
        // Act & Assert
        do {
            try await manager.startRecording(config: RecordingConfig(name: "test2"))
            XCTFail("Should throw error on concurrent start")
        } catch RecordingError.alreadyRecording {
            // Expected
        }
    }
    
    func testStopWithoutStart() async throws {
        // Arrange
        let manager = RecordingManager()
        
        // Act & Assert
        do {
            _ = try await manager.stopRecording()
            XCTFail("Should throw error when stopping without start")
        } catch RecordingError.notRecording {
            // Expected
        }
    }
}
```

---

#### 2. HTTP API Endpoints (5 tests)
```swift
// Tests/ScreenMuseCoreTests/APIEndpointTests.swift

import XCTest
@testable import ScreenMuseCore

final class APIEndpointTests: XCTestCase {
    var server: ScreenMuseServer!
    
    override func setUp() async throws {
        server = try await ScreenMuseServer(port: 7824) // Test port
        try await server.start()
    }
    
    override func tearDown() async throws {
        try await server.stop()
    }
    
    func testStartEndpoint() async throws {
        // Arrange
        let json = #"{"name": "test-recording"}"#
        
        // Act
        let response = try await sendRequest(
            method: "POST",
            path: "/start",
            body: json
        )
        
        // Assert
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(StartResponse.self, from: response.data)
        XCTAssertEqual(data.status, "recording")
    }
    
    func testStopEndpoint() async throws {
        // Arrange
        _ = try await sendRequest(method: "POST", path: "/start", body: #"{"name": "test"}"#)
        
        // Act
        let response = try await sendRequest(method: "POST", path: "/stop")
        
        // Assert
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(StopResponse.self, from: response.data)
        XCTAssertTrue(data.video_path.hasSuffix(".mp4"))
    }
    
    func testStatusEndpoint() async throws {
        // Act
        let response = try await sendRequest(method: "GET", path: "/status")
        
        // Assert
        XCTAssertEqual(response.statusCode, 200)
        let data = try JSONDecoder().decode(StatusResponse.self, from: response.data)
        XCTAssertNotNil(data.is_recording)
    }
    
    func testInvalidRoute() async throws {
        // Act
        let response = try await sendRequest(method: "GET", path: "/invalid")
        
        // Assert
        XCTAssertEqual(response.statusCode, 404)
    }
    
    func testMalformedJSON() async throws {
        // Act
        let response = try await sendRequest(
            method: "POST",
            path: "/start",
            body: "not-json"
        )
        
        // Assert
        XCTAssertEqual(response.statusCode, 400)
    }
}
```

---

#### 3. Export Functions (5 tests)
```swift
// Tests/ScreenMuseCoreTests/ExportTests.swift

import XCTest
@testable import ScreenMuseCore

final class ExportTests: XCTestCase {
    var testVideoURL: URL!
    
    override func setUp() async throws {
        // Create test video
        testVideoURL = try await createTestVideo()
    }
    
    func testGIFExport() async throws {
        // Arrange
        let exporter = VideoExporter()
        
        // Act
        let gifURL = try await exporter.exportAsGIF(
            source: testVideoURL,
            fps: 10,
            scale: 800
        )
        
        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: gifURL.path))
        XCTAssertTrue(gifURL.pathExtension == "gif")
    }
    
    func testWebPExport() async throws {
        // Arrange
        let exporter = VideoExporter()
        
        // Act
        let webpURL = try await exporter.exportAsWebP(
            source: testVideoURL,
            quality: 80
        )
        
        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: webpURL.path))
        XCTAssertTrue(webpURL.pathExtension == "webp")
    }
    
    func testTrimVideo() async throws {
        // Arrange
        let exporter = VideoExporter()
        
        // Act
        let trimmedURL = try await exporter.trim(
            source: testVideoURL,
            start: 0,
            end: 5
        )
        
        // Assert
        let duration = try await getVideoDuration(trimmedURL)
        XCTAssertEqual(duration, 5.0, accuracy: 0.1)
    }
    
    func testCropVideo() async throws {
        // Arrange
        let exporter = VideoExporter()
        let cropRect = CGRect(x: 100, y: 100, width: 800, height: 600)
        
        // Act
        let croppedURL = try await exporter.crop(
            source: testVideoURL,
            rect: cropRect
        )
        
        // Assert
        let size = try await getVideoResolution(croppedURL)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }
    
    func testSpeedRamp() async throws {
        // Arrange
        let exporter = VideoExporter()
        let cursorData = [/* test cursor events */]
        
        // Act
        let rampedURL = try await exporter.speedRamp(
            source: testVideoURL,
            cursorData: cursorData,
            maxSpeed: 3.0
        )
        
        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: rampedURL.path))
        // Duration should be shorter
        let originalDuration = try await getVideoDuration(testVideoURL)
        let rampedDuration = try await getVideoDuration(rampedURL)
        XCTAssertLessThan(rampedDuration, originalDuration)
    }
}
```

---

#### 4. Window Management (5 tests)
```swift
// Tests/ScreenMuseCoreTests/WindowManagementTests.swift

import XCTest
@testable import ScreenMuseCore

final class WindowManagementTests: XCTestCase {
    
    func testFocusWindow() async throws {
        // Arrange
        let manager = WindowManager()
        let appName = "Safari"
        
        // Act
        try await manager.focusWindow(app: appName)
        
        // Assert
        let activeApp = try await manager.getActiveWindow()
        XCTAssertEqual(activeApp.appName, appName)
    }
    
    func testPositionWindow() async throws {
        // Arrange
        let manager = WindowManager()
        let bounds = CGRect(x: 100, y: 100, width: 1200, height: 800)
        
        // Act
        try await manager.positionWindow(
            app: "Safari",
            bounds: bounds
        )
        
        // Assert
        let window = try await manager.getWindowInfo(app: "Safari")
        XCTAssertEqual(window.frame, bounds)
    }
    
    func testHideOthers() async throws {
        // Arrange
        let manager = WindowManager()
        let keepVisible = "Safari"
        
        // Act
        try await manager.hideOthers(except: keepVisible)
        
        // Assert
        let visibleApps = try await manager.getVisibleApps()
        XCTAssertEqual(visibleApps.count, 1)
        XCTAssertEqual(visibleApps.first, keepVisible)
    }
    
    func testGetActiveWindow() async throws {
        // Arrange
        let manager = WindowManager()
        
        // Act
        let activeWindow = try await manager.getActiveWindow()
        
        // Assert
        XCTAssertNotNil(activeWindow.appName)
        XCTAssertNotNil(activeWindow.windowTitle)
    }
    
    func testListRunningApps() async throws {
        // Arrange
        let manager = WindowManager()
        
        // Act
        let apps = try await manager.getRunningApps()
        
        // Assert
        XCTAssertGreaterThan(apps.count, 0)
        XCTAssertTrue(apps.contains { $0.name == "Finder" })
    }
}
```

---

### **Week 2: Expand Coverage** (50 tests)

**Test Categories:**

#### 5. Timeline Management (10 tests)
- Add chapter
- List chapters
- Update chapter name
- Delete chapter
- Add highlight
- List highlights
- Add note
- List notes
- Timeline JSON export
- Timeline validation

#### 6. Effects & Compositing (10 tests)
- Click effect rendering
- Zoom effect calculation
- Cursor tracking
- Keyboard event capture
- Effect frame compositing
- Metal shader pipeline
- Effect animation timing
- Effect parameter validation
- Multiple effects per frame
- Effect cleanup

#### 7. OCR Integration (5 tests)
- Fast OCR mode
- Accurate OCR mode
- Screen capture OCR
- Image file OCR
- OCR error handling

#### 8. File Management (10 tests)
- List recordings
- Delete recording
- Upload to iCloud
- File size calculation
- Disk space check
- Duplicate filename handling
- Invalid path handling
- Permission errors
- File cleanup
- Recording directory creation

#### 9. Streaming (5 tests)
- Start SSE stream
- Stop SSE stream
- Frame rate control
- Scale parameter
- Client disconnection

#### 10. Error Handling (10 tests)
- Network errors
- File system errors
- Permission errors
- Invalid state errors
- Timeout errors
- Concurrent operation errors
- Resource exhaustion
- Invalid parameter errors
- API error responses
- Error recovery

---

### **Week 3: Integration Tests** (20 tests)

#### 11. Full Workflow Tests (10 tests)
```swift
// Tests/ScreenMuseCoreTests/IntegrationTests.swift

final class IntegrationTests: XCTestCase {
    
    func testCompleteRecordingWorkflow() async throws {
        // Full end-to-end: start → chapter → highlight → stop → export
        let server = try await ScreenMuseServer(port: 7824)
        try await server.start()
        
        // Start recording
        _ = try await sendRequest(method: "POST", path: "/start", body: #"{"name": "integration-test"}"#)
        
        // Add chapter
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        _ = try await sendRequest(method: "POST", path: "/chapter", body: #"{"name": "Step 1"}"#)
        
        // Mark highlight
        _ = try await sendRequest(method: "POST", path: "/highlight")
        
        // Stop
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
        let stopResponse = try await sendRequest(method: "POST", path: "/stop")
        let data = try JSONDecoder().decode(StopResponse.self, from: stopResponse.data)
        
        // Export as GIF
        let exportBody = #"{"format": "gif", "fps": 10, "scale": 800}"#
        let exportResponse = try await sendRequest(method: "POST", path: "/export", body: exportBody)
        
        // Assert
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.video_path))
        let exportData = try JSONDecoder().decode(ExportResponse.self, from: exportResponse.data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportData.gif_path))
    }
    
    func testPiPRecording() async throws {
        // Multi-window PiP recording
    }
    
    func testConcatMultipleRecordings() async throws {
        // Record 3 clips, concat them
    }
    
    func testTrimAndCrop() async throws {
        // Record, trim, then crop
    }
    
    func testSpeedRampWithIdleDetection() async throws {
        // Record with idle periods, apply speedramp
    }
    
    func testWindowFocusAndRecord() async throws {
        // Focus window, position it, record
    }
    
    func testOCRDuringRecording() async throws {
        // Start recording, run OCR mid-session
    }
    
    func testWebhookNotification() async throws {
        // Start with webhook, verify callback
    }
    
    func testBatchScriptExecution() async throws {
        // Run multiple scripts during recording
    }
    
    func testErrorRecoveryWorkflow() async throws {
        // Trigger error, recover, continue
    }
}
```

#### 12. Playwright Integration Tests (5 tests)
```swift
// Tests/PlaywrightIntegrationTests.swift

final class PlaywrightIntegrationTests: XCTestCase {
    
    func testPlaywrightPackageIntegration() async throws {
        // Test npm package can control ScreenMuse
    }
    
    func testBrowserWindowDetection() async throws {
        // Launch browser, detect window, start recording
    }
    
    func testPlaywrightTestFixture() async throws {
        // Test automatic video on test failure
    }
    
    func testCleanRecordingSetup() async throws {
        // Test focus, position, hide-others workflow
    }
    
    func testGIFExportFromPlaywright() async throws {
        // Test gif: true option
    }
}
```

#### 13. MCP Server Tests (5 tests)
```swift
// Tests/MCPServerTests.swift

final class MCPServerTests: XCTestCase {
    
    func testMCPServerStartup() async throws {
        // MCP server starts correctly
    }
    
    func testMCPToolInvocation() async throws {
        // Can call tools via MCP protocol
    }
    
    func testMCPResourceListing() async throws {
        // Can list recordings via MCP
    }
    
    func testMCPErrorHandling() async throws {
        // MCP error responses correct
    }
    
    func testClaudeDesktopIntegration() async throws {
        // Mock Claude Desktop connection
    }
}
```

---

## 🛠️ IMPLEMENTATION PLAN:

### **Step 1: Setup Test Infrastructure (Day 1)**

Create test structure:

```bash
# Create test directories
mkdir -p Tests/ScreenMuseCoreTests
mkdir -p Tests/PlaywrightIntegrationTests
mkdir -p Tests/MCPServerTests

# Create test files
touch Tests/ScreenMuseCoreTests/RecordingLifecycleTests.swift
touch Tests/ScreenMuseCoreTests/APIEndpointTests.swift
touch Tests/ScreenMuseCoreTests/ExportTests.swift
touch Tests/ScreenMuseCoreTests/WindowManagementTests.swift
touch Tests/ScreenMuseCoreTests/IntegrationTests.swift
```

Update `Package.swift`:

```swift
// Add test targets
.testTarget(
    name: "ScreenMuseCoreTests",
    dependencies: ["ScreenMuseCore"]
),
.testTarget(
    name: "PlaywrightIntegrationTests",
    dependencies: ["ScreenMuseCore"]
),
.testTarget(
    name: "MCPServerTests",
    dependencies: ["ScreenMuseCore"]
)
```

---

### **Step 2: Add SwiftLint (Day 1)**

Install SwiftLint:

```bash
brew install swiftlint
```

Create `.swiftlint.yml`:

```yaml
# .swiftlint.yml
disabled_rules:
  - trailing_whitespace
opt_in_rules:
  - empty_count
  - empty_string
included:
  - Sources
excluded:
  - Tests
  - .build
line_length: 120
function_body_length: 60
type_body_length: 300
file_length: 500
```

Add to Package.swift:

```swift
.plugin(name: "SwiftLintPlugin", package: "SwiftLintPlugin")
```

---

### **Step 3: Add CI/CD (Day 2)**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v3
      
      - name: Install SwiftLint
        run: brew install swiftlint
      
      - name: Lint
        run: swiftlint
      
      - name: Build
        run: swift build
      
      - name: Test
        run: swift test
      
      - name: Test Coverage
        run: |
          swift test --enable-code-coverage
          xcrun llvm-cov report .build/debug/ScreenMuseCorePackageTests.xctest/Contents/MacOS/ScreenMuseCorePackageTests -instr-profile .build/debug/codecov/default.profdata
```

---

### **Step 4: Add Architecture Docs (Day 3)**

Create `ARCHITECTURE.md` (15KB):

**Sections:**
1. System Overview (diagram)
2. Core Components
   - ScreenCaptureKit integration
   - AVFoundation pipeline
   - Metal effects compositing
   - HTTP API server
3. Data Flow
   - Recording → Encoding → File
   - Export → Processing → Output
4. Design Decisions
   - Why zero dependencies?
   - Why HTTP API?
   - Why Metal for effects?
5. Extension Points

---

### **Step 5: Write Tests (Days 4-21)**

**Week 1 (Days 4-7):** 20 tests  
**Week 2 (Days 8-14):** 50 tests  
**Week 3 (Days 15-21):** 20 integration tests

**Daily target:** 5-7 tests/day

---

## 📊 SUCCESS METRICS:

| Metric | Current | Week 1 | Week 2 | Week 3 | Target |
|--------|---------|--------|--------|--------|--------|
| **Test Files** | 0 | 5 | 15 | 20 | 20 |
| **Test Cases** | 0 | 20 | 70 | 90 | 90 |
| **Code Coverage** | 0% | 30% | 60% | 75% | 75%+ |
| **SwiftLint** | ❌ | ✅ | ✅ | ✅ | ✅ |
| **CI/CD** | ❌ | ✅ | ✅ | ✅ | ✅ |
| **Architecture Docs** | ❌ | - | ✅ | ✅ | ✅ |
| **Overall Score** | 7.8/10 | 8.2/10 | 8.8/10 | 9.5/10 | 9.5/10 |

---

## 🎯 DELIVERABLES:

**Week 1:**
- ✅ 20 critical tests
- ✅ SwiftLint configured
- ✅ CI/CD pipeline

**Week 2:**
- ✅ 70 total tests
- ✅ ARCHITECTURE.md
- ✅ 60% code coverage

**Week 3:**
- ✅ 90 total tests
- ✅ Integration tests
- ✅ 75%+ code coverage
- ✅ 9.5/10 score

---

## 💰 COST-BENEFIT:

**Investment:** 3 weeks (60-90 hours)

**Benefits:**
- ✅ Production confidence (no more blind deploys)
- ✅ Safe refactoring (test safety net)
- ✅ Agent reliability (API tested)
- ✅ Faster debugging (tests pinpoint issues)
- ✅ Better documentation (tests = living docs)
- ✅ Professional credibility (shows discipline)
- ✅ **7.8/10 → 9.5/10 score**

**ROI:** High (prevents production incidents, enables rapid iteration)

---

## 🔥 PRIORITY ORDER:

1. **CRITICAL:** Recording lifecycle tests (Day 1)
2. **CRITICAL:** HTTP API tests (Day 2)
3. **HIGH:** Export tests (Day 3)
4. **HIGH:** SwiftLint + CI/CD (Day 1-2)
5. **MEDIUM:** Window management tests (Day 4)
6. **MEDIUM:** Timeline tests (Week 2)
7. **MEDIUM:** Effects tests (Week 2)
8. **LOW:** Integration tests (Week 3)

---

## 📝 NOTES:

- Start with critical paths (recording, API)
- Keep tests fast (< 5s total suite time)
- Use test doubles for expensive operations (Metal, file I/O)
- Run tests on every commit (CI/CD)
- Track coverage (aim for 75%+)
- Document test setup in README

---

**Ready to execute!** 🚀

**Next steps:**
1. Create test infrastructure
2. Add SwiftLint
3. Setup CI/CD
4. Start writing tests (5-7/day)

**Timeline:** 3 weeks to 9.5/10

**Let's do this!** 💪
