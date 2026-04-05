import SwiftUI
import ScreenMuseCore

// MARK: - QA Report Modal

/// Modal sheet displayed automatically after video processing.
/// Shows quality checks, before/after metrics, and export/action buttons.
struct QAReportView: View {

    let report: QAReport
    let processedURL: URL
    var onDismiss: () -> Void

    @State private var exportError: String? = nil
    @State private var showExportConfirmation = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    checksSection
                    metricsSection
                }
                .padding(20)
            }

            Divider()

            // Footer buttons
            footerView
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640,
               minHeight: 480, idealHeight: 540, maxHeight: 700)
        .alert("Error", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            if let e = exportError { Text(e) }
        }
        .alert("Report Saved", isPresented: $showExportConfirmation) {
            Button("OK") {}
        } message: {
            Text("QA report saved successfully.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: overallIcon)
                .font(.title2)
                .foregroundColor(overallColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(overallTitle)
                    .font(.headline)
                Text(String(format: "Confidence: %.0f%%", report.summary.confidenceScore * 100))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Check counts pill
            HStack(spacing: 6) {
                if report.summary.passed > 0 {
                    badgePill("\(report.summary.passed)", color: .green)
                }
                if report.summary.warnings > 0 {
                    badgePill("\(report.summary.warnings)", color: .orange)
                }
                if report.summary.failed > 0 {
                    badgePill("\(report.summary.failed)", color: .red)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Quality Checks Section

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Quality Checks")

            VStack(spacing: 6) {
                ForEach(report.qualityChecks, id: \.id) { check in
                    checkRow(check)
                }
            }
        }
    }

    private func checkRow(_ check: QualityCheck) -> some View {
        HStack(spacing: 10) {
            Image(systemName: checkIcon(for: check))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(checkColor(for: check))
                .frame(width: 18)

            Text(check.name)
                .font(.callout)
                .fontWeight(.medium)
                .frame(minWidth: 140, alignment: .leading)

            Text(check.message)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(2)

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(checkBackground(for: check))
        )
    }

    // MARK: - Metrics Section

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Before / After")

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                // Header row
                GridRow {
                    Text("Metric")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Text("Original")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text("Processed")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text("Change")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .gridColumnAlignment(.trailing)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)

                Divider().gridCellColumns(4)

                metricsRow(
                    label: "Duration",
                    original: formatDuration(report.videos.original.duration),
                    processed: formatDuration(report.videos.processed.duration),
                    change: formatChange(
                        report.changes.durationChangeSeconds,
                        percent: report.changes.durationChangePercent,
                        unit: "s"
                    ),
                    changeGoodWhenNegative: true
                )

                metricsRow(
                    label: "File Size",
                    original: formatSize(report.videos.original.fileSizeMB),
                    processed: formatSize(report.videos.processed.fileSizeMB),
                    change: formatChange(
                        Double(report.changes.fileSizeChangeBytes) / 1_048_576,
                        percent: report.changes.fileSizeChangePercent,
                        unit: "MB"
                    ),
                    changeGoodWhenNegative: true
                )

                metricsRow(
                    label: "Bitrate",
                    original: formatBitrate(report.videos.original.bitrateMBPS),
                    processed: formatBitrate(report.videos.processed.bitrateMBPS),
                    change: formatChange(
                        Double(report.changes.bitrateChangeBPS) / 1_000_000,
                        percent: report.changes.bitrateChangePercent,
                        unit: "Mbps"
                    ),
                    changeGoodWhenNegative: false
                )

                metricsRow(
                    label: "Resolution",
                    original: "\(report.videos.original.width)×\(report.videos.original.height)",
                    processed: "\(report.videos.processed.width)×\(report.videos.processed.height)",
                    change: report.videos.original.width == report.videos.processed.width
                        ? "—" : "Changed",
                    changeGoodWhenNegative: false
                )

                metricsRow(
                    label: "Frame Rate",
                    original: String(format: "%.2ffps", report.videos.original.fps),
                    processed: String(format: "%.2ffps", report.videos.processed.fps),
                    change: abs(report.videos.original.fps - report.videos.processed.fps) < 0.01
                        ? "—" : "Changed",
                    changeGoodWhenNegative: false
                )
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }

    private func metricsRow(
        label: String,
        original: String,
        processed: String,
        change: String,
        changeGoodWhenNegative: Bool
    ) -> some View {
        GridRow {
            Text(label)
                .font(.callout)
                .frame(minWidth: 80, alignment: .leading)
            Text(original)
                .font(.callout)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .gridColumnAlignment(.trailing)
            Text(processed)
                .font(.callout)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
            Text(change)
                .font(.callout)
                .monospacedDigit()
                .foregroundColor(changeColor(change, goodWhenNegative: changeGoodWhenNegative))
                .gridColumnAlignment(.trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 10) {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([processedURL])
            }

            Button("Export Report") {
                exportReport()
            }

            Spacer()

            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.escape)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Export

    private func exportReport() {
        let panel = NSSavePanel()
        let stem = processedURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(stem)-qa-report.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.directoryURL = processedURL.deletingLastPathComponent()

        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let analyzer = QAAnalyzer()
        do {
            try analyzer.save(report: report, to: dest)
            showExportConfirmation = true
        } catch {
            exportError = "Could not save report: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private var overallTitle: String {
        switch report.summary.overallStatus {
        case "failed":  return "Quality Issues Detected"
        case "warning": return "Video Processed — With Warnings"
        default:        return "Video Processed Successfully"
        }
    }

    private var overallIcon: String {
        switch report.summary.overallStatus {
        case "failed":  return "exclamationmark.triangle.fill"
        case "warning": return "exclamationmark.circle.fill"
        default:        return "checkmark.circle.fill"
        }
    }

    private var overallColor: Color {
        switch report.summary.overallStatus {
        case "failed":  return .red
        case "warning": return .orange
        default:        return .green
        }
    }

    private func checkIcon(for check: QualityCheck) -> String {
        if check.isWarning { return "exclamationmark.circle.fill" }
        return check.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func checkColor(for check: QualityCheck) -> Color {
        if check.isWarning { return .orange }
        return check.passed ? .green : .red
    }

    private func checkBackground(for check: QualityCheck) -> Color {
        if check.isWarning { return Color.orange.opacity(0.05) }
        if !check.passed { return Color.red.opacity(0.05) }
        return Color.clear
    }

    private func badgePill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundColor(color)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let mins = total / 60
        let secs = total % 60
        if mins > 0 { return String(format: "%dm %ds", mins, secs) }
        return String(format: "%.1fs", s)
    }

    private func formatSize(_ mb: Double) -> String { String(format: "%.1f MB", mb) }

    private func formatBitrate(_ mbps: Double) -> String {
        mbps < 1 ? String(format: "%.0f Kbps", mbps * 1000) : String(format: "%.1f Mbps", mbps)
    }

    private func formatChange(_ delta: Double, percent: Double, unit: String) -> String {
        let sign = delta >= 0 ? "+" : ""
        return String(format: "%@%.1f%@ (%.0f%%)", sign, delta, unit, percent)
    }

    private func changeColor(_ change: String, goodWhenNegative: Bool) -> Color {
        guard change != "—", !change.contains("Changed") else { return .secondary }
        let isNegative = change.hasPrefix("-")
        let isGood = goodWhenNegative ? isNegative : !isNegative
        return isGood ? .green : .orange
    }
}

// MARK: - QA Report Window Presenter

/// Posts a notification to show the QA report modal from anywhere in the app.
public extension Notification.Name {
    static let showQAReport = Notification.Name("ScreenMuse.ShowQAReport")
}

public extension NotificationCenter {
    func postQAReport(_ report: QAReport, processedURL: URL) {
        post(name: .showQAReport, object: nil, userInfo: [
            "report": report,
            "processedURL": processedURL
        ])
    }
}

// MARK: - Preview

// FIXME: Preview macro not available in this build configuration
// #Preview("QA Passed") {
//     QAReportView(
//         report: QAReport.samplePassed,
//         processedURL: URL(fileURLWithPath: "/tmp/recording.processed.mp4"),
//         onDismiss: {}
//     )
// }
//
// #Preview("QA Failed") {
//     QAReportView(
//         report: QAReport.sampleFailed,
//         processedURL: URL(fileURLWithPath: "/tmp/recording.processed.mp4"),
//         onDismiss: {}
//     )
// }
