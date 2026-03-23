import SwiftUI
import ScreenMuseCore

/// Main timeline editor view
public struct TimelineView: View {
    @ObservedObject var timeline: TimelineManager
    @State private var draggedEventID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var hoveredEventID: UUID?
    
    private let trackHeight: CGFloat = 40
    private let headerWidth: CGFloat = 120
    
    public init(timeline: TimelineManager) {
        self.timeline = timeline
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Timeline header
            timelineHeader
            
            Divider()
            
            // Timeline tracks
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    // Click ripples track
                    timelineTrack(
                        title: "Click Ripples",
                        color: .blue,
                        events: timeline.events(ofType: .clickRipple)
                    )
                    
                    Divider()
                    
                    // Auto-zoom track
                    timelineTrack(
                        title: "Auto Zoom",
                        color: .green,
                        events: timeline.events(ofType: .autoZoom)
                    )
                    
                    Divider()
                    
                    // Keystroke track
                    timelineTrack(
                        title: "Keystrokes",
                        color: .purple,
                        events: timeline.events(ofType: .keystroke)
                    )
                    
                    Divider()
                    
                    // Cursor track (reference only)
                    timelineTrack(
                        title: "Cursor Path",
                        color: .gray,
                        events: timeline.events(ofType: .cursorPosition)
                    )
                }
                .frame(minWidth: timelineWidth)
            }
            .frame(height: 300)
            
            Divider()
            
            // Timeline controls
            timelineControls
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Components
    
    private var timelineHeader: some View {
        HStack(spacing: 0) {
            // Track labels column
            Text("Tracks")
                .frame(width: headerWidth, alignment: .leading)
                .padding(.leading, 8)
                .font(.headline)
            
            // Time ruler
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(0..<Int(timeline.videoDuration) + 1, id: \.self) { second in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(second)s")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: 1, height: 8)
                        }
                        .frame(width: timeline.zoomLevel, alignment: .leading)
                    }
                }
                .padding(.leading, 8)
            }
        }
        .frame(height: 30)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func timelineTrack(title: String, color: Color, events: [any TimelineEvent]) -> some View {
        HStack(spacing: 0) {
            // Track label
            Text(title)
                .frame(width: headerWidth, alignment: .leading)
                .padding(.leading, 8)
                .font(.subheadline)
            
            // Track content
            ZStack(alignment: .leading) {
                // Background grid
                ForEach(0..<Int(timeline.videoDuration) + 1, id: \.self) { second in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 1)
                        .offset(x: CGFloat(second) * timeline.zoomLevel)
                }
                
                // Events on this track
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    eventBlock(event: event, color: color)
                }
                
                // Current time indicator
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2)
                    .offset(x: timeline.currentTime * timeline.zoomLevel)
            }
            .frame(height: trackHeight)
            .frame(minWidth: timelineWidth)
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTrackTap(at: location)
            }
        }
    }
    
    private func eventBlock(event: any TimelineEvent, color: Color) -> some View {
        let xPosition = event.startTime * timeline.zoomLevel
        let width = max(event.duration * timeline.zoomLevel, 20) // Minimum 20pt width
        let isSelected = timeline.selectedEventIDs.contains(event.id)
        let isHovered = hoveredEventID == event.id
        
        return RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(isSelected ? 0.8 : 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
            )
            .overlay(
                Text(eventLabel(event))
                    .font(.caption2)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            )
            .frame(width: width, height: trackHeight - 8)
            .offset(x: xPosition, y: 4)
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isHovered)
            .onHover { hovering in
                hoveredEventID = hovering ? event.id : nil
            }
            .onTapGesture {
                handleEventTap(event: event)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        handleEventDrag(event: event, translation: value.translation)
                    }
                    .onEnded { _ in
                        draggedEventID = nil
                    }
            )
    }
    
    private var timelineControls: some View {
        HStack(spacing: 16) {
            // Playback controls
            Button(action: { timeline.seekTo(0) }) {
                Image(systemName: "backward.end.fill")
            }
            
            Button(action: timeline.seekToPreviousEvent) {
                Image(systemName: "backward.frame.fill")
            }
            
            Button(action: timeline.seekToNextEvent) {
                Image(systemName: "forward.frame.fill")
            }
            
            Button(action: { timeline.seekTo(timeline.videoDuration) }) {
                Image(systemName: "forward.end.fill")
            }
            
            Divider()
                .frame(height: 20)
            
            // Edit controls
            Button(action: timeline.deleteSelected) {
                Image(systemName: "trash")
            }
            .disabled(timeline.selectedEventIDs.isEmpty)
            
            Button(action: timeline.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!timeline.canUndo)
            
            Button(action: timeline.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!timeline.canRedo)
            
            Divider()
                .frame(height: 20)
            
            // Zoom controls
            Button(action: { timeline.zoomLevel = max(20, timeline.zoomLevel - 10) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            
            Text("Zoom: \(Int(timeline.zoomLevel))px/s")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button(action: { timeline.zoomLevel = min(200, timeline.zoomLevel + 10) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            
            Spacer()
            
            // Time display
            Text(formatTime(timeline.currentTime))
                .font(.system(.body, design: .monospaced))
            
            Text("/")
                .foregroundColor(.secondary)
            
            Text(formatTime(timeline.videoDuration))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - Helpers
    
    private var timelineWidth: CGFloat {
        max(800, timeline.videoDuration * timeline.zoomLevel + 100)
    }
    
    private func eventLabel(_ event: any TimelineEvent) -> String {
        switch event {
        case let ripple as ClickRippleEvent:
            return "Click"
        case let zoom as AutoZoomEvent:
            return "Zoom \(String(format: "%.1fx", zoom.zoomScale))"
        case let key as KeystrokeEvent:
            return key.modifiers.isEmpty ? key.key : key.modifiers.joined() + key.key
        case is CursorPositionEvent:
            return "•"
        default:
            return "Event"
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", minutes, secs, millis)
    }
    
    private func handleTrackTap(at location: CGPoint) {
        let time = (location.x - headerWidth) / timeline.zoomLevel
        timeline.seekTo(time)
    }
    
    private func handleEventTap(event: any TimelineEvent) {
        if NSEvent.modifierFlags.contains(.command) {
            timeline.toggleEventSelection(id: event.id)
        } else {
            timeline.selectEvent(id: event.id)
        }
    }
    
    private func handleEventDrag(event: any TimelineEvent, translation: CGSize) {
        guard event.isMovable else { return }
        
        let timeDelta = translation.width / timeline.zoomLevel
        let newStart = event.startTime + timeDelta
        
        timeline.updateEventTiming(id: event.id, startTime: newStart)
    }
}

/// Event inspector panel
public struct EventInspectorView: View {
    @ObservedObject var timeline: TimelineManager
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if timeline.selectedEventIDs.count == 1,
               let selectedID = timeline.selectedEventIDs.first,
               let event = timeline.events.first(where: { $0.id == selectedID }) {
                
                Text("Event Properties")
                    .font(.headline)
                
                Divider()
                
                // Common properties
                HStack {
                    Text("Type:")
                    Spacer()
                    Text(event.eventType.rawValue)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Start Time:")
                    Spacer()
                    Text(String(format: "%.2fs", event.startTime))
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Duration:")
                    Spacer()
                    Text(String(format: "%.2fs", event.duration))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Type-specific properties
                if let ripple = event as? ClickRippleEvent {
                    clickRippleInspector(ripple)
                } else if let zoom = event as? AutoZoomEvent {
                    autoZoomInspector(zoom)
                } else if let key = event as? KeystrokeEvent {
                    keystrokeInspector(key)
                }
                
            } else if timeline.selectedEventIDs.count > 1 {
                Text("\(timeline.selectedEventIDs.count) events selected")
                    .foregroundColor(.secondary)
            } else {
                Text("No selection")
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 250)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func clickRippleInspector(_ ripple: ClickRippleEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Click Ripple")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack {
                Text("Position:")
                Spacer()
                Text("(\(Int(ripple.position.x)), \(Int(ripple.position.y)))")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("Scale:")
                Spacer()
                Text(String(format: "%.1fx", ripple.scale))
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("Color:")
                Spacer()
                Text(ripple.color.rawValue)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func autoZoomInspector(_ zoom: AutoZoomEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto Zoom")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack {
                Text("Target:")
                Spacer()
                Text("(\(Int(zoom.targetPosition.x)), \(Int(zoom.targetPosition.y)))")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("Zoom:")
                Spacer()
                Text(String(format: "%.1fx", zoom.zoomScale))
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("Hold:")
                Spacer()
                Text(String(format: "%.1fs", zoom.holdDuration))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func keystrokeInspector(_ key: KeystrokeEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keystroke")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack {
                Text("Key:")
                Spacer()
                Text(key.modifiers.isEmpty ? key.key : key.modifiers.joined() + key.key)
                    .foregroundColor(.secondary)
            }
        }
    }
}
