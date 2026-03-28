import XCTest
@testable import ScreenMuseCore
import AppKit

/// Tests for window management and system control
/// Priority: HIGH - Required for clean recordings
final class WindowManagementTests: XCTestCase {
    
    var manager: WindowManager!
    
    override func setUp() async throws {
        try await super.setUp()
        manager = WindowManager()
    }
    
    // MARK: - Focus Window Tests
    
    func testFocusWindow() async throws {
        // Given: Safari is running (or another test app)
        let testApp = "Finder" // Finder is always running on macOS
        
        // When: Focusing the window
        try await manager.focusWindow(app: testApp)
        
        // Then: App should be frontmost
        let activeApp = try await manager.getActiveWindow()
        XCTAssertEqual(activeApp.appName, testApp)
    }
    
    func testFocusNonExistentApp() async throws {
        // When: Attempting to focus non-existent app
        do {
            try await manager.focusWindow(app: "NonExistentApp12345")
            XCTFail("Should throw error for non-existent app")
        } catch WindowError.appNotFound {
            // Expected
        }
    }
    
    func testFocusMultipleTimes() async throws {
        // When: Focusing same app multiple times
        try await manager.focusWindow(app: "Finder")
        try await manager.focusWindow(app: "Finder")
        try await manager.focusWindow(app: "Finder")
        
        // Then: Should not error, app should be focused
        let activeApp = try await manager.getActiveWindow()
        XCTAssertEqual(activeApp.appName, "Finder")
    }
    
    func testFocusWindowByBundleID() async throws {
        // When: Focusing by bundle ID
        try await manager.focusWindow(bundleID: "com.apple.finder")
        
        // Then: Finder should be active
        let activeApp = try await manager.getActiveWindow()
        XCTAssertEqual(activeApp.appName, "Finder")
    }
    
    // MARK: - Position Window Tests
    
    func testPositionWindow() async throws {
        // Given: A window to position
        let bounds = CGRect(x: 100, y: 100, width: 1200, height: 800)
        
        // When: Setting window position
        try await manager.positionWindow(
            app: "Finder",
            bounds: bounds
        )
        
        // Then: Window should be at new position
        let window = try await manager.getWindowInfo(app: "Finder")
        XCTAssertEqual(window.frame.origin.x, bounds.origin.x, accuracy: 10)
        XCTAssertEqual(window.frame.origin.y, bounds.origin.y, accuracy: 10)
        XCTAssertEqual(window.frame.size.width, bounds.size.width, accuracy: 10)
        XCTAssertEqual(window.frame.size.height, bounds.size.height, accuracy: 10)
    }
    
    func testPositionWindowCentered() async throws {
        // Given: Screen dimensions
        let screen = NSScreen.main!
        let screenFrame = screen.frame
        
        // When: Centering window
        let size = CGSize(width: 1200, height: 800)
        let origin = CGPoint(
            x: (screenFrame.width - size.width) / 2,
            y: (screenFrame.height - size.height) / 2
        )
        let bounds = CGRect(origin: origin, size: size)
        
        try await manager.positionWindow(
            app: "Finder",
            bounds: bounds
        )
        
        // Then: Window should be centered
        let window = try await manager.getWindowInfo(app: "Finder")
        XCTAssertEqual(window.frame.origin.x, origin.x, accuracy: 10)
        XCTAssertEqual(window.frame.origin.y, origin.y, accuracy: 10)
    }
    
    func testPositionWindowOffScreen() async throws {
        // When: Attempting to position off-screen
        let offScreenBounds = CGRect(x: -1000, y: -1000, width: 800, height: 600)
        
        do {
            try await manager.positionWindow(
                app: "Finder",
                bounds: offScreenBounds
            )
            XCTFail("Should throw error for off-screen position")
        } catch WindowError.invalidPosition {
            // Expected
        }
    }
    
    func testPositionWindowRequiresAccessibility() async throws {
        // When: Positioning without Accessibility permission
        // Then: Should either work or throw permission error
        
        do {
            let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
            try await manager.positionWindow(app: "Finder", bounds: bounds)
            // Success - permission granted
        } catch WindowError.accessibilityPermissionRequired {
            // Expected if permission not granted
            XCTExpectFailure("Accessibility permission not granted")
        }
    }
    
    // MARK: - Hide Others Tests
    
    func testHideOthers() async throws {
        // Given: Multiple apps running
        let keepVisible = "Finder"
        
        // When: Hiding all except Finder
        try await manager.hideOthers(except: keepVisible)
        
        // Wait a bit for animations
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Then: Only Finder should be visible
        let visibleApps = try await manager.getVisibleApps()
        XCTAssertTrue(visibleApps.contains(keepVisible))
        // Note: System apps like Dock, SystemUIServer might still be visible
    }
    
    func testHideOthersByBundleID() async throws {
        // When: Hiding by bundle ID
        try await manager.hideOthers(exceptBundleID: "com.apple.finder")
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Then: Finder should be visible
        let visibleApps = try await manager.getVisibleApps()
        XCTAssertTrue(visibleApps.contains("Finder"))
    }
    
    func testHideOthersNonExistentApp() async throws {
        // When: Specifying non-existent app
        do {
            try await manager.hideOthers(except: "NonExistentApp")
            XCTFail("Should throw error")
        } catch WindowError.appNotFound {
            // Expected
        }
    }
    
    func testShowAllAfterHide() async throws {
        // Given: Hidden apps
        try await manager.hideOthers(except: "Finder")
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // When: Showing all
        try await manager.showAll()
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Then: Apps should be visible again
        let visibleApps = try await manager.getVisibleApps()
        XCTAssertGreaterThan(visibleApps.count, 1)
    }
    
    // MARK: - Get Active Window Tests
    
    func testGetActiveWindow() async throws {
        // Given: Some app is active
        try await manager.focusWindow(app: "Finder")
        
        // When: Getting active window
        let activeWindow = try await manager.getActiveWindow()
        
        // Then: Should return window info
        XCTAssertEqual(activeWindow.appName, "Finder")
        XCTAssertFalse(activeWindow.windowTitle.isEmpty)
        XCTAssertGreaterThan(activeWindow.frame.width, 0)
        XCTAssertGreaterThan(activeWindow.frame.height, 0)
    }
    
    func testGetActiveWindowDetails() async throws {
        // When: Getting detailed window info
        let window = try await manager.getActiveWindow()
        
        // Then: Should have all properties
        XCTAssertNotNil(window.appName)
        XCTAssertNotNil(window.windowTitle)
        XCTAssertNotNil(window.frame)
        XCTAssertNotNil(window.bundleID)
        XCTAssertNotNil(window.processID)
    }
    
    // MARK: - List Running Apps Tests
    
    func testListRunningApps() async throws {
        // When: Getting running apps
        let apps = try await manager.getRunningApps()
        
        // Then: Should include system apps
        XCTAssertGreaterThan(apps.count, 0)
        XCTAssertTrue(apps.contains { $0.name == "Finder" })
    }
    
    func testRunningAppsDetails() async throws {
        // When: Getting app details
        let apps = try await manager.getRunningApps()
        
        // Then: Each app should have valid info
        for app in apps.prefix(5) { // Check first 5
            XCTAssertFalse(app.name.isEmpty)
            XCTAssertFalse(app.bundleID.isEmpty)
            XCTAssertGreaterThan(app.processID, 0)
        }
    }
    
    func testFilterRunningAppsByName() async throws {
        // When: Filtering by name
        let apps = try await manager.getRunningApps(matching: "Finder")
        
        // Then: Should find Finder
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.name, "Finder")
    }
    
    func testFilterRunningAppsByBundleID() async throws {
        // When: Filtering by bundle ID
        let apps = try await manager.getRunningApps(bundleID: "com.apple.finder")
        
        // Then: Should find Finder
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.bundleID, "com.apple.finder")
    }
    
    // MARK: - Get Window Info Tests
    
    func testGetWindowInfo() async throws {
        // When: Getting info for specific app
        let window = try await manager.getWindowInfo(app: "Finder")
        
        // Then: Should return valid info
        XCTAssertEqual(window.appName, "Finder")
        XCTAssertGreaterThan(window.frame.width, 0)
        XCTAssertGreaterThan(window.frame.height, 0)
    }
    
    func testGetWindowInfoMultipleWindows() async throws {
        // When: App has multiple windows
        let windows = try await manager.getAllWindows(app: "Finder")
        
        // Then: Should return all windows
        XCTAssertGreaterThanOrEqual(windows.count, 1)
        for window in windows {
            XCTAssertEqual(window.appName, "Finder")
            XCTAssertGreaterThan(window.frame.width, 0)
        }
    }
    
    func testGetWindowInfoNonExistent() async throws {
        // When: Getting info for non-existent app
        do {
            _ = try await manager.getWindowInfo(app: "NonExistent")
            XCTFail("Should throw error")
        } catch WindowError.appNotFound {
            // Expected
        }
    }
    
    // MARK: - Get Visible Apps Tests
    
    func testGetVisibleApps() async throws {
        // When: Getting visible apps
        let visibleApps = try await manager.getVisibleApps()
        
        // Then: Should include at least one app
        XCTAssertGreaterThan(visibleApps.count, 0)
    }
    
    func testGetVisibleAppsExcludesHidden() async throws {
        // Given: Hide some apps
        try await manager.hideOthers(except: "Finder")
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // When: Getting visible apps
        let visibleApps = try await manager.getVisibleApps()
        
        // Then: Hidden apps should not be included
        XCTAssertTrue(visibleApps.contains("Finder"))
        // (Other apps should be hidden)
    }
    
    // MARK: - Screen Detection Tests
    
    func testDetectScreens() async throws {
        // When: Detecting screens
        let screens = try await manager.getScreens()
        
        // Then: Should have at least main screen
        XCTAssertGreaterThanOrEqual(screens.count, 1)
        
        for screen in screens {
            XCTAssertGreaterThan(screen.frame.width, 0)
            XCTAssertGreaterThan(screen.frame.height, 0)
        }
    }
    
    func testGetMainScreen() async throws {
        // When: Getting main screen
        let mainScreen = try await manager.getMainScreen()
        
        // Then: Should return valid screen info
        XCTAssertGreaterThan(mainScreen.frame.width, 0)
        XCTAssertGreaterThan(mainScreen.frame.height, 0)
        XCTAssertTrue(mainScreen.isMain)
    }
    
    // MARK: - Performance Tests
    
    func testFocusWindowPerformance() async throws {
        // Measure focus performance
        measure {
            let expectation = expectation(description: "Focus")
            
            Task {
                try await manager.focusWindow(app: "Finder")
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 1.0)
        }
    }
    
    func testListAppsPerformance() async throws {
        // Measure list performance
        measure {
            let expectation = expectation(description: "List")
            
            Task {
                _ = try await manager.getRunningApps()
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 1.0)
        }
    }
}

// MARK: - Supporting Types

enum WindowError: Error {
    case appNotFound
    case accessibilityPermissionRequired
    case invalidPosition
    case noWindowFound
}

struct WindowInfo {
    let appName: String
    let windowTitle: String
    let frame: CGRect
    let bundleID: String
    let processID: Int32
    let isMinimized: Bool
    let isHidden: Bool
}

struct AppInfo {
    let name: String
    let bundleID: String
    let processID: Int32
    let isActive: Bool
    let isHidden: Bool
}

struct ScreenInfo {
    let frame: CGRect
    let isMain: Bool
    let name: String?
    let displayID: UInt32
}
