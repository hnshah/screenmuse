import Foundation
import SwiftUI
import ScreenMuseCore

/// View model for QA Report modal
@MainActor
public class QAReportViewModel: ObservableObject {
    @Published var isPresented = false
    @Published var report: QAReport?
    
    public struct QAReport {
        let originalPath: String
        let processedPath: String
        let originalDuration: TimeInterval
        let processedDuration: TimeInterval
        let originalFileSize: Int64
        let processedFileSize: Int64
        let originalBitrate: Double
        let processedBitrate: Double
        let compressionRatio: Double
        let checks: [QualityCheck]
        let editsApplied: EditsApplied
        
        struct QualityCheck {
            let name: String
            let passed: Bool
            let message: String
            let severity: Severity
            
            enum Severity {
                case critical, high, medium, low
            }
        }
        
        struct EditsApplied {
            let pausesRemoved: Int
            let transitionsAdded: Int
            let totalTimeSaved: TimeInterval
        }
        
        var durationChangePercent: Double {
            guard originalDuration > 0 else { return 0 }
            return ((processedDuration - originalDuration) / originalDuration) * 100
        }
        
        var fileSizeChangePercent: Double {
            guard originalFileSize > 0 else { return 0 }
            return ((Double(processedFileSize) - Double(originalFileSize)) / Double(originalFileSize)) * 100
        }
        
        var allChecksPassed: Bool {
            checks.allSatisfy { $0.passed }
        }
        
        var hasWarnings: Bool {
            checks.contains { !$0.passed && $0.severity == .medium }
        }
        
        var hasCriticalIssues: Bool {
            checks.contains { !$0.passed && ($0.severity == .critical || $0.severity == .high) }
        }
    }
    
    public init() {}
    
    /// Show processed video in Finder
    public func showInFinder() {
        guard let report = report else { return }
        let url = URL(fileURLWithPath: report.processedPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    /// Export report as JSON
    public func exportReport() -> URL? {
        guard let report = report else { return nil }
        
        let data: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "original": [
                "path": report.originalPath,
                "duration": report.originalDuration,
                "file_size_bytes": report.originalFileSize,
                "bitrate_bps": report.originalBitrate
            ],
            "processed": [
                "path": report.processedPath,
                "duration": report.processedDuration,
                "file_size_bytes": report.processedFileSize,
                "bitrate_bps": report.processedBitrate
            ],
            "checks": report.checks.map { ["name": $0.name, "passed": $0.passed, "message": $0.message] },
            "edits": [
                "pauses_removed": report.editsApplied.pausesRemoved,
                "time_saved": report.editsApplied.totalTimeSaved
            ]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted])
            let processedURL = URL(fileURLWithPath: report.processedPath)
            let reportURL = processedURL.deletingPathExtension().appendingPathExtension("qa-report.json")
            try jsonData.write(to: reportURL)
            return reportURL
        } catch {
            return nil
        }
    }
}
