import XCTest
@testable import ScreenMuseCore
import Metal
import CoreGraphics

/// Tests for effects and Metal compositing
/// Priority: MEDIUM - Key visual features
final class EffectsCompositingTests: XCTestCase {
    
    var effectsEngine: EffectsEngine!
    var device: MTLDevice!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Initialize Metal device
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw EffectsError.metalNotAvailable
        }
        device = metalDevice
        
        effectsEngine = try EffectsEngine(device: device)
    }
    
    // MARK: - Click Effect Tests
    
    func testClickEffectRender() async throws {
        // Given: Click at position
        let clickPosition = CGPoint(x: 500, y: 400)
        
        // When: Rendering click effect
        let texture = try await effectsEngine.renderClickEffect(
            at: clickPosition,
            radius: 50,
            color: .blue
        )
        
        // Then: Texture should be created
        XCTAssertNotNil(texture)
        XCTAssertEqual(texture.width, 100) // 2x radius
        XCTAssertEqual(texture.height, 100)
    }
    
    func testClickEffectAnimation() async throws {
        // Given: Click animation parameters
        let clickPosition = CGPoint(x: 500, y: 400)
        
        // When: Generating animation frames
        let frames = try await effectsEngine.generateClickAnimation(
            at: clickPosition,
            duration: 0.5,
            fps: 30
        )
        
        // Then: Should generate correct number of frames
        let expectedFrames = Int(0.5 * 30) // duration * fps
        XCTAssertEqual(frames.count, expectedFrames)
        
        // All frames should be valid textures
        for frame in frames {
            XCTAssertNotNil(frame.texture)
            XCTAssertGreaterThan(frame.timestamp, 0)
        }
    }
    
    func testMultipleClickEffects() async throws {
        // Given: Multiple clicks
        let clicks = [
            CGPoint(x: 100, y: 100),
            CGPoint(x: 500, y: 500),
            CGPoint(x: 900, y: 700)
        ]
        
        // When: Rendering all clicks
        var textures: [MTLTexture] = []
        for click in clicks {
            let texture = try await effectsEngine.renderClickEffect(at: click, radius: 40, color: .red)
            textures.append(texture)
        }
        
        // Then: All should render successfully
        XCTAssertEqual(textures.count, 3)
        for texture in textures {
            XCTAssertNotNil(texture)
        }
    }
    
    // MARK: - Zoom Effect Tests
    
    func testZoomCalculation() async throws {
        // Given: Zoom parameters
        let sourceFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let targetPoint = CGPoint(x: 500, y: 400)
        let zoomFactor = 2.0
        
        // When: Calculating zoom region
        let zoomRect = try await effectsEngine.calculateZoomRegion(
            source: sourceFrame,
            target: targetPoint,
            zoom: zoomFactor
        )
        
        // Then: Zoom region should be correct size
        XCTAssertEqual(zoomRect.width, sourceFrame.width / zoomFactor, accuracy: 1.0)
        XCTAssertEqual(zoomRect.height, sourceFrame.height / zoomFactor, accuracy: 1.0)
        
        // Center should be near target point
        let center = CGPoint(x: zoomRect.midX, y: zoomRect.midY)
        XCTAssertEqual(center.x, targetPoint.x, accuracy: 50)
        XCTAssertEqual(center.y, targetPoint.y, accuracy: 50)
    }
    
    func testZoomAnimation() async throws {
        // Given: Zoom animation parameters
        let startRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let endRect = CGRect(x: 400, y: 300, width: 960, height: 540)
        
        // When: Generating zoom animation
        let frames = try await effectsEngine.generateZoomAnimation(
            from: startRect,
            to: endRect,
            duration: 1.0,
            fps: 30,
            easing: .easeInOut
        )
        
        // Then: Should generate smooth transition
        XCTAssertEqual(frames.count, 30)
        
        // First frame should match start
        XCTAssertEqual(frames.first!.rect.width, startRect.width, accuracy: 1.0)
        
        // Last frame should match end
        XCTAssertEqual(frames.last!.rect.width, endRect.width, accuracy: 1.0)
        
        // Middle frames should be interpolated
        let midFrame = frames[frames.count / 2]
        XCTAssertGreaterThan(midFrame.rect.width, endRect.width)
        XCTAssertLessThan(midFrame.rect.width, startRect.width)
    }
    
    // MARK: - Cursor Tracking Tests
    
    func testCursorTracking() async throws {
        // Given: Cursor events
        let events = [
            CursorEvent(timestamp: 0.0, position: CGPoint(x: 100, y: 100)),
            CursorEvent(timestamp: 0.5, position: CGPoint(x: 200, y: 150)),
            CursorEvent(timestamp: 1.0, position: CGPoint(x: 300, y: 200))
        ]
        
        // When: Processing cursor data
        let trail = try await effectsEngine.processCursorTrail(events: events)
        
        // Then: Trail should be generated
        XCTAssertEqual(trail.segments.count, 2) // 3 points = 2 segments
        
        // Each segment should have correct positions
        XCTAssertEqual(trail.segments[0].start, events[0].position)
        XCTAssertEqual(trail.segments[0].end, events[1].position)
    }
    
    func testCursorVelocity() async throws {
        // Given: Cursor events with varying speed
        let events = [
            CursorEvent(timestamp: 0.0, position: CGPoint(x: 0, y: 0)),
            CursorEvent(timestamp: 1.0, position: CGPoint(x: 100, y: 0)),  // 100px/s
            CursorEvent(timestamp: 2.0, position: CGPoint(x: 500, y: 0))   // 400px/s
        ]
        
        // When: Calculating velocities
        let velocities = try await effectsEngine.calculateCursorVelocity(events: events)
        
        // Then: Should detect velocity changes
        XCTAssertEqual(velocities.count, 2)
        XCTAssertEqual(velocities[0], 100, accuracy: 10) // First segment
        XCTAssertEqual(velocities[1], 400, accuracy: 10) // Second segment
    }
    
    // MARK: - Keyboard Event Tests
    
    func testKeyboardEventCapture() async throws {
        // Given: Keyboard events
        let events = [
            KeyboardEvent(timestamp: 0.0, key: "A", modifiers: []),
            KeyboardEvent(timestamp: 0.5, key: "B", modifiers: [.command]),
            KeyboardEvent(timestamp: 1.0, key: "C", modifiers: [.shift])
        ]
        
        // When: Processing keyboard events
        let overlays = try await effectsEngine.generateKeyboardOverlays(events: events)
        
        // Then: Should generate overlays for each event
        XCTAssertEqual(overlays.count, 3)
        
        // Command key should be indicated
        XCTAssertTrue(overlays[1].modifierText.contains("⌘"))
        
        // Shift key should be indicated
        XCTAssertTrue(overlays[2].modifierText.contains("⇧"))
    }
    
    // MARK: - Frame Compositing Tests
    
    func testCompositeFrame() async throws {
        // Given: Base frame and effects
        let baseTexture = try createTestTexture(width: 1920, height: 1080)
        let clickEffect = try await effectsEngine.renderClickEffect(
            at: CGPoint(x: 500, y: 400),
            radius: 50,
            color: .blue
        )
        
        // When: Compositing
        let composited = try await effectsEngine.composite(
            base: baseTexture,
            effects: [clickEffect],
            at: [CGPoint(x: 500, y: 400)]
        )
        
        // Then: Should create new texture with effects
        XCTAssertNotNil(composited)
        XCTAssertEqual(composited.width, baseTexture.width)
        XCTAssertEqual(composited.height, baseTexture.height)
    }
    
    func testCompositeMultipleEffects() async throws {
        // Given: Base frame and multiple effects
        let baseTexture = try createTestTexture(width: 1920, height: 1080)
        
        let effects = [
            try await effectsEngine.renderClickEffect(at: CGPoint(x: 100, y: 100), radius: 30, color: .red),
            try await effectsEngine.renderClickEffect(at: CGPoint(x: 500, y: 500), radius: 40, color: .blue),
            try await effectsEngine.renderClickEffect(at: CGPoint(x: 900, y: 700), radius: 35, color: .green)
        ]
        
        let positions = [
            CGPoint(x: 100, y: 100),
            CGPoint(x: 500, y: 500),
            CGPoint(x: 900, y: 700)
        ]
        
        // When: Compositing all effects
        let composited = try await effectsEngine.composite(
            base: baseTexture,
            effects: effects,
            at: positions
        )
        
        // Then: Should successfully composite all
        XCTAssertNotNil(composited)
    }
    
    // MARK: - Metal Shader Tests
    
    func testShaderPipeline() async throws {
        // When: Creating shader pipeline
        let pipeline = try await effectsEngine.createShaderPipeline(
            vertexFunction: "vertexShader",
            fragmentFunction: "fragmentShader"
        )
        
        // Then: Pipeline should be valid
        XCTAssertNotNil(pipeline)
    }
    
    func testShaderExecution() async throws {
        // Given: Test texture and shader
        let inputTexture = try createTestTexture(width: 100, height: 100)
        
        // When: Executing shader
        let outputTexture = try await effectsEngine.executeShader(
            name: "testShader",
            input: inputTexture
        )
        
        // Then: Output should be generated
        XCTAssertNotNil(outputTexture)
        XCTAssertEqual(outputTexture.width, inputTexture.width)
        XCTAssertEqual(outputTexture.height, inputTexture.height)
    }
    
    // MARK: - Effect Parameters Tests
    
    func testEffectParameterValidation() async throws {
        // When: Creating effect with invalid parameters
        do {
            _ = try await effectsEngine.renderClickEffect(
                at: CGPoint(x: -100, y: -100), // Invalid position
                radius: -50,                    // Invalid radius
                color: .blue
            )
            XCTFail("Should throw error for invalid parameters")
        } catch EffectsError.invalidParameters {
            // Expected
        }
    }
    
    func testEffectColorSupport() async throws {
        // Given: Different colors
        let colors: [EffectColor] = [.red, .blue, .green, .yellow, .purple]
        
        // When: Rendering with each color
        var textures: [MTLTexture] = []
        for color in colors {
            let texture = try await effectsEngine.renderClickEffect(
                at: CGPoint(x: 500, y: 400),
                radius: 50,
                color: color
            )
            textures.append(texture)
        }
        
        // Then: All should render successfully
        XCTAssertEqual(textures.count, colors.count)
    }
    
    // MARK: - Performance Tests
    
    func testClickEffectPerformance() async throws {
        measure {
            let expectation = expectation(description: "Click effect")
            
            Task {
                _ = try await effectsEngine.renderClickEffect(
                    at: CGPoint(x: 500, y: 400),
                    radius: 50,
                    color: .blue
                )
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 0.1)
        }
    }
    
    func testCompositePerformance() async throws {
        // Given: Base texture and effect
        let baseTexture = try createTestTexture(width: 1920, height: 1080)
        let effect = try await effectsEngine.renderClickEffect(
            at: CGPoint(x: 500, y: 400),
            radius: 50,
            color: .blue
        )
        
        measure {
            let expectation = expectation(description: "Composite")
            
            Task {
                _ = try await effectsEngine.composite(
                    base: baseTexture,
                    effects: [effect],
                    at: [CGPoint(x: 500, y: 400)]
                )
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 0.1)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw EffectsError.textureCreationFailed
        }
        
        return texture
    }
}

// MARK: - Supporting Types

enum EffectsError: Error {
    case metalNotAvailable
    case invalidParameters
    case textureCreationFailed
    case shaderCompilationFailed
}

enum EffectColor {
    case red, blue, green, yellow, purple, custom(r: Float, g: Float, b: Float)
}

struct EffectFrame {
    let texture: MTLTexture
    let timestamp: Double
}

struct ZoomFrame {
    let rect: CGRect
    let timestamp: Double
}

struct CursorTrail {
    let segments: [CursorSegment]
}

struct CursorSegment {
    let start: CGPoint
    let end: CGPoint
    let velocity: Double
}

struct KeyboardEvent {
    let timestamp: Double
    let key: String
    let modifiers: [KeyModifier]
}

enum KeyModifier {
    case command, shift, option, control
}

struct KeyboardOverlay {
    let keyText: String
    let modifierText: String
    let timestamp: Double
}

enum EasingFunction {
    case linear
    case easeIn
    case easeOut
    case easeInOut
}
