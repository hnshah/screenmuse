import Foundation

// MARK: - QA Analyzer (Orchestrator)

/// Orchestrates the full QA analysis pipeline:
///   1. Extract metadata from original + processed video via ffprobe
///   2. Run 5 quality checks
///   3. Build QAReport with summary + confidence score
///   4. Save report JSON next to processed video
///
/// Designed to be lightweight and fast (<5s for typical 1080p60 videos).
public final class QAAnalyzer: Sendable {

    public init() {}

    // MARK: - Public API

    /// Analyze original and processed video. Returns a complete `QAReport`.
    ///
    /// - Parameters:
    ///   - original: URL of the original (pre-processing) video.
    ///   - processed: URL of the processed (output) video.
    /// - Returns: Complete `QAReport`.
    /// - Throws: `QAError` if metadata extraction fails for either video.
    public func analyze(original: URL, processed: URL) throws -> QAReport {
        let extractor = FFProbeExtractor()

        // Extract metadata for both videos
        let originalMeta = try extractor.extract(from: original)
        let processedMeta = try extractor.extract(from: processed)

        // Run quality checks
        let checker = QualityCheckRunner()
        let checks = checker.run(
            original: originalMeta,
            processed: processedMeta,
            processedURL: processed
        )

        // Build summary
        let summary = buildSummary(checks: checks)

        // Build changes
        let changes = buildChanges(original: originalMeta, processed: processedMeta)

        return QAReport(
            videos: QAVideos(original: originalMeta, processed: processedMeta),
            qualityChecks: checks,
            summary: summary,
            changes: changes
        )
    }

    /// Analyze and automatically save report to disk beside the processed video.
    ///
    /// Report path: `processed.qa-report.json` (same directory, same stem).
    ///
    /// - Returns: `(report, reportURL)` tuple.
    public func analyzeAndSave(
        original: URL,
        processed: URL
    ) throws -> (QAReport, URL) {
        let report = try analyze(original: original, processed: processed)
        let reportURL = reportPath(for: processed)
        try save(report: report, to: reportURL)
        return (report, reportURL)
    }

    // MARK: - Report persistence

    /// Save `QAReport` as JSON to the given URL.
    public func save(report: QAReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    /// Load a previously saved `QAReport` from disk.
    public func load(from url: URL) throws -> QAReport {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QAReport.self, from: data)
    }

    /// Derive the report JSON path from the processed video URL.
    ///
    /// Example: `recording.processed.mp4` → `recording.processed.qa-report.json`
    public func reportPath(for processedURL: URL) -> URL {
        processedURL
            .deletingPathExtension()
            .appendingPathExtension("qa-report.json")
    }

    // MARK: - Private helpers

    private func buildSummary(checks: [QualityCheck]) -> QASummary {
        let total = checks.count
        let passed = checks.filter { $0.passed && !$0.isWarning }.count
        let warnings = checks.filter { $0.isWarning }.count
        let failed = checks.filter { !$0.passed && !$0.isWarning }.count

        // Confidence score: weighted by severity
        let score = computeConfidenceScore(checks: checks)

        let status: String
        if failed > 0 {
            // Any critical/high failure = "failed"
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
            totalChecks: total,
            passed: passed,
            failed: failed,
            warnings: warnings,
            overallStatus: status,
            confidenceScore: score
        )
    }

    /// Weighted confidence score:
    ///   critical check failure = -0.40
    ///   high check failure = -0.25
    ///   medium check failure = -0.15
    ///   low / warning = -0.05
    private func computeConfidenceScore(checks: [QualityCheck]) -> Double {
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
        return max(0.0, min(1.0, score))
    }

    private func buildChanges(
        original: VideoMetadata,
        processed: VideoMetadata
    ) -> QAChanges {
        let durDelta = processed.duration - original.duration
        let durPct = original.duration > 0
            ? (durDelta / original.duration) * 100.0
            : 0.0

        let sizeDelta = processed.fileSizeBytes - original.fileSizeBytes
        let sizePct = original.fileSizeBytes > 0
            ? (Double(sizeDelta) / Double(original.fileSizeBytes)) * 100.0
            : 0.0

        let bitrateDelta = processed.bitrateBPS - original.bitrateBPS
        let bitratePct = original.bitrateBPS > 0
            ? (Double(bitrateDelta) / Double(original.bitrateBPS)) * 100.0
            : 0.0

        return QAChanges(
            durationChangeSeconds: durDelta,
            durationChangePercent: durPct,
            fileSizeChangeBytes: sizeDelta,
            fileSizeChangePercent: sizePct,
            bitrateChangeBPS: bitrateDelta,
            bitrateChangePercent: bitratePct
        )
    }
}
