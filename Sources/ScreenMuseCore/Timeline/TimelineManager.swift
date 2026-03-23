import Foundation
import Combine

/// Manages timeline of all effects
@MainActor
public final class TimelineManager: ObservableObject {
    @Published public private(set) var events: [any TimelineEvent] = []
    @Published public private(set) var selectedEventIDs: Set<UUID> = []
    @Published public var currentTime: TimeInterval = 0.0
    @Published public var videoDuration: TimeInterval = 0.0
    
    /// Zoom level (pixels per second on timeline)
    @Published public var zoomLevel: CGFloat = 50.0  // 50 pixels = 1 second
    
    /// Timeline history for undo/redo
    private var undoStack: [[any TimelineEvent]] = []
    private var redoStack: [[any TimelineEvent]] = []
    private let maxUndoLevels = 50
    
    public init() {}
    
    // MARK: - Event Management
    
    /// Add event to timeline
    public func addEvent(_ event: any TimelineEvent) {
        saveToUndoStack()
        events.append(event)
        objectWillChange.send()
    }
    
    /// Remove event from timeline
    public func removeEvent(id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }),
              events[index].isDeletable else {
            return
        }
        
        saveToUndoStack()
        events.remove(at: index)
        selectedEventIDs.remove(id)
        objectWillChange.send()
    }
    
    /// Remove multiple events
    public func removeEvents(ids: Set<UUID>) {
        let removableIDs = ids.filter { id in
            events.first(where: { $0.id == id })?.isDeletable ?? false
        }
        
        guard !removableIDs.isEmpty else { return }
        
        saveToUndoStack()
        events.removeAll { removableIDs.contains($0.id) }
        selectedEventIDs.subtract(removableIDs)
        objectWillChange.send()
    }
    
    /// Update event timing
    public func updateEventTiming(id: UUID, startTime: TimeInterval? = nil, duration: TimeInterval? = nil) {
        guard let index = events.firstIndex(where: { $0.id == id }) else {
            return
        }
        
        var event = events[index]
        
        if let newStart = startTime, event.isMovable {
            // Clamp to valid range
            let clampedStart = max(0, min(newStart, videoDuration - event.duration))
            event.startTime = clampedStart
        }
        
        if let newDuration = duration, event.isDurationAdjustable {
            // Minimum duration: 0.1s
            let clampedDuration = max(0.1, min(newDuration, videoDuration - event.startTime))
            event.duration = clampedDuration
        }
        
        saveToUndoStack()
        events[index] = event
        objectWillChange.send()
    }
    
    /// Update click ripple properties
    public func updateClickRipple(id: UUID, position: CGPoint? = nil, scale: CGFloat? = nil, color: RippleColor? = nil) {
        guard let index = events.firstIndex(where: { $0.id == id }),
              var ripple = events[index] as? ClickRippleEvent else {
            return
        }
        
        saveToUndoStack()
        
        if let newPosition = position {
            ripple.position = newPosition
        }
        if let newScale = scale {
            ripple.scale = newScale
        }
        if let newColor = color {
            ripple.color = newColor
        }
        
        events[index] = ripple
        objectWillChange.send()
    }
    
    /// Update auto-zoom properties
    public func updateAutoZoom(id: UUID, targetPosition: CGPoint? = nil, zoomScale: CGFloat? = nil, holdDuration: TimeInterval? = nil) {
        guard let index = events.firstIndex(where: { $0.id == id }),
              var zoom = events[index] as? AutoZoomEvent else {
            return
        }
        
        saveToUndoStack()
        
        if let newPosition = targetPosition {
            zoom.targetPosition = newPosition
        }
        if let newScale = zoomScale {
            zoom.zoomScale = max(1.0, min(3.0, newScale))
        }
        if let newHold = holdDuration {
            zoom.holdDuration = max(0.1, newHold)
        }
        
        events[index] = zoom
        objectWillChange.send()
    }
    
    // MARK: - Selection
    
    /// Select single event
    public func selectEvent(id: UUID) {
        selectedEventIDs = [id]
    }
    
    /// Toggle event selection
    public func toggleEventSelection(id: UUID) {
        if selectedEventIDs.contains(id) {
            selectedEventIDs.remove(id)
        } else {
            selectedEventIDs.insert(id)
        }
    }
    
    /// Select multiple events
    public func selectEvents(ids: Set<UUID>) {
        selectedEventIDs = ids
    }
    
    /// Clear selection
    public func clearSelection() {
        selectedEventIDs.removeAll()
    }
    
    /// Select all events
    public func selectAll() {
        selectedEventIDs = Set(events.map { $0.id })
    }
    
    // MARK: - Timeline Navigation
    
    /// Jump to specific time
    public func seekTo(_ time: TimeInterval) {
        currentTime = max(0, min(time, videoDuration))
    }
    
    /// Jump to next event
    public func seekToNextEvent() {
        let nextEvents = events.filter { $0.startTime > currentTime }
        if let next = nextEvents.min(by: { $0.startTime < $1.startTime }) {
            seekTo(next.startTime)
        }
    }
    
    /// Jump to previous event
    public func seekToPreviousEvent() {
        let prevEvents = events.filter { $0.startTime < currentTime }
        if let prev = prevEvents.max(by: { $0.startTime < $1.startTime }) {
            seekTo(prev.startTime)
        }
    }
    
    /// Get events at specific time
    public func eventsAt(_ time: TimeInterval) -> [any TimelineEvent] {
        events.filter { event in
            time >= event.startTime && time <= event.startTime + event.duration
        }
    }
    
    // MARK: - Filtering
    
    /// Get events by type
    public func events(ofType type: TimelineEventType) -> [any TimelineEvent] {
        events.filter { $0.eventType == type }
    }
    
    /// Get events in time range
    public func events(from start: TimeInterval, to end: TimeInterval) -> [any TimelineEvent] {
        events.filter { event in
            !(event.startTime + event.duration < start || event.startTime > end)
        }
    }
    
    // MARK: - Bulk Operations
    
    /// Delete selected events
    public func deleteSelected() {
        removeEvents(ids: selectedEventIDs)
    }
    
    /// Move selected events by delta
    public func moveSelectedEvents(by delta: TimeInterval) {
        saveToUndoStack()
        
        for id in selectedEventIDs {
            guard let index = events.firstIndex(where: { $0.id == id }),
                  events[index].isMovable else {
                continue
            }
            
            var event = events[index]
            let newStart = event.startTime + delta
            let clampedStart = max(0, min(newStart, videoDuration - event.duration))
            event.startTime = clampedStart
            events[index] = event
        }
        
        objectWillChange.send()
    }
    
    // MARK: - Undo/Redo
    
    private func saveToUndoStack() {
        // Save current state
        undoStack.append(events)
        
        // Limit stack size
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
        
        // Clear redo stack (new action invalidates redo)
        redoStack.removeAll()
    }
    
    public func undo() {
        guard let previousState = undoStack.popLast() else { return }
        
        // Save current state to redo stack
        redoStack.append(events)
        
        // Restore previous state
        events = previousState
        objectWillChange.send()
    }
    
    public func redo() {
        guard let nextState = redoStack.popLast() else { return }
        
        // Save current state to undo stack
        undoStack.append(events)
        
        // Restore next state
        events = nextState
        objectWillChange.send()
    }
    
    public var canUndo: Bool {
        !undoStack.isEmpty
    }
    
    public var canRedo: Bool {
        !redoStack.isEmpty
    }
    
    // MARK: - Import/Export
    
    /// Import events from effect managers
    public func importEvents(
        clickRipples: [ClickEvent],
        autoZooms: [ZoomEvent],
        keystrokes: [KeyEvent],
        cursorPositions: [CursorFrame]
    ) {
        events.removeAll()
        
        // Convert click events
        for click in clickRipples {
            let event = ClickRippleEvent(
                startTime: click.timestamp,
                duration: 0.8,  // Default ripple duration
                position: click.position,
                scale: 1.5,
                color: .blue
            )
            events.append(event)
        }
        
        // Convert zoom events
        for zoom in autoZooms {
            let totalDuration = zoom.config.zoomInDuration + zoom.config.holdDuration + zoom.config.zoomOutDuration
            let event = AutoZoomEvent(
                startTime: zoom.startTime,
                duration: totalDuration,
                targetPosition: zoom.clickPosition,
                zoomScale: zoom.config.zoomScale,
                holdDuration: zoom.config.holdDuration
            )
            events.append(event)
        }
        
        // Convert keystroke events
        for keystroke in keystrokes {
            let event = KeystrokeEvent(
                startTime: keystroke.timestamp,
                duration: 1.5,  // Default display duration
                key: keystroke.key,
                modifiers: keystroke.modifiers
            )
            events.append(event)
        }
        
        // Convert cursor positions (for reference)
        for (index, cursor) in cursorPositions.enumerated() where index % 10 == 0 {
            let event = CursorPositionEvent(
                startTime: cursor.timestamp,
                position: cursor.position
            )
            events.append(event)
        }
        
        objectWillChange.send()
    }
    
    /// Export events back to effect managers
    public func exportEvents() -> (
        clickRipples: [ClickEvent],
        autoZooms: [ZoomEvent],
        keystrokes: [KeyEvent]
    ) {
        var clickRipples: [ClickEvent] = []
        var autoZooms: [ZoomEvent] = []
        var keystrokes: [KeyEvent] = []
        
        for event in events {
            switch event {
            case let ripple as ClickRippleEvent:
                clickRipples.append(ClickEvent(
                    position: ripple.position,
                    timestamp: ripple.startTime,
                    intensity: Double(ripple.scale)
                ))
                
            case let zoom as AutoZoomEvent:
                autoZooms.append(ZoomEvent(
                    clickPosition: zoom.targetPosition,
                    startTime: zoom.startTime,
                    config: AutoZoomConfig(
                        zoomScale: zoom.zoomScale,
                        holdDuration: zoom.holdDuration
                    )
                ))
                
            case let key as KeystrokeEvent:
                keystrokes.append(KeyEvent(
                    key: key.key,
                    timestamp: key.startTime,
                    type: key.modifiers.isEmpty ? .keyPress : .shortcut,
                    modifiers: key.modifiers
                ))
                
            default:
                break
            }
        }
        
        return (clickRipples, autoZooms, keystrokes)
    }
    
    // MARK: - Statistics
    
    public var eventCount: Int {
        events.count
    }
    
    public var eventsByType: [TimelineEventType: Int] {
        var counts: [TimelineEventType: Int] = [:]
        for event in events {
            counts[event.eventType, default: 0] += 1
        }
        return counts
    }
    
    /// Reset timeline
    public func reset() {
        events.removeAll()
        selectedEventIDs.removeAll()
        currentTime = 0.0
        videoDuration = 0.0
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
