import SwiftUI
import ScreenCaptureKit
import ScreenMuseCore
import UserNotifications
import AppKit

@MainActor
final class RecordViewModel: ObservableObject {
    // Shared instance used by both the UI and the agent API server
    static let shared = RecordViewModel()

    // MARK: - Recording State
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedSourceIndex = 0
    @Published var includeSystemAudio = true
    @Published var includeMicrophone = false
    
    // MARK: - Phase 2 Feature Toggles
    @Published var clickEffectsEnabled = true
    @Published var autoZoomEnabled = true
    @Published var cursorAnimationsEnabled = true
    @Published var keystrokeOverlayEnabled = true
    
    // MARK: - Phase 2 Presets
    @Published var clickPreset: ClickPreset = .subtle
    @Published var zoomPreset: ZoomPreset = .subtle
    @Published var cursorPreset: CursorPreset = .clean
    @Published var keystrokePreset: KeystrokePreset = .screencast
    
    // MARK: - Processing State
    @Published var isProcessing = false
    @Published var processingProgress: Double = 0
    @Published var showTimeline = false
    
    // MARK: - Managers
    internal let recordingManager = RecordingManager()
    let cursorTracker = CursorTracker()
    let keyboardMonitor = KeyboardMonitor()
    private let clickEffectsManager = ClickEffectsManager()
    private let autoZoomManager = AutoZoomManager()
    private let cursorAnimationManager = CursorAnimationManager()
    private let keystrokeOverlayManager = KeystrokeOverlayManager()
    let timelineManager = TimelineManager()
    
    internal var timer: Timer?
    var recordingStartTime: Date?
    private var rawVideoURL: URL?
    /// The final video URL after effects are applied — set by stopRecording() / processRecordingWithEffects()
    @Published public private(set) var lastVideoURL: URL?

    /// Set lastVideoURL from external sources (e.g. PiP recording manager)
    public func setLastVideoURL(_ url: URL) {
        lastVideoURL = url
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    // MARK: - Presets
    enum ClickPreset: String, CaseIterable {
        case subtle = "Subtle"
        case medium = "Medium"
        case bold = "Bold"
        
        var config: ClickEffectConfig {
            switch self {
            case .subtle: return .subtle
            case .medium: return .medium
            case .bold: return .bold
            }
        }
    }
    
    enum ZoomPreset: String, CaseIterable {
        case subtle = "Subtle (1.5x)"
        case strong = "Strong (2.0x)"
        case quick = "Quick (1.3x)"
        
        var config: AutoZoomConfig {
            switch self {
            case .subtle: return .subtle
            case .strong: return .strong
            case .quick: return .quick
            }
        }
    }
    
    enum CursorPreset: String, CaseIterable {
        case clean = "Clean"
        case dramatic = "Dramatic"
        case minimal = "Minimal"
        
        var config: CursorAnimationConfig {
            switch self {
            case .clean: return .clean
            case .dramatic: return .dramatic
            case .minimal: return .minimal
            }
        }
    }
    
    enum KeystrokePreset: String, CaseIterable {
        case tutorial = "Tutorial (Large)"
        case screencast = "Screencast (Medium)"
        case demo = "Demo (All Keys)"
        
        var config: KeystrokeOverlayConfig {
            switch self {
            case .tutorial: return .tutorial
            case .screencast: return .screencast
            case .demo: return .demo
            }
        }
    }

    // MARK: - Recording
    /// API-facing start — used by RecordingCoordinating conformance.
    /// Supports window targeting and quality selection from the agent API.
    func startRecording(name: String, windowTitle: String?, windowPid: Int?, quality: String?) async throws {
        let resolvedQuality = RecordingConfig.Quality(rawValue: quality ?? "medium") ?? .medium

        // Resolve capture source
        let source: CaptureSource
        if windowTitle != nil || windowPid != nil {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let title = windowTitle,
               let window = content.windows.first(where: { $0.title?.localizedCaseInsensitiveContains(title) ?? false }) {
                source = .window(window)
            } else if let pid = windowPid,
                      let window = content.windows.first(where: { $0.owningApplication?.processID == Int32(pid) }) {
                source = .window(window)
            } else {
                let query = windowTitle ?? "PID \(windowPid ?? 0)"
                throw RecordingError.windowNotFound(query)
            }
        } else {
            source = .fullScreen
        }

        let config = RecordingConfig(
            captureSource: source,
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: includeMicrophone,
            fps: 30,
            quality: resolvedQuality
        )
        try await recordingManager.startRecording(config: config)
        isRecording = true
        duration = 0
        lastVideoURL = nil

        // Start effects tracking
        let recordingStartTime = Date()
        if clickEffectsEnabled {
            clickEffectsManager.startRecording(at: recordingStartTime)
        }
        if autoZoomEnabled {
            autoZoomManager.startRecording(at: recordingStartTime)
        }
        if cursorAnimationsEnabled {
            cursorTracker.startTracking()
            cursorAnimationManager.startRecording(at: recordingStartTime)
        }
        if keystrokeOverlayEnabled {
            keyboardMonitor.startMonitoring()
            keystrokeOverlayManager.startRecording(at: recordingStartTime)
            keystrokeOverlayManager.updateConfig(keystrokePreset.config)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.duration += 1
            }
        }
    }

    func startRecording() async {
        let source: CaptureSource
        if selectedSourceIndex == 0 {
            source = .fullScreen
        } else {
            let windowIndex = selectedSourceIndex - 1
            guard windowIndex < availableWindows.count else { return }
            source = .window(availableWindows[windowIndex])
        }

        let config = RecordingConfig(
            captureSource: source,
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: includeMicrophone
        )

        do {
            // Start recording
            try await recordingManager.startRecording(config: config)
            isRecording = true
            duration = 0
            recordingStartTime = Date()
            
            // Start tracking (Phase 2)
            if clickEffectsEnabled || autoZoomEnabled || cursorAnimationsEnabled {
                cursorTracker.startTracking()
            }
            
            if clickEffectsEnabled {
                clickEffectsManager.startRecording(at: recordingStartTime!)
                clickEffectsManager.updateConfig(clickPreset.config)
            }
            
            if autoZoomEnabled {
                autoZoomManager.startRecording(at: recordingStartTime!)
                autoZoomManager.updateConfig(zoomPreset.config)
            }
            
            if cursorAnimationsEnabled {
                cursorAnimationManager.startRecording(at: recordingStartTime!)
                cursorAnimationManager.updateConfig(cursorPreset.config)
            }
            
            if keystrokeOverlayEnabled {
                keystrokeOverlayManager.startRecording(at: recordingStartTime!)
                keystrokeOverlayManager.updateConfig(keystrokePreset.config)
                keyboardMonitor.startMonitoring()
            }
            
            // Start timer
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.duration += 1
                }
            }
        } catch {
            smLog.error("RecordViewModel: Failed to start recording: \(error.localizedDescription)", category: .recording)
        }
    }

    func stopRecording() async {
        await stopAndGetVideo()
    }

    /// Stop recording and return final video URL (with effects applied).
    /// Used by both the UI and the agent API server.
    @discardableResult
    func stopAndGetVideo() async -> URL? {
        timer?.invalidate()
        timer = nil

        // Stop tracking
        cursorTracker.stopTracking()
        keyboardMonitor.stopMonitoring()

        do {
            let url = try await recordingManager.stopRecording()
            rawVideoURL = url
            isRecording = false

            let hasEffects = clickEffectsEnabled || autoZoomEnabled ||
                             cursorAnimationsEnabled || keystrokeOverlayEnabled

            if hasEffects {
                await processRecordingWithEffects(rawVideoURL: url)
                // lastVideoURL is set inside processRecordingWithEffects
                if let finalURL = lastVideoURL ?? (url as URL?) {
                    notifyVideoReady(url: finalURL)
                    revealInFinder(url: finalURL)
                }
                return lastVideoURL ?? url
            } else {
                lastVideoURL = url
                smLog.info("RecordViewModel: Recording saved (no effects) to \(url.path)", category: .recording)
                notifyVideoReady(url: url)
                revealInFinder(url: url)
                return url
            }
        } catch {
            smLog.error("RecordViewModel: Failed to stop recording: \(error.localizedDescription)", category: .recording)
            return nil
        }
    }
    
    // MARK: - Effects Processing
    private func processRecordingWithEffects(rawVideoURL: URL) async {
        isProcessing = true
        processingProgress = 0
        
        // Populate managers from captured events
        for event in cursorTracker.events {
            // Add cursor position
            if cursorAnimationsEnabled {
                cursorAnimationManager.addCursorPosition(
                    at: event.position,
                    timestamp: event.timestamp
                )
            }
            
            // Add click events
            if event.type == .leftClick {
                if clickEffectsEnabled {
                    clickEffectsManager.addClick(
                        at: event.position,
                        timestamp: event.timestamp
                    )
                }
                
                if autoZoomEnabled {
                    autoZoomManager.addClick(
                        at: event.position,
                        timestamp: event.timestamp
                    )
                }
            }
        }
        
        // Add keystroke events
        if keystrokeOverlayEnabled {
            for event in keyboardMonitor.events {
                keystrokeOverlayManager.addKeystroke(
                    key: event.key,
                    timestamp: event.timestamp,
                    modifiers: event.modifiers
                )
            }
        }
        
        // Import into timeline for editing (optional)
        timelineManager.videoDuration = duration
        timelineManager.importEvents(
            clickRipples: clickEffectsManager.clickEvents,
            autoZooms: autoZoomManager.zoomEvents,
            keystrokes: keystrokeOverlayManager.keyEvents,
            cursorPositions: cursorAnimationManager.cursorFrames
        )
        
        // Apply effects
        let outputURL = rawVideoURL.deletingPathExtension()
            .appendingPathExtension("processed.mp4")
        
        do {
            let compositor = FullEffectsCompositor(
                clickEffects: clickEffectsEnabled ? clickEffectsManager : nil,
                autoZoom: autoZoomEnabled ? autoZoomManager : nil,
                cursorAnimation: cursorAnimationsEnabled ? cursorAnimationManager : nil,
                keystrokeOverlay: keystrokeOverlayEnabled ? keystrokeOverlayManager : nil
            )
            
            try await compositor.applyEffects(
                sourceURL: rawVideoURL,
                outputURL: outputURL,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.processingProgress = progress
                    }
                }
            )
            
            isProcessing = false
            lastVideoURL = outputURL
            smLog.info("RecordViewModel: Processed video (with effects) saved to \(outputURL.path)", category: .effects)
            // Notification + Finder reveal are called from stopAndGetVideo() after this returns
            
        } catch {
            isProcessing = false
            smLog.error("RecordViewModel: Failed to process video with effects: \(error.localizedDescription)", category: .effects)
            notifyError("Effects compositing failed", detail: error.localizedDescription)
        }
    }

    // MARK: - Notifications & Finder

    /// Send a native macOS notification when the video file is ready.
    /// No-ops gracefully when running as a bare executable (swift build) — no bundle = no UNUserNotificationCenter.
    private func notifyVideoReady(url: URL) {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let sizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576)
        smLog.info("Video ready — \(url.lastPathComponent) (\(sizeMB)MB)", category: .lifecycle)

        guard Bundle.main.bundleIdentifier != nil else {
            smLog.debug("Skipping notification (no bundle — swift build mode)", category: .permissions)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                smLog.warning("Notification permission not granted — skipping video-ready notification", category: .permissions)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Recording ready ✓"
            content.body = "\(url.lastPathComponent) · \(sizeMB) MB"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "screenmuse.video-ready.\(url.lastPathComponent)",
                content: content,
                trigger: nil  // deliver immediately
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    smLog.warning("Failed to deliver notification: \(error.localizedDescription)", category: .lifecycle)
                }
            }
        }
    }

    /// Reveal the finished video in Finder, selected.
    private func revealInFinder(url: URL) {
        smLog.info("Revealing in Finder: \(url.lastPathComponent)", category: .lifecycle)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Send an error notification (e.g. when compositing fails).
    /// No-ops gracefully without a proper app bundle.
    private func notifyError(_ title: String, detail: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "ScreenMuse — \(title)"
            content.body = detail
            content.sound = .defaultCritical
            let request = UNNotificationRequest(
                identifier: "screenmuse.error.\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            availableWindows = content.windows.filter { $0.isOnScreen }
        } catch {
            smLog.warning("RecordViewModel: Failed to refresh windows: \(error.localizedDescription)", category: .capture)
        }
    }
    
    // MARK: - Timeline Editing
    func openTimelineEditor() {
        showTimeline = true
    }
    
    func applyTimelineEdits() async {
        guard let rawURL = rawVideoURL else { return }
        
        // Export edited events from timeline
        let (clicks, zooms, keystrokes) = timelineManager.exportEvents()
        
        // Update managers with edited events
        clickEffectsManager.setClickEvents(clicks)
        autoZoomManager.setZoomEvents(zooms)
        keystrokeOverlayManager.setKeyEvents(keystrokes)
        
        // Re-process with edited timeline
        await processRecordingWithEffects(rawVideoURL: rawURL)
        
        showTimeline = false
    }
}
