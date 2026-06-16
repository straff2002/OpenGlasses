import XCTest
@testable import OpenGlasses

/// Verifies that tools discovered on connected MCP servers are surfaced to the model as callable
/// tool declarations (the NativeToolRouter already routes the resulting calls back to the server).
@MainActor
final class MCPDeclarationsTests: XCTestCase {

    private func clientWithTool() -> MCPClient {
        let client = MCPClient()
        client.discoveredTools = [
            MCPTool(name: "create_page",
                    description: "Create a Notion page",
                    inputSchema: ["type": "object", "properties": ["title": ["type": "string"]]],
                    serverId: "notion", serverLabel: "Notion")
        ]
        return client
    }

    func testMCPToolDeclarationsIncludeDiscoveredTools() {
        let decls = ToolDeclarations.mcpToolDeclarations(mcpClient: clientWithTool())
        // Tools are offered ONLY under their namespace-isolated qualified name (Plan R).
        XCTAssertEqual(decls.first?["name"] as? String, "notion__create_page")
        XCTAssertTrue((decls.first?["description"] as? String)?.contains("Notion") ?? false)
    }

    func testEmptySchemaGetsObjectDefault() {
        let client = MCPClient()
        client.discoveredTools = [MCPTool(name: "ping", description: "ping", inputSchema: [:], serverId: "s", serverLabel: "S")]
        let params = ToolDeclarations.mcpToolDeclarations(mcpClient: client).first?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
    }

    func testAnthropicToolsIncludeMCPTool() {
        let tools = ToolDeclarations.anthropicTools(registry: nil, includeOpenClaw: false, mcpClient: clientWithTool())
        XCTAssertTrue(tools.contains { ($0["name"] as? String) == "notion__create_page" })
        let decl = tools.first { ($0["name"] as? String) == "notion__create_page" }
        XCTAssertNotNil(decl?["input_schema"])
    }

    func testOpenAIToolsIncludeMCPTool() {
        let tools = ToolDeclarations.openAITools(registry: nil, includeOpenClaw: false, mcpClient: clientWithTool())
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("notion__create_page"))
    }

    func testNilClientAddsNothing() {
        XCTAssertTrue(ToolDeclarations.mcpToolDeclarations(mcpClient: nil).isEmpty)
    }
}
