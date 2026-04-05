#!/usr/bin/env swift

import Foundation

// Direct test of QA analyzer without GUI

print("=== ScreenMuse QA Direct Test ===\n")

// Test 1: Check if FFProbe is available
let ffprobeCheck = Process()
ffprobeCheck.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
ffprobeCheck.arguments = ["-version"]

do {
    try ffprobeCheck.run()
    ffprobeCheck.waitUntilExit()
    
    if ffprobeCheck.terminationStatus == 0 {
        print("✅ ffprobe is available")
    } else {
        print("❌ ffprobe failed")
    }
} catch {
    print("❌ ffprobe not found: \(error)")
}

// Test 2: Create test video
print("\n=== Creating Test Video ===")

let testDir = "/tmp/screenmuse-qa-test"
try? FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

let originalPath = "\(testDir)/original.mp4"
let processedPath = "\(testDir)/processed.mp4"

// Create 5-second test video
let createVideo = Process()
createVideo.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
createVideo.arguments = [
    "-f", "lavfi",
    "-i", "testsrc=duration=5:size=1920x1080:rate=30",
    "-f", "lavfi",
    "-i", "sine=frequency=1000:duration=5",
    "-pix_fmt", "yuv420p",
    "-c:v", "libx264",
    "-c:a", "aac",
    "-y",
    originalPath
]

do {
    print("Creating original.mp4...")
    try createVideo.run()
    createVideo.waitUntilExit()
    
    if createVideo.terminationStatus == 0 {
        print("✅ Created test video: \(originalPath)")
    } else {
        print("❌ Failed to create video")
    }
} catch {
    print("❌ Error creating video: \(error)")
}

// Create processed version (trimmed to 3s)
let processVideo = Process()
processVideo.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
processVideo.arguments = [
    "-i", originalPath,
    "-t", "3",
    "-c", "copy",
    "-y",
    processedPath
]

do {
    print("Creating processed.mp4...")
    try processVideo.run()
    processVideo.waitUntilExit()
    
    if processVideo.terminationStatus == 0 {
        print("✅ Created processed video: \(processedPath)")
    } else {
        print("❌ Failed to create processed video")
    }
} catch {
    print("❌ Error processing video: \(error)")
}

// Test 3: Extract metadata with ffprobe
print("\n=== Testing Metadata Extraction ===")

func getMetadata(_ path: String) -> String? {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
    probe.arguments = [
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        path
    ]
    
    let pipe = Pipe()
    probe.standardOutput = pipe
    
    do {
        try probe.run()
        probe.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    } catch {
        print("Error running ffprobe: \(error)")
        return nil
    }
}

if let originalMeta = getMetadata(originalPath) {
    print("✅ Extracted metadata from original")
    // Parse duration
    if let data = originalMeta.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let format = json["format"] as? [String: Any],
       let duration = format["duration"] as? String {
        print("   Duration: \(duration)s")
    }
} else {
    print("❌ Failed to extract metadata")
}

if let processedMeta = getMetadata(processedPath) {
    print("✅ Extracted metadata from processed")
    if let data = processedMeta.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let format = json["format"] as? [String: Any],
       let duration = format["duration"] as? String {
        print("   Duration: \(duration)s")
    }
} else {
    print("❌ Failed to extract processed metadata")
}

// Test 4: File size comparison
print("\n=== File Size Comparison ===")

if let originalSize = try? FileManager.default.attributesOfItem(atPath: originalPath)[.size] as? Int64,
   let processedSize = try? FileManager.default.attributesOfItem(atPath: processedPath)[.size] as? Int64 {
    let changePercent = (Double(processedSize - originalSize) / Double(originalSize)) * 100
    print("Original:  \(originalSize) bytes")
    print("Processed: \(processedSize) bytes")
    print("Change:    \(String(format: "%.1f", changePercent))%")
    
    if abs(changePercent) < 100 {
        print("✅ File size change is reasonable")
    } else {
        print("⚠️  Large file size change detected")
    }
} else {
    print("❌ Could not read file sizes")
}

print("\n=== Test Complete ===")
print("Test files: \(testDir)")
