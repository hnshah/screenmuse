import Foundation
import AppKit

/// Executes demo scripts by coordinating window management and recording
@MainActor
public final class DemoExecutor {
    
    private weak var server: ScreenMuseServer?
    
    public init(server: ScreenMuseServer) {
        self.server = server
    }
    
    /// Execute a demo script
    public func execute(script: DemoScript, outputName: String?) async throws -> DemoRecordingResult {
        smLog.info("Starting demo execution: \(script.name)", category: .server)
        smLog.usage("DEMO START", details: ["name": script.name, "scenes": "\(script.scenes.count)"])
        
        let startTime = Date()
        var completedScenes = 0
        var chapters: [(name: String, time: TimeInterval)] = []
        
        // Start recording
        let recordingName = outputName ?? script.name.replacingOccurrences(of: " ", with: "-").lowercased()
        try await startRecording(name: recordingName)
        
        // Execute each scene
        for (index, scene) in script.scenes.enumerated() {
            smLog.info("Executing scene \(index + 1)/\(script.scenes.count): \(scene.name)", category: .server)
            
            // Mark chapter
            await createChapter(name: scene.name)
            chapters.append((name: scene.name, time: Date().timeIntervalSince(startTime)))
            
            // Execute actions
            for action in scene.actions {
                try await executeAction(action)
            }
            
            completedScenes += 1
            
            // Wait for scene duration if specified
            if let duration = scene.duration {
                let elapsed = Date().timeIntervalSince(startTime) - chapters.last!.time
                let remaining = duration - elapsed
                if remaining > 0 {
                    smLog.debug("Waiting \(remaining)s for scene duration", category: .server)
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
        }
        
        // Stop recording
        let videoPath = try await stopRecording()
        let totalDuration = Date().timeIntervalSince(startTime)
        
        smLog.info("Demo completed: \(videoPath)", category: .server)
        smLog.usage("DEMO COMPLETE", details: [
            "scenes": "\(completedScenes)",
            "duration": String(format: "%.1fs", totalDuration),
            "path": videoPath
        ])
        
        return DemoRecordingResult(
            videoPath: videoPath,
            duration: totalDuration,
            scenesCompleted: completedScenes,
            chapters: chapters.map { DemoRecordingResult.Chapter(name: $0.name, time: $0.time) }
        )
    }
    
    // MARK: - Action Execution
    
    private func executeAction(_ action: DemoScript.Action) async throws {
        smLog.debug("Action: \(action.type.rawValue)", category: .server)
        
        switch action.type {
        case .focusWindow:
            guard let app = action.app else {
                throw DemoError.missingParameter("app", for: "focus_window")
            }
            try await focusWindow(app: app)
            
        case .wait:
            guard let seconds = action.seconds else {
                throw DemoError.missingParameter("seconds", for: "wait")
            }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            
        case .chapter:
            // Already handled at scene level
            break
            
        case .highlight:
            await triggerHighlight()
            
        case .typeText:
            guard let text = action.text else {
                throw DemoError.missingParameter("text", for: "type_text")
            }
            try await typeText(text)
            
        case .click:
            await triggerHighlight() // Highlight before click
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
            
        case .navigate:
            guard let url = action.url else {
                throw DemoError.missingParameter("url", for: "navigate")
            }
            try await navigate(url: url)
            
        case .screenshot:
            // TODO: Implement screenshot action
            break
        }
    }
    
    // MARK: - Recording Control
    
    private func startRecording(name: String) async throws {
        guard let server = server else {
            throw DemoError.serverUnavailable
        }
        
        // Use server's coordinator to start recording
        if let coordinator = server.coordinator {
            try await coordinator.startRecording(name: name, windowTitle: nil, windowPid: nil, quality: "high")
        } else {
            throw DemoError.coordinatorUnavailable
        }
    }
    
    private func stopRecording() async throws -> String {
        guard let server = server else {
            throw DemoError.serverUnavailable
        }
        
        if let coordinator = server.coordinator {
            guard let url = await coordinator.stopAndGetVideo() else {
                throw DemoError.recordingFailed
            }
            return url.path
        } else {
            throw DemoError.coordinatorUnavailable
        }
    }
    
    private func createChapter(name: String) async {
        // Chapters are handled via server helper
        guard let server = server else { return }
        server.addChapterInternal(name: name)
    }
    
    private func triggerHighlight() async {
        guard let server = server else { return }
        server.setHighlightFlagInternal()
    }
    
    // MARK: - Window Actions
    
    private func focusWindow(app: String) async throws {
        let workspace = NSWorkspace.shared
        
        // Try to find running app
        if let runningApp = workspace.runningApplications.first(where: {
            $0.localizedName?.lowercased().contains(app.lowercased()) ?? false ||
            $0.bundleIdentifier?.lowercased().contains(app.lowercased()) ?? false
        }) {
            runningApp.activate()
            try await Task.sleep(nanoseconds: 500_000_000) // Wait for activation
        } else {
            // Try to launch app
            if workspace.launchApplication(app) {
                try await Task.sleep(nanoseconds: 1_000_000_000) // Wait for launch
            } else {
                throw DemoError.appNotFound(app)
            }
        }
    }
    
    private func typeText(_ text: String) async throws {
        // TODO: Implement keyboard simulation
        // For now, just paste via clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Simulate Cmd+V
        // This is a simplified version - real implementation would use CGEvent
        smLog.warning("typeText not fully implemented - text copied to clipboard", category: .server)
    }
    
    private func navigate(url: String) async throws {
        // Open URL in default browser
        if let urlObj = URL(string: url) {
            NSWorkspace.shared.open(urlObj)
            try await Task.sleep(nanoseconds: 1_000_000_000) // Wait for browser
        } else {
            throw DemoError.invalidURL(url)
        }
    }
}

// MARK: - Errors

public enum DemoError: Error, LocalizedError {
    case missingParameter(String, for: String)
    case serverUnavailable
    case coordinatorUnavailable
    case recordingFailed
    case appNotFound(String)
    case invalidURL(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingParameter(let param, let action):
            return "Missing '\(param)' parameter for action '\(action)'"
        case .serverUnavailable:
            return "ScreenMuse server unavailable"
        case .coordinatorUnavailable:
            return "Recording coordinator unavailable"
        case .recordingFailed:
            return "Recording failed to produce video"
        case .appNotFound(let app):
            return "Application not found: \(app)"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        }
    }
}
