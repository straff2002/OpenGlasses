import Foundation
import os.lock

/// Routes tool calls: native tools → MCP servers → OpenClaw fallback.
@MainActor
final class NativeToolRouter {
    let registry: NativeToolRegistry
    var openClawBridge: OpenClawBridge?
    var mcpClient: MCPClient?

    /// Callback for periodic "still working" updates during long tool executions.
    /// Set by AppState to speak progress updates via TTS.
    /// Fires every 10 s while a tool runs, with the elapsed seconds. The *consumer* decides how to
    /// surface it (Plan CB): Direct mode speaks a deterministic phrase; live modes stay silent here
    /// because the two-phase ack in `ToolCallRouter` already covers them in the model's own voice.
    var onLongRunningUpdate: ((Int) -> Void)?

    /// Human-in-the-loop gate for high-impact / irreversible tool calls. Set by AppState.
    /// When agent mode is on, destructive actions are confirmed by the user before running —
    /// the backstop against a prompt-injected instruction driving the model to act unprompted.
    var confirmationCoordinator: ToolConfirmationCoordinator?

    /// Builds the live `SafetyContext` for the deterministic supervisor (Plan S). Injected by
    /// AppState from current location + clock + persisted rules. When nil, the router falls back
    /// to settings-only context (no location), so the rules still apply headlessly.
    var safetyContextProvider: (() -> SafetyContext)?

    /// Called when an acting (high-impact) tool is held because presence lowered the autonomy
    /// ceiling (Plan W) — AppState records it for surfacing when the user re-engages. The string is
    /// a human-readable action summary.
    var onActionHeld: ((String) -> Void)?

    /// Tool execution timeout in seconds (prevents hung tools from blocking forever).
    var toolTimeoutSeconds: TimeInterval = 30

    /// Names of tools routed since the last `takeTurnToolNames()` — lets the memory loop
    /// (Memory & Recall Phase 3) see which tools a turn used, to spot repeated multi-step
    /// requests worth saving as a skill.
    private(set) var turnToolNames: [String] = []

    /// Return and clear the tools routed this turn.
    func takeTurnToolNames() -> [String] {
        let names = turnToolNames
        turnToolNames = []
        return names
    }

    init(registry: NativeToolRegistry, openClawBridge: OpenClawBridge? = nil) {
        self.registry = registry
        self.openClawBridge = openClawBridge
    }

    /// Handle a tool call by name. Routing order: native → MCP → OpenClaw → error.
    func handleToolCall(name: String, args: [String: Any]) async -> ToolResult {
        turnToolNames.append(name)   // Phase 3: track tools used this turn for skill detection

        // 0a. Actuation floor (Plan BC): confirmation before irreversible, security-relevant
        // physical actions (unlock a door, open a garage, disarm an alarm) even when agent mode is
        // OFF — so a prompt-injected sign/web result can't silently actuate. When agent mode is on,
        // the SafetySupervisor below (0b) already confirms these high-impact tools, so this floor
        // only needs to cover the agent-mode-off default and would otherwise double-prompt.
        if !Config.agentModeEnabled,
           HighImpactToolPolicy.mayRequireConfirmation(tool: name),
           case .requiresConfirmation(let summary) = HighImpactToolPolicy.evaluate(tool: name, args: args) {
            if let coordinator = confirmationCoordinator {
                NSLog("[NativeToolRouter] Actuation floor requires confirmation for %@: %@", name, summary)
                let approved = await coordinator.requestConfirmation(toolName: name, summary: summary)
                guard approved else {
                    NSLog("[NativeToolRouter] User declined %@ (actuation floor)", name)
                    return .failure("The user did NOT approve this action, so '\(name)' was not performed. Do not retry it; tell the user it was cancelled unless they explicitly ask again.")
                }
            } else {
                // No confirmation UI wired (e.g. headless): fail closed rather than actuate blind.
                NSLog("[NativeToolRouter] No confirmation coordinator; refusing high-impact %@", name)
                return .failure("'\(name)' requires user confirmation, which isn't available right now, so it was not performed. Tell the user to try again with the app in the foreground.")
            }
        }

        // 0b. Deterministic safety supervisor (Plan S): the single pre-execution safety gate when
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
                // Plan W: when the block is the presence autonomy ceiling on an acting tool (the
                // user is idle/away), hold it for re-engagement instead of reporting a hard safety
                // block — the action was deferred, not forbidden.
                if context.autonomy != .autoAct,
                   PromptInjectionPolicy.isHighImpact(toolName: name, args: args) {
                    let summary = PromptInjectionPolicy.actionSummary(toolName: name, args: args)
                    onActionHeld?(summary)
                    NSLog("[NativeToolRouter] Held %@ for re-engagement (autonomy=%@)", name, context.autonomy.rawValue)
                    return .failure("'\(name)' wasn't run because you've been away from the glasses; I've held it to raise when you're back. Do not retry automatically.")
                }
                return .failure("'\(name)' was blocked by a safety rule (\(reason)). Do not retry; tell the user it was blocked for safety.")
            case .confirm(let reason):
                guard let coordinator = confirmationCoordinator else {
                    // No confirmation UI wired (e.g. headless): fail closed rather than actuate
                    // blind, exactly as the agent-mode-off floor above does. Falling through here
                    // would make the *more* autonomous mode the one that skips the gate.
                    NSLog("[NativeToolRouter] No confirmation coordinator; refusing %@ (%@)", name, reason)
                    return .failure("'\(name)' requires user confirmation, which isn't available right now, so it was not performed. Tell the user to try again with the app in the foreground.")
                }
                // High-impact tools get the richer action summary; other rules use their reason.
                let summary = PromptInjectionPolicy.isHighImpact(toolName: name, args: args)
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
        if let mcp = mcpClient, let tool = mcp.offeredTool(matching: name),
           let server = mcp.server(id: tool.serverId), server.enabled {
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

        // 3. Fall through to OpenClaw for "execute" or unknown tools (BK P0: gateway delegation is
        // an autonomous action, so it needs Agent Mode on, not just a configured gateway).
        if let bridge = openClawBridge, Config.isOpenClawAgentActive {
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
                self?.onLongRunningUpdate?(elapsed)
            }
        }

        // Race: tool execution vs timeout.
        //
        // Deliberately *not* a task group. A group implicitly awaits all of its children before
        // returning, so when the timeout sentinel won the race the group still blocked until the
        // real work finished — `cancelAll()` only signals cooperative cancellation, and most tools
        // here (HomeKit writes, URL-scheme launches, third-party SDK calls) never check it. The
        // "timeout" therefore bounded nothing.
        //
        // Instead the two racers resume a single continuation and `resolved` decides the winner, so
        // the caller returns on time. Cancellation is still requested, but work that ignores it is
        // abandoned rather than waited on — and logged if it lands late, since its side effect will
        // have happened after the model was told the call timed out.
        let resolved = OSAllocatedUnfairLock(initialState: false)
        /// Returns true for the first caller only.
        func claim() -> Bool {
            resolved.withLock { alreadyResolved in
                if alreadyResolved { return false }
                alreadyResolved = true
                return true
            }
        }

        let result: ToolResult = await withCheckedContinuation { continuation in
            let workTask = Task {
                let outcome: ToolResult
                do {
                    outcome = .success(try await work())
                } catch {
                    outcome = .failure("Tool error: \(error.localizedDescription)")
                }
                if claim() {
                    continuation.resume(returning: outcome)
                } else {
                    NSLog("[NativeToolRouter] Tool %@ finished after it timed out — its effect landed late",
                          name)
                }
            }

            Task { [toolTimeoutSeconds] in
                try? await Task.sleep(nanoseconds: UInt64(toolTimeoutSeconds * 1_000_000_000))
                guard claim() else { return }
                workTask.cancel()   // best effort; cancellation-aware tools stop here
                continuation.resume(
                    returning: .failure("Tool '\(name)' timed out after \(Int(toolTimeoutSeconds))s"))
            }
        }

        stillWorkingTask.cancel()

        let duration = Date().timeIntervalSince(startTime)
        switch result {
        case .success(let text):
            NSLog("[NativeToolRouter] Tool %@ succeeded in %.1fs: %@", name, duration, String(text.prefix(200)))
        case .failure(let err):
            NSLog("[NativeToolRouter] Tool %@ failed in %.1fs: %@", name, duration, err)
            // Skill Self-Evolution (Plan AW): a genuine tool-execution error is a skill-gap signal.
            // Record it off the critical path; the service is Agent-Mode-gated and re-checks. Timeouts
            // and intentional outcomes are filtered out so the proposal bank stays clean.
            if Config.agentModeEnabled, ToolFailureFilter.shouldRecord(err) {
                let sample = FailureSample(kind: .toolError, prompt: "tool: \(name)", response: err,
                                          toolName: name, at: Date())
                Task { @MainActor in
                    SkillEvolutionService.shared.record(sample)
                    _ = await SkillEvolutionService.shared.evolveIfNeeded()
                }
            }
        }

        return result
    }
}
