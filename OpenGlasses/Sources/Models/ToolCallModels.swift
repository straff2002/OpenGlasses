import Foundation

// MARK: - Gemini Tool Call (parsed from WebSocket JSON)

struct GeminiFunctionCall {
    let id: String
    let name: String
    let args: [String: Any]
}

struct GeminiToolCall {
    let functionCalls: [GeminiFunctionCall]

    init?(json: [String: Any]) {
        guard let toolCall = json["toolCall"] as? [String: Any],
              let calls = toolCall["functionCalls"] as? [[String: Any]] else {
            return nil
        }
        self.functionCalls = calls.compactMap { call in
            guard let id = call["id"] as? String,
                  let name = call["name"] as? String else { return nil }
            let args = call["args"] as? [String: Any] ?? [:]
            return GeminiFunctionCall(id: id, name: name, args: args)
        }
    }
}

// MARK: - Gemini Tool Call Cancellation

struct GeminiToolCallCancellation {
    let ids: [String]

    init?(json: [String: Any]) {
        guard let cancellation = json["toolCallCancellation"] as? [String: Any],
              let ids = cancellation["ids"] as? [String] else {
            return nil
        }
        self.ids = ids
    }
}

// MARK: - Tool Result

enum ToolResult {
    case success(String)
    case failure(String)

    var responseValue: [String: Any] {
        switch self {
        case .success(let result):
            return ["result": result]
        case .failure(let error):
            return ["error": error]
        }
    }
}

// MARK: - Tool Call Status (for UI)

enum ToolCallStatus: Equatable {
    case idle
    case executing(String)
    case completed(String)
    case failed(String, String)
    /// The wait ran out on work that may still land. Deliberately not `.failed`: telling the user
    /// something didn't happen when it may have is what makes them do it twice.
    case outcomeUnknown(String)
    case cancelled(String)
    case yielded(String)

    var displayText: String {
        switch self {
        case .idle: return ""
        case .executing(let name): return "Running: \(name)..."
        case .completed(let name): return "Done: \(name)"
        case .failed(let name, let err): return "Failed: \(name) — \(err)"
        case .outcomeUnknown(let name): return "\(name): status unknown — checking"
        case .cancelled(let name): return "Cancelled: \(name)"
        case .yielded: return "Waiting for you..."
        }
    }

    /// Whether the status pill is worth showing. An unresolved outcome counts: the turn has moved
    /// on, but the user is owed the fact that we don't yet know how it ended. It clears with the
    /// rest of the turn when the loop goes idle.
    var isActive: Bool {
        switch self {
        case .executing, .outcomeUnknown: return true
        default: return false
        }
    }
}

// MARK: - Tool Declarations

/// Shared tool definitions used by both Gemini Live (WebSocket) and Direct Mode (REST API tool calling).
/// The `execute` tool delegates tasks to the OpenClaw gateway.
enum ToolDeclarations {

    static func allDeclarations() -> [[String: Any]] {
        return [execute]
    }

    /// Build declarations from native tool registry + optional OpenClaw execute tool.
    @MainActor
    static func allDeclarations(registry: NativeToolRegistry?, includeOpenClaw: Bool) -> [[String: Any]] {
        var declarations = nativeToolDeclarations(registry: registry)
        if includeOpenClaw {
            declarations.append(execute)
        }
        return declarations
    }

    /// The single "execute" tool that routes all actions through OpenClaw.
    static let execute: [String: Any] = [
        "name": "execute",
        "description": """
            Your only way to take action. You have no memory, storage, or ability to do anything on your own — \
            use this tool for everything: sending messages, searching the web, adding to lists, setting reminders, \
            creating notes, research, drafts, scheduling, smart home control, app interactions, or any request \
            that goes beyond answering a question. When in doubt, use this tool.
            """,
        "parameters": [
            "type": "object",
            "properties": [
                "task": [
                    "type": "string",
                    "description": "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc."
                ]
            ],
            "required": ["task"]
        ] as [String: Any],
        "behavior": "BLOCKING"
    ]

    // MARK: - Provider-Specific Formats

    /// Build native tool declarations from the registry.
    @MainActor
    private static func nativeToolDeclarations(registry: NativeToolRegistry?) -> [[String: Any]] {
        guard let registry else { return [] }
        return registry.allTools.filter { Config.isToolEnabled($0.name) }.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parametersSchema,
            ] as [String: Any]
        }
    }

    /// Declarations for tools discovered on connected MCP servers, so the model can call them
    /// directly (the NativeToolRouter routes the call to the owning server). Returns the generic
    /// {name, description, parameters} shape used by the per-provider mappers.
    @MainActor
    static func mcpToolDeclarations(mcpClient: MCPClient?) -> [[String: Any]] {
        guard let mcpClient else { return [] }
        // Blocked (tool-poisoned) definitions are never offered to the model. Offered tools are
        // exposed ONLY under their fully-qualified name, so a server can't shadow a native tool
        // and the router routes the call back unambiguously (Plan R).
        return mcpClient.discoveredTools.filter { $0.trust.isOffered }.map { tool in
            let schema = tool.inputSchema.isEmpty
                ? ["type": "object", "properties": [:] as [String: Any]] as [String: Any]
                : tool.inputSchema
            return [
                "name": tool.qualifiedName,
                "description": MCPToolDeclarationPolicy.description(for: tool),
                "parameters": schema,
            ] as [String: Any]
        }
    }

    /// Anthropic tool format for the Messages API
    @MainActor
    static func anthropicTools(registry: NativeToolRegistry?, includeOpenClaw: Bool, mcpClient: MCPClient? = nil) -> [[String: Any]] {
        var tools: [[String: Any]] = (nativeToolDeclarations(registry: registry) + mcpToolDeclarations(mcpClient: mcpClient)).map { decl in
            [
                "name": decl["name"] as! String,
                "description": decl["description"] as! String,
                "input_schema": decl["parameters"] as Any,
            ]
        }
        if includeOpenClaw {
            tools.append([
                "name": "execute",
                "description": execute["description"] as! String,
                "input_schema": [
                    "type": "object",
                    "properties": ["task": ["type": "string", "description": "Clear, detailed description of what to do."]],
                    "required": ["task"],
                ] as [String: Any],
            ])
        }
        return tools
    }

    /// OpenAI / Groq / Custom tool format
    @MainActor
    static func openAITools(registry: NativeToolRegistry?, includeOpenClaw: Bool, mcpClient: MCPClient? = nil) -> [[String: Any]] {
        var tools: [[String: Any]] = (nativeToolDeclarations(registry: registry) + mcpToolDeclarations(mcpClient: mcpClient)).map { decl in
            [
                "type": "function",
                "function": [
                    "name": decl["name"] as! String,
                    "description": decl["description"] as! String,
                    "parameters": decl["parameters"] as Any,
                ] as [String: Any],
            ]
        }
        if includeOpenClaw {
            tools.append([
                "type": "function",
                "function": [
                    "name": "execute",
                    "description": execute["description"] as! String,
                    "parameters": [
                        "type": "object",
                        "properties": ["task": ["type": "string", "description": "Clear, detailed description of what to do."]],
                        "required": ["task"],
                    ] as [String: Any],
                ] as [String: Any],
            ])
        }
        return tools
    }

    /// OpenAI **Realtime** session tool format.
    ///
    /// Flat — `{type, name, description, parameters}` — where the Chat Completions format nests
    /// the same fields under `function`. Written as its own mapper rather than reusing
    /// `openAITools` because passing the nested shape to `session.update` is accepted and then
    /// silently ignored, which is the worst of the three outcomes: no error, no tools.
    ///
    /// `names`, when given, restricts the surface. Plan FO P3a declares only the Field Assist job
    /// tools to this backend: it has never executed a tool of any kind, so handing it the whole
    /// registry would be a far larger change than the guided flow needs and one no test here could
    /// stand behind. With Field Assist off the list is empty and `session.update` carries no
    /// `tools` key at all, so the wearer's existing session is byte-for-byte what it was.
    @MainActor
    static func openAIRealtimeTools(registry: NativeToolRegistry?,
                                    names: Set<String>? = nil) -> [[String: Any]] {
        openAIRealtimeTools(declarations: nativeToolDeclarations(registry: registry), names: names)
    }

    /// The same mapping over declarations that are already in hand — what a cross-provider diff
    /// test drives, since a `NativeToolRegistry` cannot be built headlessly.
    static func openAIRealtimeTools(declarations: [[String: Any]],
                                    names: Set<String>? = nil) -> [[String: Any]] {
        declarations
            .filter { declaration in
                guard let names else { return true }
                return (declaration["name"] as? String).map(names.contains) ?? false
            }
            .map { declaration in
                [
                    "type": "function",
                    "name": declaration["name"] as? String ?? "",
                    "description": declaration["description"] as? String ?? "",
                    "parameters": declaration["parameters"] as Any,
                ] as [String: Any]
            }
    }

    /// The generic `{name, description, parameters}` declarations for a named subset — what a
    /// cross-provider diff test compares, so the comparison is of the contract rather than of two
    /// providers' envelopes.
    @MainActor
    static func declarations(registry: NativeToolRegistry?, names: Set<String>) -> [[String: Any]] {
        nativeToolDeclarations(registry: registry).filter { declaration in
            (declaration["name"] as? String).map(names.contains) ?? false
        }
    }

    /// Gemini REST API tool format
    @MainActor
    static func geminiRESTTools(registry: NativeToolRegistry?, includeOpenClaw: Bool, mcpClient: MCPClient? = nil) -> [[String: Any]] {
        var declarations = nativeToolDeclarations(registry: registry) + mcpToolDeclarations(mcpClient: mcpClient)
        if includeOpenClaw {
            declarations.append(execute)
        }
        return [["functionDeclarations": declarations]]
    }
}
