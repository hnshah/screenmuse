import Foundation

// MARK: - Sample Reports (for Previews & Tests)

public extension QAReport {

    static var samplePassed: QAReport {
        let orig = VideoMetadata(
            path: "/tmp/recording.mp4",
            duration: 47.234,
            fileSizeBytes: 2_201_600,
            width: 1920, height: 1080,
            fps: 60.0,
            bitrateBPS: 3_500_000,
            codec: "h264",
            hasAudio: true,
            audioCodec: "aac"
        )
        let proc = VideoMetadata(
            path: "/tmp/recording.processed.mp4",
            duration: 34.891,
            fileSizeBytes: 1_884_160,
            width: 1920, height: 1080,
            fps: 60.0,
            bitrateBPS: 4_200_000,
            codec: "h264",
            hasAudio: true,
            audioCodec: "aac"
        )
        let checks: [QualityCheck] = [
            .init(id: "file_validity", name: "File Validity", passed: true,
                  severity: .critical, message: "Video file is valid and playable"),
            .init(id: "resolution_maintained", name: "Resolution Maintained", passed: true,
                  severity: .high, message: "Resolution maintained (1920×1080)"),
            .init(id: "audio_video_sync", name: "Audio/Video Sync", passed: true,
                  severity: .high, message: "Audio and video are in sync (max drift: 0.02s)"),
            .init(id: "frame_rate_maintained", name: "Frame Rate Maintained", passed: true,
                  severity: .medium, message: "Frame rate maintained (60.00fps)"),
            .init(id: "file_size_reasonable", name: "File Size Check", passed: true,
                  severity: .low, message: "File size reduced by 14% (2.1 MB → 1.8 MB)")
        ]
        let summary = QASummary(
            totalChecks: 5, passed: 5, failed: 0, warnings: 0,
            overallStatus: "passed", confidenceScore: 1.0
        )
        let changes = QAChanges(
            durationChangeSeconds: -12.343, durationChangePercent: -26.1,
            fileSizeChangeBytes: -317_440, fileSizeChangePercent: -14.4,
            bitrateChangeBPS: 700_000, bitrateChangePercent: 20.0
        )
        return QAReport(videos: .init(original: orig, processed: proc),
                        qualityChecks: checks, summary: summary, changes: changes)
    }

    static var sampleFailed: QAReport {
        let orig = VideoMetadata(
            path: "/tmp/recording.mp4",
            duration: 47.234, fileSizeBytes: 2_201_600,
            width: 1920, height: 1080, fps: 60.0,
            bitrateBPS: 3_500_000, codec: "h264",
            hasAudio: true, audioCodec: "aac"
        )
        let proc = VideoMetadata(
            path: "/tmp/recording.processed.mp4",
            duration: 47.234, fileSizeBytes: 9_200_000,
            width: 1280, height: 720, fps: 60.0,
            bitrateBPS: 3_500_000, codec: "h264",
            hasAudio: true, audioCodec: "aac"
        )
        let checks: [QualityCheck] = [
            .init(id: "file_validity", name: "File Validity", passed: true,
                  severity: .critical, message: "Video file is valid and playable"),
            .init(id: "resolution_maintained", name: "Resolution Maintained", passed: false,
                  severity: .high, message: "Resolution changed from 1920×1080 to 1280×720"),
            .init(id: "audio_video_sync", name: "Audio/Video Sync", passed: true,
                  severity: .high, message: "Audio and video are in sync (max drift: 0.01s)"),
            .init(id: "frame_rate_maintained", name: "Frame Rate Maintained", passed: true,
                  severity: .medium, message: "Frame rate maintained (60.00fps)"),
            .init(id: "file_size_reasonable", name: "File Size Check", passed: false,
                  isWarning: true, severity: .low,
                  message: "Processed file is 4.2x larger than original — File size increased by 318% (2.1 MB → 8.8 MB)")
        ]
        let summary = QASummary(
            totalChecks: 5, passed: 3, failed: 1, warnings: 1,
            overallStatus: "failed", confidenceScore: 0.70
        )
        let changes = QAChanges(
            durationChangeSeconds: 0, durationChangePercent: 0,
            fileSizeChangeBytes: 6_998_400, fileSizeChangePercent: 317.9,
            bitrateChangeBPS: 0, bitrateChangePercent: 0
        )
        return QAReport(videos: .init(original: orig, processed: proc),
                        qualityChecks: checks, summary: summary, changes: changes)
    }
}
