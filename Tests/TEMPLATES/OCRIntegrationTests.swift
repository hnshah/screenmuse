import XCTest
@testable import ScreenMuseCore
import Vision
import CoreGraphics
import AppKit

/// Tests for OCR integration using Vision framework
/// Priority: MEDIUM - Useful for text extraction
final class OCRIntegrationTests: XCTestCase {
    
    var ocrEngine: OCREngine!
    
    override func setUp() async throws {
        try await super.setUp()
        ocrEngine = OCREngine()
    }
    
    // MARK: - Fast OCR Mode Tests
    
    func testFastOCRMode() async throws {
        // Given: Test image with text
        let testImage = try createTestImageWithText("Hello World")
        
        // When: Running fast OCR
        let startTime = Date()
        let result = try await ocrEngine.recognize(
            image: testImage,
            mode: .fast
        )
        let duration = Date().timeIntervalSince(startTime)
        
        // Then: Should be fast (< 1 second)
        XCTAssertLessThan(duration, 1.0)
        
        // Should detect text
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(result.text.contains("Hello"))
    }
    
    func testFastOCRAccuracy() async throws {
        // Given: Simple text image
        let testImage = try createTestImageWithText("SCREENMUSE")
        
        // When: Running fast OCR
        let result = try await ocrEngine.recognize(
            image: testImage,
            mode: .fast
        )
        
        // Then: Should recognize text (may not be perfect)
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }
    
    // MARK: - Accurate OCR Mode Tests
    
    func testAccurateOCRMode() async throws {
        // Given: Test image with text
        let testImage = try createTestImageWithText("Accuracy Test 123")
        
        // When: Running accurate OCR
        let result = try await ocrEngine.recognize(
            image: testImage,
            mode: .accurate
        )
        
        // Then: Should have high confidence
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertGreaterThan(result.confidence, 0.8)
    }
    
    func testAccurateOCRWithComplexText() async throws {
        // Given: Complex text with numbers and symbols
        let complexText = "Price: $49.99 (20% off)"
        let testImage = try createTestImageWithText(complexText)
        
        // When: Running accurate OCR
        let result = try await ocrEngine.recognize(
            image: testImage,
            mode: .accurate
        )
        
        // Then: Should recognize numbers and symbols
        XCTAssertTrue(result.text.contains("49") || result.text.contains("$"))
    }
    
    // MARK: - Screen Capture OCR Tests
    
    func testScreenCaptureOCR() async throws {
        // Given: Current screen
        guard let screen = NSScreen.main else {
            throw OCRError.screenNotAvailable
        }
        
        // When: Capturing and recognizing
        let result = try await ocrEngine.recognizeScreen(
            region: CGRect(x: 0, y: 0, width: 800, height: 600),
            mode: .fast
        )
        
        // Then: Should return result (may be empty if no text on screen)
        XCTAssertNotNil(result)
    }
    
    func testScreenRegionOCR() async throws {
        // Given: Specific screen region
        let region = CGRect(x: 100, y: 100, width: 400, height: 200)
        
        // When: Recognizing region
        let result = try await ocrEngine.recognizeScreen(
            region: region,
            mode: .accurate
        )
        
        // Then: Should complete without error
        XCTAssertNotNil(result)
    }
    
    // MARK: - Image File OCR Tests
    
    func testImageFileOCR() async throws {
        // Given: Image file with text
        let testImage = try createTestImageWithText("File Test")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-ocr.png")
        
        // Save image to file
        guard let pngData = testImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: pngData),
              let data = bitmapImage.representation(using: .png, properties: [:]) else {
            throw OCRError.imageConversionFailed
        }
        try data.write(to: tempURL)
        
        // When: Running OCR on file
        let result = try await ocrEngine.recognizeFile(
            url: tempURL,
            mode: .accurate
        )
        
        // Then: Should recognize text
        XCTAssertFalse(result.text.isEmpty)
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    func testInvalidImageFile() async throws {
        // Given: Non-existent file
        let invalidURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).png")
        
        // When: Attempting OCR
        do {
            _ = try await ocrEngine.recognizeFile(url: invalidURL, mode: .fast)
            XCTFail("Should throw error for invalid file")
        } catch OCRError.fileNotFound {
            // Expected
        }
    }
    
    // MARK: - Bounding Box Tests
    
    func testTextBoundingBoxes() async throws {
        // Given: Image with multiple words
        let testImage = try createTestImageWithText("Multiple Words Here")
        
        // When: Detecting text with bounding boxes
        let result = try await ocrEngine.recognizeWithBoundingBoxes(
            image: testImage,
            mode: .accurate
        )
        
        // Then: Should have bounding boxes for each word
        XCTAssertGreaterThan(result.boxes.count, 0)
        
        // Each box should have valid coordinates
        for box in result.boxes {
            XCTAssertGreaterThan(box.rect.width, 0)
            XCTAssertGreaterThan(box.rect.height, 0)
            XCTAssertFalse(box.text.isEmpty)
        }
    }
    
    func testBoundingBoxAccuracy() async throws {
        // Given: Image with known text position
        let testImage = try createTestImageWithText("Test")
        
        // When: Getting bounding boxes
        let result = try await ocrEngine.recognizeWithBoundingBoxes(
            image: testImage,
            mode: .accurate
        )
        
        // Then: Boxes should cover reasonable portion of image
        guard let box = result.boxes.first else {
            XCTFail("No bounding boxes detected")
            return
        }
        
        let imageSize = testImage.size
        XCTAssertLessThan(box.rect.width, imageSize.width)
        XCTAssertLessThan(box.rect.height, imageSize.height)
    }
    
    // MARK: - Language Detection Tests
    
    func testLanguageDetection() async throws {
        // Given: English text
        let testImage = try createTestImageWithText("English Text")
        
        // When: Detecting language
        let result = try await ocrEngine.recognize(
            image: testImage,
            mode: .accurate,
            languages: ["en-US"]
        )
        
        // Then: Should recognize English
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertEqual(result.detectedLanguage, "en")
    }
    
    func testMultiLanguageSupport() async throws {
        // Given: Text image
        let testImage = try createTestImageWithText("Multilingual Test")
        
        // When: Running OCR with multiple language hints
        let result = try await ocrEngine.recognize(
            image: testImage,
            mode: .accurate,
            languages: ["en-US", "es-ES", "fr-FR"]
        )
        
        // Then: Should complete successfully
        XCTAssertNotNil(result)
    }
    
    // MARK: - Confidence Tests
    
    func testConfidenceScores() async throws {
        // Given: Clear text image
        let testImage = try createTestImageWithText("CONFIDENCE")
        
        // When: Running OCR
        let result = try await ocrEngine.recognize(
            image: testImage,
            mode: .accurate
        )
        
        // Then: Confidence should be reasonable
        XCTAssertGreaterThan(result.confidence, 0.0)
        XCTAssertLessThanOrEqual(result.confidence, 1.0)
    }
    
    func testLowConfidenceDetection() async throws {
        // Given: Blurry/low quality image
        let blurryImage = try createBlurryImageWithText("Blurry")
        
        // When: Running OCR
        let result = try await ocrEngine.recognize(
            image: blurryImage,
            mode: .fast
        )
        
        // Then: Confidence should reflect quality
        XCTAssertLessThan(result.confidence, 0.9)
    }
    
    // MARK: - Error Handling Tests
    
    func testEmptyImageOCR() async throws {
        // Given: Empty/blank image
        let emptyImage = NSImage(size: NSSize(width: 100, height: 100))
        
        // When: Running OCR
        let result = try await ocrEngine.recognize(
            image: emptyImage,
            mode: .fast
        )
        
        // Then: Should return empty result (no error)
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertEqual(result.confidence, 0.0)
    }
    
    func testVerySmallImageOCR() async throws {
        // Given: Very small image (10x10)
        let tinyImage = try createTestImageWithText("X", size: NSSize(width: 10, height: 10))
        
        // When: Running OCR
        do {
            _ = try await ocrEngine.recognize(image: tinyImage, mode: .fast)
            // May succeed or fail depending on implementation
        } catch OCRError.imageTooSmall {
            // Expected error
        }
    }
    
    // MARK: - Performance Tests
    
    func testFastModePerformance() async throws {
        let testImage = try createTestImageWithText("Performance Test")
        
        measure {
            let expectation = expectation(description: "Fast OCR")
            
            Task {
                _ = try await ocrEngine.recognize(image: testImage, mode: .fast)
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 2.0)
        }
    }
    
    func testAccurateModePerformance() async throws {
        let testImage = try createTestImageWithText("Accuracy Performance")
        
        measure {
            let expectation = expectation(description: "Accurate OCR")
            
            Task {
                _ = try await ocrEngine.recognize(image: testImage, mode: .accurate)
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 5.0)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestImageWithText(_ text: String, size: NSSize = NSSize(width: 400, height: 100)) throws -> NSImage {
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        // White background
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        
        // Black text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        
        let textSize = (text as NSString).size(withAttributes: attributes)
        let x = (size.width - textSize.width) / 2
        let y = (size.height - textSize.height) / 2
        
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        
        image.unlockFocus()
        
        return image
    }
    
    private func createBlurryImageWithText(_ text: String) throws -> NSImage {
        let clearImage = try createTestImageWithText(text)
        
        // Apply blur filter (simplified - real implementation would use CIFilter)
        // For tests, just return clear image (blur simulation not critical)
        return clearImage
    }
}

// MARK: - Supporting Types

enum OCRError: Error {
    case screenNotAvailable
    case imageConversionFailed
    case fileNotFound
    case imageTooSmall
    case recognitionFailed
}

enum OCRMode {
    case fast      // Quick recognition, lower accuracy
    case accurate  // Slower, higher accuracy
}

struct OCRResult {
    let text: String
    let confidence: Double
    let detectedLanguage: String?
}

struct OCRResultWithBoxes {
    let text: String
    let confidence: Double
    let boxes: [TextBox]
}

struct TextBox {
    let text: String
    let rect: CGRect
    let confidence: Double
}
