import SwiftUI
import ScreenCaptureKit
import ScreenMuseCore

@MainActor
final class RecordViewModel: ObservableObject {
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
    private let recordingManager = RecordingManager()
    private let cursorTracker = CursorTracker()
    private let keyboardMonitor = KeyboardMonitor()
    private let clickEffectsManager = ClickEffectsManager()
    private let autoZoomManager = AutoZoomManager()
    private let cursorAnimationManager = CursorAnimationManager()
    private let keystrokeOverlayManager = KeystrokeOverlayManager()
    private let timelineManager = TimelineManager()
    
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var rawVideoURL: URL?

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
            print("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        timer?.invalidate()
        timer = nil
        
        // Stop tracking
        cursorTracker.stopTracking()
        keyboardMonitor.stopMonitoring()
        
        do {
            let url = try await recordingManager.stopRecording()
            rawVideoURL = url
            isRecording = false
            
            // Check if any effects enabled
            let hasEffects = clickEffectsEnabled || autoZoomEnabled || 
                           cursorAnimationsEnabled || keystrokeOverlayEnabled
            
            if hasEffects {
                // Process with effects
                await processRecordingWithEffects(rawVideoURL: url)
            } else {
                // No effects, just save raw video
                print("Recording saved to \(url.path)")
            }
        } catch {
            print("Failed to stop recording: \(error.localizedDescription)")
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
            print("Processed video saved to \(outputURL.path)")
            
            // Optionally show timeline editor
            // showTimeline = true
            
        } catch {
            isProcessing = false
            print("Failed to process video: \(error.localizedDescription)")
        }
    }

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            availableWindows = content.windows.filter { $0.isOnScreen }
        } catch {
            print("Failed to refresh windows: \(error.localizedDescription)")
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
