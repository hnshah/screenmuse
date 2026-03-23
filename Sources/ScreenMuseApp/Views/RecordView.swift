import SwiftUI
import ScreenMuseCore

struct RecordView: View {
    @StateObject private var viewModel = RecordViewModel.shared
    @State private var showEffectsSettings = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text("ScreenMuse")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            // Recording controls
            recordingControls
            
            // Phase 2 effects toggles
            if !viewModel.isRecording {
                effectsToggles
            }
            
            // Processing indicator
            if viewModel.isProcessing {
                processingView
            }
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 400, minHeight: 600)
        .sheet(isPresented: $showEffectsSettings) {
            EffectsSettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showTimeline) {
            TimelineEditorView(
                timeline: viewModel.timelineManager,
                onApply: {
                    Task {
                        await viewModel.applyTimelineEdits()
                    }
                }
            )
        }
        .task {
            await viewModel.refreshWindows()
        }
    }
    
    // MARK: - Recording Controls
    private var recordingControls: some View {
        VStack(spacing: 16) {
            // Source selection
            if !viewModel.isRecording {
                Picker("Capture Source", selection: $viewModel.selectedSourceIndex) {
                    Text("Full Screen").tag(0)
                    ForEach(Array(viewModel.availableWindows.enumerated()), id: \.offset) { index, window in
                        Text(window.title ?? "Window \(index + 1)").tag(index + 1)
                    }
                }
                .pickerStyle(.menu)
                
                // Audio options
                HStack {
                    Toggle("System Audio", isOn: $viewModel.includeSystemAudio)
                    Toggle("Microphone", isOn: $viewModel.includeMicrophone)
                }
            }
            
            // Duration display
            if viewModel.isRecording {
                Text(viewModel.formattedDuration)
                    .font(.system(.title, design: .monospaced))
                    .foregroundColor(.red)
            }
            
            // Record button
            Button(action: {
                Task {
                    if viewModel.isRecording {
                        await viewModel.stopRecording()
                    } else {
                        await viewModel.startRecording()
                    }
                }
            }) {
                HStack {
                    Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.title)
                    Text(viewModel.isRecording ? "Stop Recording" : "Start Recording")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.isRecording ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(viewModel.isProcessing)
        }
    }
    
    // MARK: - Effects Toggles
    private var effectsToggles: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Effects")
                    .font(.headline)
                
                Spacer()
                
                Button("Settings") {
                    showEffectsSettings = true
                }
                .buttonStyle(.borderless)
            }
            
            Divider()
            
            // Click ripples
            HStack {
                Toggle("Click Ripples", isOn: $viewModel.clickEffectsEnabled)
                Spacer()
                if viewModel.clickEffectsEnabled {
                    Picker("", selection: $viewModel.clickPreset) {
                        ForEach(RecordViewModel.ClickPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
            }
            
            // Auto-zoom
            HStack {
                Toggle("Auto Zoom", isOn: $viewModel.autoZoomEnabled)
                Spacer()
                if viewModel.autoZoomEnabled {
                    Picker("", selection: $viewModel.zoomPreset) {
                        ForEach(RecordViewModel.ZoomPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
            }
            
            // Cursor animations
            HStack {
                Toggle("Cursor Animations", isOn: $viewModel.cursorAnimationsEnabled)
                Spacer()
                if viewModel.cursorAnimationsEnabled {
                    Picker("", selection: $viewModel.cursorPreset) {
                        ForEach(RecordViewModel.CursorPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
            }
            
            // Keystroke overlay
            HStack {
                Toggle("Keystroke Overlay", isOn: $viewModel.keystrokeOverlayEnabled)
                Spacer()
                if viewModel.keystrokeOverlayEnabled {
                    Picker("", selection: $viewModel.keystrokePreset) {
                        ForEach(RecordViewModel.KeystrokePreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
            }
            
            // Info text
            Text("✨ Phase 2: All effects enabled! Competitive parity achieved.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
    
    // MARK: - Processing View
    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView("Applying effects...", value: viewModel.processingProgress, total: 1.0)
                .progressViewStyle(.linear)
            
            Text("\(Int(viewModel.processingProgress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("Adding click ripples, zoom, cursor animations, and keystroke overlay")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

// MARK: - Effects Settings Sheet
struct EffectsSettingsView: View {
    @ObservedObject var viewModel: RecordViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Effects Settings")
                .font(.title2)
                .fontWeight(.bold)
            
            Form {
                Section("Click Ripples") {
                    Picker("Preset", selection: $viewModel.clickPreset) {
                        ForEach(RecordViewModel.ClickPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    
                    Text("Subtle: 1.5x scale, professional")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Auto Zoom") {
                    Picker("Preset", selection: $viewModel.zoomPreset) {
                        ForEach(RecordViewModel.ZoomPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    
                    Text("Subtle: 1.5x zoom, smooth camera movement")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Cursor Animations") {
                    Picker("Preset", selection: $viewModel.cursorPreset) {
                        ForEach(RecordViewModel.CursorPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    
                    Text("Clean: smooth movement, no trail")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Keystroke Overlay") {
                    Picker("Preset", selection: $viewModel.keystrokePreset) {
                        ForEach(RecordViewModel.KeystrokePreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    
                    Text("Screencast: bottom-center, shortcuts only")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 400, height: 500)
    }
}

// MARK: - Timeline Editor Sheet
struct TimelineEditorView: View {
    @ObservedObject var timeline: TimelineManager
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Timeline Editor")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                
                Button("Apply Changes") {
                    onApply()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            
            Divider()
            
            // Timeline view (from Phase 2)
            HSplitView {
                TimelineView(timeline: timeline)
                EventInspectorView(timeline: timeline)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

#Preview {
    RecordView()
}
