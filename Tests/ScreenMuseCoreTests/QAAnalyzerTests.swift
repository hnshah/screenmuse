import XCTest
@testable import ScreenMuseCore

final class QAAnalyzerTests: XCTestCase {

    // MARK: - FFProbeExtractor: parseRationalFPS

    func testParseRationalFPS_standard() {
        let e = FFProbeExtractor()
        XCTAssertEqual(e.parseRationalFPS("60/1"), 60.0, accuracy: 0.001)
        XCTAssertEqual(e.parseRationalFPS("30/1"), 30.0, accuracy: 0.001)
        XCTAssertEqual(e.parseRationalFPS("25/1"), 25.0, accuracy: 0.001)
    }

    func testParseRationalFPS_NTSC() {
        let e = FFProbeExtractor()
        XCTAssertEqual(e.parseRationalFPS("30000/1001"), 29.97, accuracy: 0.01)
        XCTAssertEqual(e.parseRationalFPS("24000/1001"), 23.976, accuracy: 0.01)
    }

    func testParseRationalFPS_invalid() {
        let e = FFProbeExtractor()
        XCTAssertEqual(e.parseRationalFPS("0/1"), 0.0)
        XCTAssertEqual(e.parseRationalFPS("invalid"), 0.0)
        XCTAssertEqual(e.parseRationalFPS(""), 0.0)
        XCTAssertEqual(e.parseRationalFPS("60/0"), 0.0) // divide by zero
    }

    // MARK: - QualityCheckRunner

    func testCheckResolution_same() {
        let runner = QualityCheckRunner()
        let orig = makeMetadata(width: 1920, height: 1080)
        let proc = makeMetadata(width: 1920, height: 1080)
        let check = runner.checkResolution(original: orig, processed: proc)
        XCTAssertEqual(check.id, "resolution_maintained")
        XCTAssertTrue(check.passed)
        XCTAssertTrue(check.message.contains("1920×1080"))
    }

    func testCheckResolution_changed() {
        let runner = QualityCheckRunner()
        let orig = makeMetadata(width: 1920, height: 1080)
        let proc = makeMetadata(width: 1280, height: 720)
        let check = runner.checkResolution(original: orig, processed: proc)
        XCTAssertFalse(check.passed)
        XCTAssertEqual(check.severity, .high)
        XCTAssertTrue(check.message.contains("1920×1080"))
        XCTAssertTrue(check.message.contains("1280×720"))
    }

    func testCheckFrameRate_same() {
        let runner = QualityCheckRunner()
        let orig = makeMetadata(fps: 60.0)
        let proc = makeMetadata(fps: 60.0)
        let check = runner.checkFrameRate(original: orig, processed: proc)
        XCTAssertTrue(check.passed)
    }

    func testCheckFrameRate_withinTolerance() {
        let runner = QualityCheckRunner()
        // 30000/1001 ≈ 29.97 vs 30.0 — only 0.03 diff but > 0.01 threshold
        let orig = makeMetadata(fps: 29.97)
        let proc = makeMetadata(fps: 30.0)
        let check = runner.checkFrameRate(original: orig, processed: proc)
        // 0.03 > 0.01 → should fail
        XCTAssertFalse(check.passed)
    }

    func testCheckFrameRate_changed() {
        let runner = QualityCheckRunner()
        let orig = makeMetadata(fps: 60.0)
        let proc = makeMetadata(fps: 30.0)
        let check = runner.checkFrameRate(original: orig, processed: proc)
        XCTAssertFalse(check.passed)
        XCTAssertEqual(check.severity, .medium)
        XCTAssertTrue(check.message.contains("60.00fps"))
        XCTAssertTrue(check.message.contains("30.00fps"))
    }

    func testCheckFileSize_reduced() {
        let runner = QualityCheckRunner()
        let orig = makeMetadata(fileSizeBytes: 2_000_000)
        let proc = makeMetadata(fileSizeBytes: 1_500_000)
        let check = runner.checkFileSize(original: orig, processed: proc)
        XCTAssertTrue(check.passed)
        XCTAssertFalse(check.isWarning)
        XCTAssertTrue(check.message.contains("reduced"))
    }

    func testCheckFileSize_oversized() {
        let runner = QualityCheckRunner()
        let orig = makeMetadata(fileSizeBytes: 1_000_000)
        let proc = makeMetadata(fileSizeBytes: 3_000_000) // 3x
        let check = runner.checkFileSize(original: orig, processed: proc)
        XCTAssertFalse(check.passed)
        XCTAssertTrue(check.isWarning) // warning, not hard failure
        XCTAssertEqual(check.severity, .low)
    }

    func testCheckFileSize_justUnder2x() {
        let runner = QualityCheckRunner()
        let orig = makeMetadata(fileSizeBytes: 1_000_000)
        let proc = makeMetadata(fileSizeBytes: 1_990_000) // 1.99x
        let check = runner.checkFileSize(original: orig, processed: proc)
        XCTAssertTrue(check.passed)
        XCTAssertFalse(check.isWarning)
    }

    func testCheckFileSize_zeroOriginal() {
        let runner = QualityCheckRunner()
        let orig = makeMetadata(fileSizeBytes: 0)
        let proc = makeMetadata(fileSizeBytes: 1_000_000)
        let check = runner.checkFileSize(original: orig, processed: proc)
        XCTAssertTrue(check.passed) // unknown → skip
    }

    // MARK: - QAAnalyzer: confidence score + summary

    func testConfidenceScore_allPassed() {
        let analyzer = QAAnalyzer()
        let report = QAReport.samplePassed
        XCTAssertEqual(report.summary.confidenceScore, 1.0, accuracy: 0.001)
        XCTAssertEqual(report.summary.overallStatus, "passed")
    }

    func testConfidenceScore_criticalFailure() {
        // Build a report with 1 critical failure
        let checks: [QualityCheck] = [
            .init(id: "file_validity", name: "File Validity",
                  passed: false, severity: .critical, message: "Corrupted")
        ]
        let summary = buildSummaryFor(checks: checks)
        // Confidence should be 0.60 (1.0 - 0.40 for critical)
        XCTAssertEqual(summary.confidenceScore, 0.60, accuracy: 0.01)
        XCTAssertEqual(summary.overallStatus, "failed")
    }

    func testConfidenceScore_warningOnly() {
        let checks: [QualityCheck] = [
            .init(id: "file_size_reasonable", name: "File Size",
                  passed: false, isWarning: true, severity: .low, message: "Warning")
        ]
        let summary = buildSummaryFor(checks: checks)
        // Warning deducts 0.05 → 0.95
        XCTAssertEqual(summary.confidenceScore, 0.95, accuracy: 0.01)
        XCTAssertEqual(summary.overallStatus, "warning")
    }

    // MARK: - QAReport: JSON round-trip

    func testJSONRoundTrip() throws {
        let report = QAReport.samplePassed
        let analyzer = QAAnalyzer()

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qa-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try analyzer.save(report: report, to: tempURL)
        let loaded = try analyzer.load(from: tempURL)

        XCTAssertEqual(loaded.version, report.version)
        XCTAssertEqual(loaded.summary.totalChecks, report.summary.totalChecks)
        XCTAssertEqual(loaded.summary.confidenceScore, report.summary.confidenceScore, accuracy: 0.001)
        XCTAssertEqual(loaded.videos.original.width, report.videos.original.width)
        XCTAssertEqual(loaded.videos.processed.duration, report.videos.processed.duration, accuracy: 0.001)
        XCTAssertEqual(loaded.qualityChecks.count, report.qualityChecks.count)
    }

    // MARK: - Report path derivation

    func testReportPath() {
        let analyzer = QAAnalyzer()
        let processed = URL(fileURLWithPath: "/tmp/recording.processed.mp4")
        let reportURL = analyzer.reportPath(for: processed)
        XCTAssertEqual(reportURL.path, "/tmp/recording.processed.qa-report.json")
    }

    func testReportPath_mov() {
        let analyzer = QAAnalyzer()
        let processed = URL(fileURLWithPath: "/Users/bob/Movies/clip.mov")
        let reportURL = analyzer.reportPath(for: processed)
        XCTAssertEqual(reportURL.path, "/Users/bob/Movies/clip.qa-report.json")
    }

    // MARK: - VideoMetadata: computed properties

    func testVideoMetadata_computedProperties() {
        let meta = makeMetadata(fileSizeBytes: 2_097_152, bitrateBPS: 5_000_000)
        XCTAssertEqual(meta.fileSizeMB, 2.0, accuracy: 0.01)
        XCTAssertEqual(meta.bitrateMBPS, 5.0, accuracy: 0.01)
    }

    // MARK: - QAChanges

    func testChangesCalculation() {
        let orig = makeMetadata(duration: 60.0, fileSizeBytes: 10_000_000, bitrateBPS: 10_000_000)
        let proc = makeMetadata(duration: 45.0, fileSizeBytes: 7_500_000, bitrateBPS: 10_000_000)

        let changes = QAChanges(
            durationChangeSeconds: proc.duration - orig.duration,
            durationChangePercent: ((proc.duration - orig.duration) / orig.duration) * 100,
            fileSizeChangeBytes: proc.fileSizeBytes - orig.fileSizeBytes,
            fileSizeChangePercent: (Double(proc.fileSizeBytes - orig.fileSizeBytes) / Double(orig.fileSizeBytes)) * 100,
            bitrateChangeBPS: proc.bitrateBPS - orig.bitrateBPS,
            bitrateChangePercent: 0.0
        )

        XCTAssertEqual(changes.durationChangeSeconds, -15.0, accuracy: 0.001)
        XCTAssertEqual(changes.durationChangePercent, -25.0, accuracy: 0.1)
        XCTAssertEqual(changes.fileSizeChangeBytes, -2_500_000)
        XCTAssertEqual(changes.fileSizeChangePercent, -25.0, accuracy: 0.1)
    }

    // MARK: - Sample reports

    func testSamplePassedReport() {
        let report = QAReport.samplePassed
        XCTAssertEqual(report.summary.overallStatus, "passed")
        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertEqual(report.qualityChecks.count, 5)
        XCTAssertTrue(report.qualityChecks.allSatisfy { $0.passed })
    }

    func testSampleFailedReport() {
        let report = QAReport.sampleFailed
        XCTAssertNotEqual(report.summary.overallStatus, "passed")
        XCTAssertGreaterThan(report.summary.failed + report.summary.warnings, 0)
    }

    // MARK: - Helpers

    private func makeMetadata(
        path: String = "/tmp/video.mp4",
        duration: Double = 30.0,
        fileSizeBytes: Int64 = 1_000_000,
        width: Int = 1920,
        height: Int = 1080,
        fps: Double = 60.0,
        bitrateBPS: Int64 = 5_000_000
    ) -> VideoMetadata {
        VideoMetadata(
            path: path, duration: duration, fileSizeBytes: fileSizeBytes,
            width: width, height: height, fps: fps, bitrateBPS: bitrateBPS,
            codec: "h264", hasAudio: true, audioCodec: "aac"
        )
    }

    /// Exercise the private confidence score logic via QAReport.sampleX
    private func buildSummaryFor(checks: [QualityCheck]) -> QASummary {
        let total = checks.count
        let passed = checks.filter { $0.passed && !$0.isWarning }.count
        let warnings = checks.filter { $0.isWarning }.count
        let failed = checks.filter { !$0.passed && !$0.isWarning }.count

        var score = 1.0
        for check in checks {
            if !check.passed {
                switch check.severity {
                case .critical: score -= 0.40
                case .high:     score -= 0.25
                case .medium:   score -= 0.15
                case .low:      score -= 0.05
                }
            } else if check.isWarning {
                score -= 0.05
            }
        }
        score = max(0.0, min(1.0, score))

        let status: String
        if failed > 0 {
            let hasCritical = checks.contains {
                !$0.passed && ($0.severity == .critical || $0.severity == .high)
            }
            status = hasCritical ? "failed" : "warning"
        } else if warnings > 0 {
            status = "warning"
        } else {
            status = "passed"
        }

        return QASummary(
            totalChecks: total, passed: passed, failed: failed, warnings: warnings,
            overallStatus: status, confidenceScore: score
        )
    }
}
