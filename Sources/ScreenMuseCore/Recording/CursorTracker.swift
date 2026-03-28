import AppKit
import Combine

public enum CursorEventType: Sendable {
    case move
    case leftClick
    case rightClick
}

public struct CursorEvent: Sendable {
    public let position: CGPoint
    public let timestamp: Date
    public let type: CursorEventType

    public init(position: CGPoint, timestamp: Date, type: CursorEventType) {
        self.position = position
        self.timestamp = timestamp
        self.type = type
    }
}

@MainActor
public final class CursorTracker: ObservableObject {
    @Published public private(set) var events: [CursorEvent] = []

    private var monitors: [Any] = []
    private var isTracking = false

    public init() {}

    public func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        events.removeAll()

        let moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @Sendable [weak self] event in
            let cursorEvent = CursorEvent(
                position: NSEvent.mouseLocation,
                timestamp: Date(),
                type: .move
            )
            Task { @MainActor [weak self] in
                self?.events.append(cursorEvent)
            }
        }
        if let moveMonitor { monitors.append(moveMonitor) }

        let leftClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { @Sendable [weak self] event in
            let cursorEvent = CursorEvent(
                position: NSEvent.mouseLocation,
                timestamp: Date(),
                type: .leftClick
            )
            Task { @MainActor [weak self] in
                self?.events.append(cursorEvent)
            }
        }
        if let leftClickMonitor { monitors.append(leftClickMonitor) }

        let rightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { @Sendable [weak self] event in
            let cursorEvent = CursorEvent(
                position: NSEvent.mouseLocation,
                timestamp: Date(),
                type: .rightClick
            )
            Task { @MainActor [weak self] in
                self?.events.append(cursorEvent)
            }
        }
        if let rightClickMonitor { monitors.append(rightClickMonitor) }
    }

    public func stopTracking() {
        isTracking = false
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    deinit {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
    }
}
