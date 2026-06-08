import Foundation

/// Routes tool calls: native tools → MCP servers → OpenClaw fallback.
@MainActor
final class NativeToolRouter {
    let registry: NativeToolRegistry
    var openClawBridge: OpenClawBridge?
    var mcpClient: MCPClient?

    /// Callback for periodic "still working" updates during long tool executions.
    /// Set by AppState to speak progress updates via TTS.
    var onLongRunningUpdate: ((String) -> Void)?

    /// Human-in-the-loop gate for high-impact / irreversible tool calls. Set by AppState.
    /// When agent mode is on, destructive actions are confirmed by the user before running —
    /// the backstop against a prompt-injected instruction driving the model to act unprompted.
    var confirmationCoordinator: ToolConfirmationCoordinator?

    /// Tool execution timeout in seconds (prevents hung tools from blocking forever).
    var toolTimeoutSeconds: TimeInterval = 30

    init(registry: NativeToolRegistry, openClawBridge: OpenClawBridge? = nil) {
        self.registry = registry
        self.openClawBridge = openClawBridge
    }

    /// Handle a tool call by name. Routing order: native → MCP → OpenClaw → error.
    func handleToolCall(name: String, args: [String: Any]) async -> ToolResult {
        // 0. Prompt-injection backstop: gate high-impact / irreversible actions behind an
        // explicit user confirmation when agent mode is on. Even if untrusted content talked
        // the model into calling a destructive tool, nothing runs without the user approving.
        if Config.agentModeEnabled,
           PromptInjectionPolicy.isHighImpact(toolName: name),
           let coordinator = confirmationCoordinator {
            let summary = PromptInjectionPolicy.actionSummary(toolName: name, args: args)
            NSLog("[NativeToolRouter] Requesting user confirmation for high-impact tool: %@", name)
            let approved = await coordinator.requestConfirmation(toolName: name, summary: summary)
            guard approved else {
                NSLog("[NativeToolRouter] User declined high-impact tool: %@", name)
                return .failure("The user did NOT approve this action, so '\(name)' was not performed. Do not retry it; tell the user it was cancelled unless they explicitly ask again.")
            }
        }

        // 1. Check native tools first
        if let tool = registry.tool(named: name) {
            NSLog("[NativeToolRouter] Executing native tool: %@", name)
            return await executeWithTimeout(name: name) {
                try await tool.execute(args: args)
            }
        }

        // 2. Check MCP servers for the tool
        if let mcp = mcpClient, mcp.discoveredTools.contains(where: { $0.name == name }) {
            NSLog("[NativeToolRouter] Executing MCP tool: %@", name)
            return await executeWithTimeout(name: name) {
                return await mcp.executeTool(name: name, arguments: args)
            }
        }

        // 3. Fall through to OpenClaw for "execute" or unknown tools
        if let bridge = openClawBridge, Config.isOpenClawConfigured {
            let taskDesc = args["task"] as? String ?? String(describing: args)
            NSLog("[NativeToolRouter] Delegating to OpenClaw: %@(%@)", name, String(taskDesc.prefix(100)))
            return await bridge.delegateTask(task: taskDesc, toolName: name)
        }

        return .failure("Unknown tool: \(name)")
    }

    // MARK: - Timeout + "Still Working" Updates

    /// Execute a tool with a timeout and periodic "still working" TTS updates.
    private func executeWithTimeout(name: String, work: @escaping () async throws -> String) async -> ToolResult {
        let startTime = Date()

        // "Still working" timer: fires every 10 seconds during long operations
        let stillWorkingTask = Task { @MainActor [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard !Task.isCancelled else { break }
                elapsed += 10
                NSLog("[NativeToolRouter] Tool %@ still running after %ds", name, elapsed)
                self?.onLongRunningUpdate?("Still working on that...")
            }
        }

        // Race: tool execution vs timeout
        let result: ToolResult = await withTaskGroup(of: ToolResult.self) { group in
            // The actual work
            group.addTask {
                do {
                    let result = try await work()
                    return .success(result)
                } catch {
                    return .failure("Tool error: \(error.localizedDescription)")
                }
            }

            // Timeout sentinel
            group.addTask { [toolTimeoutSeconds] in
                try? await Task.sleep(nanoseconds: UInt64(toolTimeoutSeconds * 1_000_000_000))
                return .failure("Tool '\(name)' timed out after \(Int(toolTimeoutSeconds))s")
            }

            // First to finish wins
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        stillWorkingTask.cancel()

        let duration = Date().timeIntervalSince(startTime)
        switch result {
        case .success(let text):
            NSLog("[NativeToolRouter] Tool %@ succeeded in %.1fs: %@", name, duration, String(text.prefix(200)))
        case .failure(let err):
            NSLog("[NativeToolRouter] Tool %@ failed in %.1fs: %@", name, duration, err)
        }

        return result
    }
}
