import Foundation

// MARK: - QA Integration Helpers
//
// This file documents the integration points and provides a ready-to-use
// integration function for calling from VideoProcessor after processing completes.
//
// USAGE in VideoProcessor (or wherever video processing finishes):
//
//   // After processedURL is written to disk:
//   Task.detached(priority: .utility) {
//       QAIntegration.runAndNotify(original: originalURL, processed: processedURL)
//   }
//
// The notification `NotificationCenter.showQAReport` is then observed in ContentView
// or AppDelegate to display the modal.

public enum QAIntegration {

    /// Run QA analysis and post a notification with the report.
    ///
    /// Designed to be called from a background Task after video processing.
    /// Posts `NotificationCenter.showQAReport` on the main queue.
    ///
    /// - Parameters:
    ///   - original: URL of the original (pre-processing) video.
    ///   - processed: URL of the processed (output) video.
    public static func runAndNotify(original: URL, processed: URL) {
        let analyzer = QAAnalyzer()
        do {
            let (report, _) = try analyzer.analyzeAndSave(
                original: original,
                processed: processed
            )
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("QAReportReady"),
                    object: nil,
                    userInfo: ["report": report, "processedURL": processed]
                )
            }
        } catch {
            // QA failure should never block the user — just log and skip the modal
            print("[ScreenMuse QA] Analysis failed: \(error.localizedDescription)")
        }
    }

    /// Synchronous version — use in tests or when already on a background thread.
    public static func analyze(original: URL, processed: URL) -> QAReport? {
        try? QAAnalyzer().analyze(original: original, processed: processed)
    }
}

// MARK: - Integration Example (reference, not compiled)
//
// In VideoProcessor.swift, after processing:
//
//  func processVideo(original: URL, output: URL) {
//      // ... existing processing code ...
//
//      // NEW: Run QA in background, show report when done
//      Task.detached(priority: .utility) {
//          QAIntegration.runAndNotify(original: original, processed: output)
//      }
//  }
//
// In ContentView.swift or AppDelegate.swift, observe the notification:
//
//  .onReceive(NotificationCenter.default.publisher(for: .showQAReport)) { notification in
//      if let report = notification.userInfo?["report"] as? QAReport,
//         let url = notification.userInfo?["processedURL"] as? URL {
//          self.qaReport = report
//          self.qaProcessedURL = url
//          self.showingQAReport = true
//      }
//  }
//  .sheet(isPresented: $showingQAReport) {
//      if let report = qaReport, let url = qaProcessedURL {
//          QAReportView(report: report, processedURL: url) {
//              showingQAReport = false
//          }
//      }
//  }
