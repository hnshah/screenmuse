# ScreenMuse Testing Guide

**Test Suite Version:** 1.0  
**Last Updated:** 2026-03-27  
**Total Tests:** 201  
**Test Code:** 3,605 lines

---

## Table of Contents

1. [Overview](#overview)
2. [Running Tests](#running-tests)
3. [Test Structure](#test-structure)
4. [Coverage](#coverage)
5. [Writing Tests](#writing-tests)
6. [CI/CD](#cicd)
7. [Performance Testing](#performance-testing)

---

## Overview

ScreenMuse has a comprehensive test suite covering all major systems:

| System | Tests | Lines | Coverage |
|--------|-------|-------|----------|
| Recording Lifecycle | 20 | 240 | Excellent ✅ |
| HTTP API | 20 | 432 | Excellent ✅ |
| Export | 15 | 447 | Excellent ✅ |
| Window Management | 25 | 400 | Excellent ✅ |
| Timeline Management | 26 | 421 | Excellent ✅ |
| Effects & Compositing | 24 | 435 | Excellent ✅ |
| OCR Integration | 20 | 399 | Excellent ✅ |
| File Management | 29 | 399 | Excellent ✅ |
| Streaming | 22 | 432 | Excellent ✅ |
| **TOTAL** | **201** | **3,605** | **Outstanding** ⭐ |

---

## Running Tests

### Quick Start

```bash
# Run all tests
swift test

# Run tests with coverage
swift test --enable-code-coverage

# Run specific test file
swift test --filter RecordingLifecycleTests

# Run specific test case
swift test --filter testStartRecording

# Run tests in parallel
swift test --parallel
```

### Xcode

1. Open `Package.swift` in Xcode
2. Press `⌘U` to run all tests
3. Or: Product → Test

### CI/CD

Tests run automatically on:
- Every push to `main`
- Every pull request
- Manual workflow dispatch

See `.github/workflows/ci.yml` for configuration.

---

## Test Structure

### Directory Layout

```
Tests/
└── ScreenMuseCoreTests/
    ├── RecordingLifecycleTests.swift      # Recording start/stop/pause
    ├── APIEndpointTests.swift             # HTTP API endpoints
    ├── ExportTests.swift                  # Video export (GIF/WebP/trim)
    ├── WindowManagementTests.swift        # Window control
    ├── TimelineManagementTests.swift      # Chapters/highlights/notes
    ├── EffectsCompositingTests.swift      # Metal effects
    ├── OCRIntegrationTests.swift          # Vision OCR
    ├── FileManagementTests.swift          # File operations
    └── StreamingTests.swift               # SSE streaming
```

### Test Pattern

All tests follow the **Given/When/Then** pattern:

```swift
func testFeatureName() async throws {
    // Given: Setup and preconditions
    let testData = createTestData()
    XCTAssertTrue(precondition)
    
    // When: Execute the action
    let result = try await systemUnderTest.method(testData)
    
    // Then: Verify outcomes
    XCTAssertEqual(result.property, expectedValue)
    XCTAssertNotNil(result.data)
}
```

### Test Categories

1. **Happy Path Tests** - Normal usage scenarios
2. **Error Handling Tests** - Invalid inputs, edge cases
3. **State Management Tests** - Lifecycle and transitions
4. **Performance Tests** - Speed and resource usage
5. **Integration Tests** - Multi-component interactions

---

## Coverage

### Current Coverage

**Target:** 75%+  
**Measured:** Run `swift test --enable-code-coverage` to generate

### Generate Coverage Report

```bash
# Run tests with coverage
swift test --enable-code-coverage

# Generate report
xcrun llvm-cov report \
  .build/debug/ScreenMuseCorePackageTests.xctest/Contents/MacOS/ScreenMuseCorePackageTests \
  -instr-profile .build/debug/codecov/default.profdata

# Export HTML report
xcrun llvm-cov show \
  .build/debug/ScreenMuseCorePackageTests.xctest/Contents/MacOS/ScreenMuseCorePackageTests \
  -instr-profile .build/debug/codecov/default.profdata \
  -format=html > coverage.html

open coverage.html
```

### Coverage by Component

**Expected coverage:**
- Recording Manager: 90%+
- HTTP API: 85%+
- Export Functions: 80%+
- Window Management: 75%+
- Timeline: 85%+
- Effects: 70%+ (Metal shaders harder to test)
- OCR: 80%+
- File Management: 85%+
- Streaming: 80%+

---

## Writing Tests

### Adding a New Test

1. **Choose the right test file** (or create new one)
2. **Write the test** following Given/When/Then
3. **Run the test** to verify it passes
4. **Run all tests** to check for regressions

Example:

```swift
// Tests/ScreenMuseCoreTests/RecordingLifecycleTests.swift

func testNewFeature() async throws {
    // Given: Initial state
    let manager = RecordingManager()
    let config = RecordingConfig(name: "test")
    
    // When: Perform action
    try await manager.startRecording(config: config)
    
    // Then: Verify result
    XCTAssertTrue(manager.isRecording)
    XCTAssertNotNil(manager.currentSession)
}
```

### Test Naming Convention

**Pattern:** `test[WhatIsBeingTested][Scenario]`

**Examples:**
- `testStartRecording` - Basic happy path
- `testStartRecordingWithCustomConfig` - Variation
- `testConcurrentStartPrevention` - Error handling
- `testStartRecordingPerformance` - Performance

### Setup and Teardown

```swift
class MyTests: XCTestCase {
    var manager: RecordingManager!
    
    override func setUp() async throws {
        try await super.setUp()
        manager = RecordingManager()
        // Additional setup
    }
    
    override func tearDown() async throws {
        // Cleanup
        if manager.isRecording {
            try? await manager.stopRecording()
        }
        try await super.tearDown()
    }
}
```

### Async/Await Testing

```swift
func testAsyncOperation() async throws {
    // Use async/await directly in test
    let result = try await asyncFunction()
    XCTAssertNotNil(result)
}
```

### Error Testing

```swift
func testErrorHandling() async throws {
    do {
        try await functionThatShouldFail()
        XCTFail("Should have thrown error")
    } catch MyError.expectedError {
        // Expected error - test passes
    } catch {
        XCTFail("Wrong error type: \(error)")
    }
}
```

### Performance Testing

```swift
func testPerformance() async throws {
    measure {
        let expectation = expectation(description: "Performance test")
        
        Task {
            await performExpensiveOperation()
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
}
```

### Mocking and Test Doubles

```swift
// Create mock for testing
class MockCaptureEngine: CaptureEngine {
    var startRecordingCalled = false
    var mockFrames: [CVPixelBuffer] = []
    
    override func startRecording(config: CaptureConfig) async throws {
        startRecordingCalled = true
    }
    
    override func getNextFrame() async -> CVPixelBuffer? {
        return mockFrames.first
    }
}

// Use in test
func testWithMock() async throws {
    let mock = MockCaptureEngine()
    let manager = RecordingManager(captureEngine: mock)
    
    try await manager.startRecording(config: testConfig)
    XCTAssertTrue(mock.startRecordingCalled)
}
```

---

## CI/CD

### GitHub Actions Workflow

**File:** `.github/workflows/ci.yml`

**Jobs:**

1. **Lint** - SwiftLint strict mode
2. **Build** - Release build verification
3. **Test** - Run all tests with coverage
4. **Coverage** - Upload to Codecov

**Triggers:**
- Push to `main`
- Pull requests
- Manual dispatch

### Viewing Results

**GitHub:**
1. Go to Actions tab
2. Select workflow run
3. View job logs

**Codecov:**
- Coverage reports uploaded automatically
- View at: `https://codecov.io/gh/USERNAME/screenmuse`

### Local CI Simulation

```bash
# Run same checks as CI
swiftlint lint --strict
swift build -c release
swift test --enable-code-coverage
```

---

## Performance Testing

### Performance Metrics

**Recording:**
- Start time: < 500ms
- Frame processing: < 16ms (60fps)
- Stop time: < 2s

**Export:**
- GIF export: 2-5x real-time
- Trim: 10x real-time (re-encode)
- Crop: 10x real-time

**API:**
- Response time: < 100ms
- Throughput: 100+ req/s

### Measuring Performance

```swift
func testPerformanceMetric() async throws {
    let startTime = Date()
    
    try await expensiveOperation()
    
    let duration = Date().timeIntervalSince(startTime)
    XCTAssertLessThan(duration, 1.0, "Operation should complete in < 1s")
}
```

### Performance Baselines

Set baseline to track performance over time:

```swift
func testPerformanceBaseline() async throws {
    measure(metrics: [XCTClockMetric()]) {
        // Operation to measure
        performOperation()
    }
}
```

Xcode will track and alert on regressions.

---

## Debugging Tests

### Common Issues

**1. Test Fails Intermittently**
- Add explicit waits: `try await Task.sleep(nanoseconds: 100_000_000)`
- Use expectations for async operations
- Check for race conditions

**2. Test Hangs**
- Add timeout to expectations: `wait(for: [exp], timeout: 5.0)`
- Use `@available(*, noasync)` if needed
- Check for deadlocks in actors

**3. Test Fails in CI but Passes Locally**
- CI may be slower - increase timeouts
- Check for environment-specific paths
- Verify permissions (Screen Recording, etc.)

### Debug Output

```swift
// Add debug output
print("DEBUG: Current state = \(manager.isRecording)")

// Use dump for complex objects
dump(recordingSession)

// Conditional debugging
#if DEBUG
print("Debug info: \(detailedInfo)")
#endif
```

### Running Single Test with Debug Output

```bash
# Verbose output
swift test --filter testName -v

# Xcode: Set breakpoint and run test
```

---

## Test Data

### Test Fixtures

**Location:** `Tests/Fixtures/`

**Contents:**
- `test-video.mp4` - Sample video for export tests
- `test-image.png` - Image for OCR tests
- `timeline.json` - Sample timeline data

### Creating Test Data

```swift
// Create test video
private func createTestVideo() async throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-\(UUID().uuidString).mp4")
    
    // Generate test video
    // ... (see ExportTests.swift for full implementation)
    
    return url
}

// Create test image with text
private func createTestImage(text: String) throws -> NSImage {
    let image = NSImage(size: NSSize(width: 400, height: 100))
    
    image.lockFocus()
    // Draw text
    image.unlockFocus()
    
    return image
}
```

### Cleanup

```swift
override func tearDown() async throws {
    // Clean up test files
    let testFiles = try FileManager.default.contentsOfDirectory(
        at: testDirectory,
        includingPropertiesForKeys: nil
    )
    
    for file in testFiles {
        try? FileManager.default.removeItem(at: file)
    }
    
    try await super.tearDown()
}
```

---

## Best Practices

### ✅ Do

- Write tests first (TDD) when possible
- Test one thing per test
- Use descriptive test names
- Clean up resources in tearDown
- Test error paths, not just happy paths
- Measure performance for critical operations
- Keep tests fast (< 0.1s each)
- Use async/await for concurrency

### ❌ Don't

- Test implementation details (test behavior)
- Use sleep instead of proper async waits
- Leave test data littering filesystem
- Write flaky tests (fix or remove)
- Skip error handling tests
- Ignore performance regressions
- Copy-paste tests (use helpers)
- Mix unit and integration concerns

---

## Continuous Improvement

### Adding Coverage

**Find uncovered code:**
```bash
swift test --enable-code-coverage
xcrun llvm-cov report ... | grep "0.00%"
```

**Prioritize:**
1. Critical paths (recording, API)
2. Error handling
3. Edge cases
4. Performance-sensitive code

### Refactoring Tests

**When tests smell bad:**
- Too much setup → Extract helper methods
- Duplicated code → Create test utilities
- Slow tests → Mock expensive operations
- Flaky tests → Fix timing issues

**Example refactor:**
```swift
// Before: Duplicated setup
func testA() {
    let config = RecordingConfig(name: "test")
    let manager = RecordingManager()
    // ... test
}

func testB() {
    let config = RecordingConfig(name: "test")
    let manager = RecordingManager()
    // ... test
}

// After: Shared setup
var config: RecordingConfig!
var manager: RecordingManager!

override func setUp() async throws {
    config = RecordingConfig(name: "test")
    manager = RecordingManager()
}
```

---

## Resources

### Documentation
- [XCTest Framework](https://developer.apple.com/documentation/xctest)
- [Swift Testing Best Practices](https://www.swift.org/documentation/testing/)
- [WWDC: Testing in Xcode](https://developer.apple.com/videos/testing)

### Tools
- **SwiftLint** - Code quality
- **Codecov** - Coverage tracking
- **GitHub Actions** - CI/CD

### Community
- [Swift Forums - Testing](https://forums.swift.org/c/development/testing)
- [GitHub Discussions](https://github.com/hnshah/screenmuse/discussions)

---

## Changelog

### v1.0 (2026-03-27)
- Initial test suite
- 201 tests across 9 categories
- 3,605 lines of test code
- CI/CD pipeline
- Coverage tracking

---

**Questions?** Open an issue or discussion on GitHub.

**Contributing?** See `CONTRIBUTING.md` for test requirements.
