import XCTest
@testable import ScreenMuseCore
import Foundation

/// Tests for Model Context Protocol (MCP) server integration
/// Priority: HIGH - Key for Claude Desktop and AI agent integration
final class MCPServerTests: XCTestCase {
    
    var mcpServer: MCPServer!
    
    override func setUp() async throws {
        try await super.setUp()
        mcpServer = try await MCPServer()
        try await mcpServer.start()
    }
    
    override func tearDown() async throws {
        try await mcpServer.stop()
        try await super.tearDown()
    }
    
    // MARK: - MCP Server Startup Tests
    
    func testMCPServerStartup() async throws {
        // When: MCP server starts
        XCTAssertTrue(mcpServer.isRunning)
        
        // Then: Should expose required MCP capabilities
        let capabilities = mcpServer.capabilities
        XCTAssertTrue(capabilities.supportsTools)
        XCTAssertTrue(capabilities.supportsResources)
        XCTAssertTrue(capabilities.supportsPrompts)
    }
    
    func testMCPServerListTools() async throws {
        // When: Listing available tools
        let tools = try await mcpServer.listTools()
        
        // Then: Should include ScreenMuse tools
        let toolNames = tools.map { $0.name }
        
        XCTAssertTrue(toolNames.contains("screenmuse_start_recording"))
        XCTAssertTrue(toolNames.contains("screenmuse_stop_recording"))
        XCTAssertTrue(toolNames.contains("screenmuse_add_chapter"))
        XCTAssertTrue(toolNames.contains("screenmuse_export_gif"))
        XCTAssertTrue(toolNames.contains("screenmuse_list_recordings"))
    }
    
    func testMCPServerStdioTransport() async throws {
        // Given: MCP uses stdio transport
        
        // When: Receiving MCP message via stdin
        let message = """
        {
            "jsonrpc": "2.0",
            "method": "tools/list",
            "id": 1
        }
        """
        
        let response = try await mcpServer.handleMessage(message)
        
        // Then: Response should follow MCP protocol
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? Int, 1)
        XCTAssertNotNil(json["result"])
    }
    
    // MARK: - Tool Invocation Tests
    
    func testInvokeStartRecordingTool() async throws {
        // Given: MCP tool invocation
        let invocation = """
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 2,
            "params": {
                "name": "screenmuse_start_recording",
                "arguments": {
                    "recording_name": "mcp-test"
                }
            }
        }
        """
        
        // When: Invoking tool
        let response = try await mcpServer.handleMessage(invocation)
        
        // Then: Recording should start
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        let result = json["result"] as! [String: Any]
        
        XCTAssertEqual(result["status"] as? String, "recording")
        XCTAssertNotNil(result["session_id"])
    }
    
    func testInvokeStopRecordingTool() async throws {
        // Given: Recording in progress
        _ = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 1,
            "params": {
                "name": "screenmuse_start_recording",
                "arguments": {"recording_name": "test"}
            }
        }
        """)
        
        // When: Stopping via MCP tool
        let stopResponse = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 2,
            "params": {
                "name": "screenmuse_stop_recording",
                "arguments": {}
            }
        }
        """)
        
        // Then: Recording should stop and return video path
        let json = try JSONSerialization.jsonObject(with: stopResponse.data(using: .utf8)!) as! [String: Any]
        let result = json["result"] as! [String: Any]
        
        XCTAssertEqual(result["status"] as? String, "stopped")
        XCTAssertNotNil(result["video_path"])
        XCTAssertTrue((result["video_path"] as! String).hasSuffix(".mp4"))
    }
    
    func testInvokeAddChapterTool() async throws {
        // Given: Recording in progress
        _ = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 1,
            "params": {
                "name": "screenmuse_start_recording",
                "arguments": {"recording_name": "test"}
            }
        }
        """)
        
        // When: Adding chapter via MCP
        let chapterResponse = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 2,
            "params": {
                "name": "screenmuse_add_chapter",
                "arguments": {
                    "chapter_name": "Step 1"
                }
            }
        }
        """)
        
        // Then: Chapter should be added
        let json = try JSONSerialization.jsonObject(with: chapterResponse.data(using: .utf8)!) as! [String: Any]
        let result = json["result"] as! [String: Any]
        
        XCTAssertTrue(result["success"] as! Bool)
        XCTAssertGreaterThan(result["timestamp"] as! Double, 0)
    }
    
    func testInvokeExportGIFTool() async throws {
        // Given: Completed recording
        let startResponse = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 1,
            "params": {
                "name": "screenmuse_start_recording",
                "arguments": {"recording_name": "test"}
            }
        }
        """)
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        let stopResponse = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 2,
            "params": {
                "name": "screenmuse_stop_recording",
                "arguments": {}
            }
        }
        """)
        
        let stopJson = try JSONSerialization.jsonObject(with: stopResponse.data(using: .utf8)!) as! [String: Any]
        let videoPath = (stopJson["result"] as! [String: Any])["video_path"] as! String
        
        // When: Exporting as GIF via MCP
        let exportResponse = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 3,
            "params": {
                "name": "screenmuse_export_gif",
                "arguments": {
                    "video_path": "\(videoPath)",
                    "fps": 10,
                    "scale": 800
                }
            }
        }
        """)
        
        // Then: GIF should be created
        let json = try JSONSerialization.jsonObject(with: exportResponse.data(using: .utf8)!) as! [String: Any]
        let result = json["result"] as! [String: Any]
        
        XCTAssertTrue((result["gif_path"] as! String).hasSuffix(".gif"))
    }
    
    // MARK: - Resource Tests
    
    func testListResourcesViaM CP() async throws {
        // When: Listing resources
        let response = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "resources/list",
            "id": 1
        }
        """)
        
        // Then: Should return available recordings
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        let result = json["result"] as! [String: Any]
        
        XCTAssertNotNil(result["resources"])
    }
    
    func testReadResourceViaMP() async throws {
        // Given: A recording exists (simulated)
        
        // When: Reading recording metadata
        let response = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "resources/read",
            "id": 1,
            "params": {
                "uri": "screenmuse://recordings/test.mp4"
            }
        }
        """)
        
        // Then: Should return recording details
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertNotNil(json["result"])
    }
    
    // MARK: - Error Handling Tests
    
    func testMCPErrorForInvalidTool() async throws {
        // When: Invoking non-existent tool
        let response = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 1,
            "params": {
                "name": "nonexistent_tool",
                "arguments": {}
            }
        }
        """)
        
        // Then: Should return MCP error
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertNotNil(json["error"])
        
        let error = json["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? Int, -32601) // Method not found
    }
    
    func testMCPErrorForInvalidArguments() async throws {
        // When: Calling tool with invalid arguments
        let response = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 1,
            "params": {
                "name": "screenmuse_start_recording",
                "arguments": {
                    "invalid_param": "value"
                }
            }
        }
        """)
        
        // Then: Should return parameter error
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        XCTAssertNotNil(json["error"])
    }
    
    // MARK: - Claude Desktop Integration Tests
    
    func testClaudeDesktopConnection() async throws {
        // Given: Claude Desktop config
        let config = """
        {
            "mcpServers": {
                "screenmuse": {
                    "command": "/path/to/screenmuse",
                    "args": ["--mcp"]
                }
            }
        }
        """
        
        // When: Claude Desktop connects
        let initMessage = """
        {
            "jsonrpc": "2.0",
            "method": "initialize",
            "id": 1,
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "roots": {
                        "listChanged": true
                    }
                },
                "clientInfo": {
                    "name": "Claude Desktop",
                    "version": "0.7.0"
                }
            }
        }
        """
        
        let response = try await mcpServer.handleMessage(initMessage)
        
        // Then: Should acknowledge connection
        let json = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!) as! [String: Any]
        let result = json["result"] as! [String: Any]
        
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        XCTAssertNotNil(result["serverInfo"])
    }
    
    func testClaudeDesktopToolUsage() async throws {
        // Given: Claude wants to record a demo
        
        // Step 1: Claude lists available tools
        let listResponse = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/list",
            "id": 1
        }
        """)
        
        let listJson = try JSONSerialization.jsonObject(with: listResponse.data(using: .utf8)!) as! [String: Any]
        let tools = (listJson["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertGreaterThan(tools.count, 0)
        
        // Step 2: Claude starts recording
        let startResponse = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 2,
            "params": {
                "name": "screenmuse_start_recording",
                "arguments": {
                    "recording_name": "claude-demo"
                }
            }
        }
        """)
        
        XCTAssertNotNil(startResponse)
        
        // Step 3: Claude adds chapter
        _ = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 3,
            "params": {
                "name": "screenmuse_add_chapter",
                "arguments": {
                    "chapter_name": "Introduction"
                }
            }
        }
        """)
        
        // Step 4: Claude stops recording
        let stopResponse = try await mcpServer.handleMessage("""
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 4,
            "params": {
                "name": "screenmuse_stop_recording",
                "arguments": {}
            }
        }
        """)
        
        // Then: Full workflow succeeds
        let stopJson = try JSONSerialization.jsonObject(with: stopResponse.data(using: .utf8)!) as! [String: Any]
        XCTAssertNotNil((stopJson["result"] as! [String: Any])["video_path"])
    }
    
    // MARK: - Performance Tests
    
    func testMCPMessageProcessingPerformance() async throws {
        measure {
            let expectation = expectation(description: "MCP message processing")
            
            Task {
                _ = try await mcpServer.handleMessage("""
                {
                    "jsonrpc": "2.0",
                    "method": "tools/list",
                    "id": 1
                }
                """)
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 0.1)
        }
    }
}

// MARK: - Supporting Types

struct MCPCapabilities {
    let supportsTools: Bool
    let supportsResources: Bool
    let supportsPrompts: Bool
}
