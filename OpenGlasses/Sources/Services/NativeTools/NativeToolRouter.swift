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

    /// Builds the live `SafetyContext` for the deterministic supervisor (Plan S). Injected by
    /// AppState from current location + clock + persisted rules. When nil, the router falls back
    /// to settings-only context (no location), so the rules still apply headlessly.
    var safetyContextProvider: (() -> SafetyContext)?

    /// Tool execution timeout in seconds (prevents hung tools from blocking forever).
    var toolTimeoutSeconds: TimeInterval = 30

    init(registry: NativeToolRegistry, openClawBridge: OpenClawBridge? = nil) {
        self.registry = registry
        self.openClawBridge = openClawBridge
    }

    /// Handle a tool call by name. Routing order: native → MCP → OpenClaw → error.
    func handleToolCall(name: String, args: [String: Any]) async -> ToolResult {
        // 0. Deterministic safety supervisor (Plan S): the single pre-execution safety gate when
        // agent mode is on. It subsumes the high-impact confirmation backstop — its
        // `needsVoiceApproval` rule reproduces it — and adds deterministic block/confirm rules
        // (geofence, quiet hours, irreversible floor). A `.block` veto short-circuits with no
        // execution; a `.confirm` routes through the same human-in-the-loop gate. Even if
        // untrusted content talked the model into a destructive tool, nothing runs without this.
        if Config.agentModeEnabled {
            let context = safetyContextProvider?() ?? SafetyContext.live(now: Date(), location: nil)
            switch SafetySupervisor.evaluate(tool: name, args: args, context: context) {
            case .allow:
                break
            case .block(let reason):
                NSLog("[NativeToolRouter] Safety supervisor BLOCKED %@: %@", name, reason)
                return .failure("'\(name)' was blocked by a safety rule (\(reason)). Do not retry; tell the user it was blocked for safety.")
            case .confirm(let reason):
                if let coordinator = confirmationCoordinator {
                    // High-impact tools get the richer action summary; other rules use their reason.
                    let summary = PromptInjectionPolicy.isHighImpact(toolName: name)
                        ? PromptInjectionPolicy.actionSummary(toolName: name, args: args)
                        : reason
                    NSLog("[NativeToolRouter] Safety supervisor requires confirmation for %@: %@", name, reason)
                    let approved = await coordinator.requestConfirmation(toolName: name, summary: summary)
                    guard approved else {
                        NSLog("[NativeToolRouter] User declined %@", name)
                        return .failure("The user did NOT approve this action, so '\(name)' was not performed. Do not retry it; tell the user it was cancelled unless they explicitly ask again.")
                    }
                }
            }
        }

        // 1. Check native tools first
        if let tool = registry.tool(named: name) {
            NSLog("[NativeToolRouter] Executing native tool: %@", name)
            return await executeWithTimeout(name: name) {
                try await tool.execute(args: args)
            }
        }

        // 2. Check MCP servers for the tool (matched on its fully-qualified, namespace-isolated
        //    name so a server can't shadow a native tool). Blocked (tool-poisoned) tools are
        //    never matched here, so the model can't reach them.
        if let mcp = mcpClient, let tool = mcp.offeredTool(matching: name), let server = mcp.server(id: tool.serverId) {
            // Outbound egress screen (Plan R): secrets/PII never leave the device for a
            // third-party server. A `.block` verdict is treated like a declined confirmation —
            // no network call, and a failure the model is told not to retry.
            let verdict = EgressScreen.evaluate(args, policy: server.policy)
            if !verdict.hits.isEmpty {
                mcp.recordEgress(serverLabel: server.label, toolName: tool.name, verdict: verdict)
            }
            if let reason = verdict.blockReason {
                NSLog("[NativeToolRouter] Egress screen withheld MCP tool %@: %@", name, reason)
                return .failure("The arguments to '\(name)' contained sensitive data, so the call to \(server.label) was withheld for safety (\(reason)). Do not retry; tell the user it was blocked.")
            }
            let outboundArgs = verdict.redactedArgs ?? args
            NSLog("[NativeToolRouter] Executing MCP tool: %@", name)
            return await executeWithTimeout(name: name) {
                await mcp.performCall(tool: tool, server: server, arguments: outboundArgs)
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
