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

    /// Whether a request carries the gateway's `execute`: never on a vault-only job (Plan KE).
    @MainActor
    private static func declaresGateway(_ includeOpenClaw: Bool) -> Bool {
        includeOpenClaw && !VaultOnlyPolicy.jobIsSealed
    }

    /// Build declarations from native tool registry + optional OpenClaw execute tool.
    @MainActor
    static func allDeclarations(registry: NativeToolRegistry?, includeOpenClaw: Bool) -> [[String: Any]] {
        var declarations = nativeToolDeclarations(registry: registry)
        if declaresGateway(includeOpenClaw) {
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
    ///
    /// Plan GB: the same filter the registry applies before it will *execute* a tool — enabled,
    /// entitled, in the active mode and not HIPAA-disabled — so a refused tool is never *declared*
    /// either. Sorted by name (P5) so the declaration list is byte-stable turn to turn and the
    /// provider's prompt cache can reuse it; `allTools` iterates a dictionary.
    @MainActor
    static func nativeToolDeclarations(registry: NativeToolRegistry?) -> [[String: Any]] {
        guard let registry else { return [] }
        // Plan GD3: during a Field Assist job the field-mode profile narrows the list — read here,
        // on the main actor, as HIPAA mode is.
        let profileEnabled = Config.fieldToolProfileEnabled
        return nativeToolDeclarations(registry: registry,
                                      fieldJobActive: profileEnabled && FieldToolProfile.fieldJobActive,
                                      fieldProfileEnabled: profileEnabled,
                                      vaultOnly: VaultOnlyPolicy.jobIsSealed)
    }

    /// The same, with the job and profile flags stated — what a test drives to prove the declared
    /// schemas and the prompt's tool list agree.
    @MainActor
    static func nativeToolDeclarations(registry: NativeToolRegistry, fieldJobActive: Bool,
                                       fieldProfileEnabled: Bool, vaultOnly: Bool = false) -> [[String: Any]] {
        let declarable = Set(declarableNames(registry.toolNames,
                                             isEnabled: Config.isToolEnabled,
                                             hipaaMode: Config.hipaaMode,
                                             hipaaDisabled: Config.hipaaDisabledTools,
                                             fieldJobActive: fieldJobActive,
                                             fieldProfileEnabled: fieldProfileEnabled,
                                             activeTrades: FieldTradeGate.currentActiveTrades,
                                             vaultOnly: vaultOnly))
        return registry.allTools
            .filter { declarable.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parametersSchema,
                ] as [String: Any]
            }
    }

    /// The tool names that may be declared to a model, sorted: enabled, not disabled by HIPAA
    /// mode, and — during a Field Assist job with the profile on — in the field-mode profile
    /// (Plan GD3) — not a tool of a trade the technician has not turned on (`FieldTradeGate`), and not
    /// one a vault-only job seals (`VaultOnlyPolicy`, Plan KE).
    /// Pure — the headless test drives it without a registry.
    static func declarableNames(_ names: [String], isEnabled: (String) -> Bool,
                                hipaaMode: Bool, hipaaDisabled: Set<String>,
                                fieldJobActive: Bool = false,
                                fieldProfileEnabled: Bool = false,
                                activeTrades: [FieldTrade] = [],
                                vaultOnly: Bool = false) -> [String] {
        let allowed = names.filter { name in
            // Plan IU: the lookup tool is declared by the on-demand exposure alone
            // (`exposedDeclarations`), never as part of the full list, so a full-exposure request
            // is byte-for-byte what it was before the tool existed.
            guard name != ToolLookupTool.toolName else { return false }
            guard isEnabled(name) else { return false }
            return !(hipaaMode && hipaaDisabled.contains(name))
        }.sorted()
        return FieldToolProfile.declaredNames(all: allowed, fieldJobActive: fieldJobActive,
                                              enabled: fieldProfileEnabled, activeTrades: activeTrades,
                                              vaultOnly: vaultOnly)
    }

    /// Declarations for tools discovered on connected MCP servers, so the model can call them
    /// directly (the NativeToolRouter routes the call to the owning server). Returns the generic
    /// {name, description, parameters} shape used by the per-provider mappers.
    @MainActor
    static func mcpToolDeclarations(mcpClient: MCPClient?) -> [[String: Any]] {
        mcpToolDeclarations(mcpClient: mcpClient, vaultOnly: VaultOnlyPolicy.jobIsSealed)
    }

    /// The same, with the seal stated. A vault-only job declares no MCP tool at all (Plan KE): they
    /// are outside `FieldToolProfile`, so nothing else narrows them.
    @MainActor
    static func mcpToolDeclarations(mcpClient: MCPClient?, vaultOnly: Bool) -> [[String: Any]] {
        guard let mcpClient, !vaultOnly else { return [] }
        // Blocked (tool-poisoned) definitions are never offered to the model. Offered tools are
        // exposed ONLY under their fully-qualified name, so a server can't shadow a native tool
        // and the router routes the call back unambiguously (Plan R).
        return mcpClient.discoveredTools.filter { $0.trust.isOffered }
            .sorted { $0.qualifiedName < $1.qualifiedName }   // byte-stable for prompt caching (GB P5)
            .map { tool in
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

    /// The generic native + MCP declarations a request carries (Plan IU).
    ///
    /// `declaring` nil is full exposure: every declarable tool, native sorted then MCP sorted —
    /// exactly what every provider sent before on-demand schemas existed. Otherwise only the named
    /// tools, plus `lookup_tools` among the native ones, in the same order, so a round's list is
    /// byte-stable until something new is looked up.
    @MainActor
    static func exposedDeclarations(registry: NativeToolRegistry?, mcpClient: MCPClient?,
                                    declaring: Set<String>?) -> [[String: Any]] {
        let native = nativeToolDeclarations(registry: registry)
        let mcp = mcpToolDeclarations(mcpClient: mcpClient)
        guard let declaring else { return native + mcp }
        func keep(_ decl: [String: Any]) -> Bool {
            (decl["name"] as? String).map(declaring.contains) ?? false
        }
        var nativeKept = native.filter(keep)
        if let lookup = registry?.tool(named: ToolLookupTool.toolName) {
            nativeKept.append(["name": lookup.name, "description": lookup.description,
                               "parameters": lookup.parametersSchema] as [String: Any])
            nativeKept.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        }
        return nativeKept + mcp.filter(keep)
    }

    /// Every name the model could be declared right now — native and MCP, without the lookup tool
    /// or the OpenClaw `execute` — and the serialized size of their full declarations, which is
    /// what Automatic measures against the context window (Plan IU).
    @MainActor
    static func availableToolSet(registry: NativeToolRegistry?, mcpClient: MCPClient?) -> (names: [String], bytes: Int) {
        let all = exposedDeclarations(registry: registry, mcpClient: mcpClient, declaring: nil)
        let bytes = (try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]))?.count ?? 0
        return (all.compactMap { $0["name"] as? String }, bytes)
    }

    /// Anthropic tool format for the Messages API
    @MainActor
    static func anthropicTools(registry: NativeToolRegistry?, includeOpenClaw: Bool, mcpClient: MCPClient? = nil,
                               declaring: Set<String>? = nil) -> [[String: Any]] {
        var tools: [[String: Any]] = exposedDeclarations(registry: registry, mcpClient: mcpClient, declaring: declaring).map { decl in
            [
                "name": decl["name"] as! String,
                "description": decl["description"] as! String,
                "input_schema": decl["parameters"] as Any,
            ]
        }
        if declaresGateway(includeOpenClaw) {
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
    static func openAITools(registry: NativeToolRegistry?, includeOpenClaw: Bool, mcpClient: MCPClient? = nil,
                            declaring: Set<String>? = nil) -> [[String: Any]] {
        var tools: [[String: Any]] = exposedDeclarations(registry: registry, mcpClient: mcpClient, declaring: declaring).map { decl in
            [
                "type": "function",
                "function": [
                    "name": decl["name"] as! String,
                    "description": decl["description"] as! String,
                    "parameters": decl["parameters"] as Any,
                ] as [String: Any],
            ]
        }
        if declaresGateway(includeOpenClaw) {
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
    static func geminiRESTTools(registry: NativeToolRegistry?, includeOpenClaw: Bool, mcpClient: MCPClient? = nil,
                                declaring: Set<String>? = nil) -> [[String: Any]] {
        var declarations = exposedDeclarations(registry: registry, mcpClient: mcpClient, declaring: declaring)
        if declaresGateway(includeOpenClaw) {
            declarations.append(execute)
        }
        return [["functionDeclarations": declarations]]
    }
}
