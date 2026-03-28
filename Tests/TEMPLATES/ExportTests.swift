import XCTest
@testable import ScreenMuseCore
import AVFoundation

/// Tests for video export and processing
/// Priority: HIGH - Core export functionality
final class ExportTests: XCTestCase {
    
    var testVideoURL: URL!
    var exporter: VideoExporter!
    
    override func setUp() async throws {
        try await super.setUp()
        exporter = VideoExporter()
        testVideoURL = try await createTestVideo()
    }
    
    override func tearDown() async throws {
        // Cleanup test video
        if let url = testVideoURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func createTestVideo() async throws -> URL {
        // Create a simple test video (black screen, 5 seconds, 1920x1080)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).mp4")
        
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080
        ]
        
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        
        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // Generate 5 seconds of black frames (30fps = 150 frames)
        let frameDuration = CMTime(value: 1, timescale: 30)
        for frameNum in 0..<150 {
            let presentationTime = CMTime(value: Int64(frameNum), timescale: 30)
            
            autoreleasepool {
                let pixelBuffer = createBlackPixelBuffer()
                let sampleBuffer = createSampleBuffer(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
                
                while !videoInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                videoInput.append(sampleBuffer)
            }
        }
        
        videoInput.markAsFinished()
        await writer.finishWriting()
        
        return outputURL
    }
    
    private func createBlackPixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920,
            1080,
            kCVPixelFormatType_32ARGB,
            nil,
            &pixelBuffer
        )
        
        CVPixelBufferLockBaseAddress(pixelBuffer!, .readOnly)
        let data = CVPixelBufferGetBaseAddress(pixelBuffer!)
        memset(data, 0, CVPixelBufferGetDataSize(pixelBuffer!))
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, .readOnly)
        
        return pixelBuffer!
    }
    
    private func createSampleBuffer(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMFormatDescription?
        
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription!,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        return sampleBuffer!
    }
    
    private func getVideoDuration(_ url: URL) async throws -> Double {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        return duration.seconds
    }
    
    private func getVideoResolution(_ url: URL) async throws -> CGSize {
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw ExportError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        return size
    }
    
    // MARK: - GIF Export Tests
    
    func testGIFExport() async throws {
        // Given: Test video
        XCTAssertTrue(FileManager.default.fileExists(atPath: testVideoURL.path))
        
        // When: Exporting as GIF
        let gifURL = try await exporter.exportAsGIF(
            source: testVideoURL,
            fps: 10,
            scale: 800
        )
        
        // Then: GIF file should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: gifURL.path))
        XCTAssertEqual(gifURL.pathExtension, "gif")
        
        // Verify file size is reasonable (not too large)
        let attributes = try FileManager.default.attributesOfItem(atPath: gifURL.path)
        let fileSize = attributes[.size] as! Int64
        XCTAssertGreaterThan(fileSize, 0)
        XCTAssertLessThan(fileSize, 50_000_000) // < 50MB for 5s video
    }
    
    func testGIFExportWithCustomFPS() async throws {
        // When: Exporting with different FPS
        let gif15fps = try await exporter.exportAsGIF(
            source: testVideoURL,
            fps: 15,
            scale: 800
        )
        
        let gif30fps = try await exporter.exportAsGIF(
            source: testVideoURL,
            fps: 30,
            scale: 800
        )
        
        // Then: Higher FPS should produce larger file
        let size15 = try FileManager.default.attributesOfItem(atPath: gif15fps.path)[.size] as! Int64
        let size30 = try FileManager.default.attributesOfItem(atPath: gif30fps.path)[.size] as! Int64
        
        XCTAssertGreaterThan(size30, size15)
    }
    
    func testGIFExportWithScaling() async throws {
        // When: Exporting at different scales
        let gifSmall = try await exporter.exportAsGIF(
            source: testVideoURL,
            fps: 10,
            scale: 400 // Smaller
        )
        
        let gifLarge = try await exporter.exportAsGIF(
            source: testVideoURL,
            fps: 10,
            scale: 1200 // Larger
        )
        
        // Then: Larger scale should produce larger file
        let sizeSmall = try FileManager.default.attributesOfItem(atPath: gifSmall.path)[.size] as! Int64
        let sizeLarge = try FileManager.default.attributesOfItem(atPath: gifLarge.path)[.size] as! Int64
        
        XCTAssertGreaterThan(sizeLarge, sizeSmall)
    }
    
    // MARK: - WebP Export Tests
    
    func testWebPExport() async throws {
        // When: Exporting as WebP
        let webpURL = try await exporter.exportAsWebP(
            source: testVideoURL,
            quality: 80
        )
        
        // Then: WebP file should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: webpURL.path))
        XCTAssertEqual(webpURL.pathExtension, "webp")
    }
    
    func testWebPQuality() async throws {
        // When: Exporting with different quality settings
        let webpLowQuality = try await exporter.exportAsWebP(
            source: testVideoURL,
            quality: 50
        )
        
        let webpHighQuality = try await exporter.exportAsWebP(
            source: testVideoURL,
            quality: 95
        )
        
        // Then: Higher quality should produce larger file
        let sizeLow = try FileManager.default.attributesOfItem(atPath: webpLowQuality.path)[.size] as! Int64
        let sizeHigh = try FileManager.default.attributesOfItem(atPath: webpHighQuality.path)[.size] as! Int64
        
        XCTAssertGreaterThan(sizeHigh, sizeLow)
    }
    
    // MARK: - Trim Tests
    
    func testTrimVideo() async throws {
        // When: Trimming to 2 seconds
        let trimmedURL = try await exporter.trim(
            source: testVideoURL,
            start: 1.0,
            end: 3.0
        )
        
        // Then: Duration should be approximately 2 seconds
        let duration = try await getVideoDuration(trimmedURL)
        XCTAssertEqual(duration, 2.0, accuracy: 0.1)
        
        // File should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: trimmedURL.path))
    }
    
    func testTrimWithStreamCopy() async throws {
        // When: Trimming with stream copy (fast, not frame-accurate)
        let trimmedURL = try await exporter.trim(
            source: testVideoURL,
            start: 0,
            end: 2,
            reencode: false
        )
        
        // Then: Should be fast and produce file
        XCTAssertTrue(FileManager.default.fileExists(atPath: trimmedURL.path))
        
        let duration = try await getVideoDuration(trimmedURL)
        XCTAssertEqual(duration, 2.0, accuracy: 0.5) // Less accurate
    }
    
    func testTrimWithReencode() async throws {
        // When: Trimming with re-encode (slow, frame-accurate)
        let trimmedURL = try await exporter.trim(
            source: testVideoURL,
            start: 1,
            end: 3,
            reencode: true
        )
        
        // Then: Should be more accurate
        let duration = try await getVideoDuration(trimmedURL)
        XCTAssertEqual(duration, 2.0, accuracy: 0.1) // More accurate
    }
    
    func testTrimInvalidRange() async throws {
        // When: Trimming with invalid range
        do {
            _ = try await exporter.trim(
                source: testVideoURL,
                start: 10, // Beyond video length
                end: 15
            )
            XCTFail("Should throw error for invalid range")
        } catch ExportError.invalidTimeRange {
            // Expected
        }
    }
    
    // MARK: - Crop Tests
    
    func testCropVideo() async throws {
        // When: Cropping a region
        let cropRect = CGRect(x: 100, y: 100, width: 800, height: 600)
        let croppedURL = try await exporter.crop(
            source: testVideoURL,
            rect: cropRect
        )
        
        // Then: Resolution should match crop
        let size = try await getVideoResolution(croppedURL)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }
    
    func testCropCenter() async throws {
        // When: Cropping center region
        let cropRect = CGRect(x: 460, y: 290, width: 1000, height: 500)
        let croppedURL = try await exporter.crop(
            source: testVideoURL,
            rect: cropRect
        )
        
        // Then: Should produce valid video
        XCTAssertTrue(FileManager.default.fileExists(atPath: croppedURL.path))
        let size = try await getVideoResolution(croppedURL)
        XCTAssertEqual(size.width, 1000)
        XCTAssertEqual(size.height, 500)
    }
    
    func testCropInvalidRect() async throws {
        // When: Cropping with invalid rect (outside bounds)
        let cropRect = CGRect(x: 2000, y: 1500, width: 500, height: 500)
        
        do {
            _ = try await exporter.crop(
                source: testVideoURL,
                rect: cropRect
            )
            XCTFail("Should throw error for out-of-bounds crop")
        } catch ExportError.invalidCropRegion {
            // Expected
        }
    }
    
    // MARK: - Speed Ramp Tests
    
    func testSpeedRamp() async throws {
        // Given: Cursor data indicating idle periods
        let cursorData = CursorData(
            events: [
                CursorEvent(timestamp: 0.0, position: CGPoint(x: 100, y: 100)),
                CursorEvent(timestamp: 1.0, position: CGPoint(x: 100, y: 100)), // Idle
                CursorEvent(timestamp: 2.0, position: CGPoint(x: 100, y: 100)), // Idle
                CursorEvent(timestamp: 3.0, position: CGPoint(x: 500, y: 500)), // Active
                CursorEvent(timestamp: 4.0, position: CGPoint(x: 600, y: 600))  // Active
            ]
        )
        
        // When: Applying speed ramp
        let rampedURL = try await exporter.speedRamp(
            source: testVideoURL,
            cursorData: cursorData,
            maxSpeed: 3.0
        )
        
        // Then: Duration should be shorter (idle sections sped up)
        let originalDuration = try await getVideoDuration(testVideoURL)
        let rampedDuration = try await getVideoDuration(rampedURL)
        
        XCTAssertLessThan(rampedDuration, originalDuration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rampedURL.path))
    }
    
    func testSpeedRampNoIdlePeriods() async throws {
        // Given: Cursor data with constant activity (no idle)
        let cursorData = CursorData(
            events: (0..<50).map { i in
                CursorEvent(timestamp: Double(i) * 0.1, position: CGPoint(x: i * 10, y: i * 10))
            }
        )
        
        // When: Applying speed ramp
        let rampedURL = try await exporter.speedRamp(
            source: testVideoURL,
            cursorData: cursorData,
            maxSpeed: 3.0
        )
        
        // Then: Duration should be similar (no idle to speed up)
        let originalDuration = try await getVideoDuration(testVideoURL)
        let rampedDuration = try await getVideoDuration(rampedURL)
        
        XCTAssertEqual(rampedDuration, originalDuration, accuracy: 0.5)
    }
    
    // MARK: - Thumbnail Tests
    
    func testExtractThumbnail() async throws {
        // When: Extracting thumbnail at 2.5s
        let thumbnailURL = try await exporter.thumbnail(
            source: testVideoURL,
            timecode: 2.5
        )
        
        // Then: Image file should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
        XCTAssertTrue(["jpg", "jpeg", "png"].contains(thumbnailURL.pathExtension))
    }
    
    func testExtractThumbnailAtStart() async throws {
        // When: Extracting at t=0
        let thumbnailURL = try await exporter.thumbnail(
            source: testVideoURL,
            timecode: 0
        )
        
        // Then: Should succeed
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
    }
    
    func testExtractThumbnailInvalidTime() async throws {
        // When: Extracting beyond video duration
        do {
            _ = try await exporter.thumbnail(
                source: testVideoURL,
                timecode: 100 // Way beyond 5s video
            )
            XCTFail("Should throw error for invalid timecode")
        } catch ExportError.invalidTimecode {
            // Expected
        }
    }
}

// MARK: - Supporting Types

enum ExportError: Error {
    case noVideoTrack
    case invalidTimeRange
    case invalidCropRegion
    case invalidTimecode
}

struct CursorData {
    let events: [CursorEvent]
}

struct CursorEvent {
    let timestamp: Double
    let position: CGPoint
}
