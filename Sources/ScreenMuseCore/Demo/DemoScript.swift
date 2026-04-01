import Foundation

/// Demo script structure for automated demo recording
public struct DemoScript: Codable, Sendable {
    public let name: String
    public let scenes: [Scene]
    public let settings: Settings?
    
    public struct Scene: Codable, Sendable {
        public let name: String
        public let duration: Double?
        public let narration: String?
        public let actions: [Action]
    }
    
    public struct Action: Codable, Sendable {
        public let type: ActionType
        public let app: String?
        public let text: String?
        public let seconds: Double?
        public let url: String?
        public let element: String?
        
        public enum ActionType: String, Codable, Sendable {
            case focusWindow = "focus_window"
            case wait
            case chapter
            case highlight
            case typeText = "type_text"
            case click
            case navigate
            case screenshot
        }
    }
    
    public struct Settings: Codable, Sendable {
        public let autoZoom: Bool?
        public let removePauses: Bool?
        public let addTransitions: Bool?
        public let voiceover: String?
        
        enum CodingKeys: String, CodingKey {
            case autoZoom = "auto_zoom"
            case removePauses = "remove_pauses"
            case addTransitions = "add_transitions"
            case voiceover
        }
    }
}

/// Result of demo recording
public struct DemoRecordingResult: Codable, Sendable {
    public let videoPath: String
    public let duration: Double
    public let scenesCompleted: Int
    public let chapters: [Chapter]
    
    public struct Chapter: Codable, Sendable {
        public let name: String
        public let time: Double
    }
    
    enum CodingKeys: String, CodingKey {
        case videoPath = "video_path"
        case duration
        case scenesCompleted = "scenes_completed"
        case chapters
    }
}
