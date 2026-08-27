import Foundation
import os.lock

/// The one object allowed to dispatch an acting tool. Composition surfaces (a skill pack's `.tool`
/// binding, a Siri Action) hold this rather than a `NativeTool` instance, so there is no shape in
/// which they can resolve a target and execute it themselves.
@MainActor
protocol ToolExecutionAuthority: AnyObject {
    func execute(_ call: ResolvedToolCall) async -> ToolResult
}

/// Routes tool calls: native tools → MCP servers → OpenClaw fallback.
@MainActor
final class NativeToolRouter: ToolExecutionAuthority {
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

    /// What a composition may reach. Defaults to refusing any target the router would have gated —
    /// admission and merge-time quarantine already keep such bindings out of the registry, so the
    /// routed confirmation path is proven by tests before it is anything's default.
    var composedTargetPolicy: ComposedToolPolicy.Mode = .refuse

    /// Content-free record of refusals, for diagnostics and for tests to assert against.
    let authorizationEvents = ToolAuthorizationEventLog()

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

    /// Handle a root tool call from a model turn. A thin adapter over `execute(_:)` so the provider
    /// integrations keep one signature; everything below the adapter sees the same resolved call a
    /// composed child does.
    func handleToolCall(name: String, args: [String: Any]) async -> ToolResult {
        await execute(.root(name: name, arguments: ToolArguments(args), origin: .model))
    }

    /// Authorize and dispatch one resolved call. Routing order: native → MCP → OpenClaw → error.
    ///
    /// Every acting path in the app funnels through here — a model tool call, a deterministically
    /// classified utterance, a Siri Action, and a skill pack's `.tool` binding — so the policy
    /// ladder is evaluated exactly once against the *real* target and its final arguments.
    func execute(_ call: ResolvedToolCall) async -> ToolResult {
        let name = call.name
        let args = call.arguments.rawValues
        // Phase 3: track tools used this turn for skill detection. A composed child records its
        // resolved target *and* keeps the pack action its parent already recorded — the pair is the
        // useful signal; only the user-visible progress reporting below is de-duplicated.
        turnToolNames.append(name)

        let safetyContext = safetyContextProvider?() ?? SafetyContext.live(now: Date(), location: nil)
        let decision = ToolAuthorizationPolicy.evaluate(.init(
            call: call,
            agentModeEnabled: Config.agentModeEnabled,
            safetyContext: safetyContext,
            composedTargets: composedTargetPolicy))

        switch decision {
        case .allow:
            break

        case .refuse(let reason, let message):
            authorizationEvents.record(call: call, verdict: reason.rawValue)
            return .failure(message)

        case .block(let message):
            NSLog("[NativeToolRouter] Safety supervisor BLOCKED %@", name)
            return .failure(message)

        case .hold(let summary, let message):
            onActionHeld?(summary)
            NSLog("[NativeToolRouter] Held %@ for re-engagement (autonomy=%@)", name,
                  safetyContext.autonomy.rawValue)
            return .failure(message)

        case .confirm(let summary):
            guard let coordinator = confirmationCoordinator else {
                // No confirmation UI wired (e.g. headless): fail closed rather than actuate blind.
                NSLog("[NativeToolRouter] No confirmation coordinator; refusing %@", name)
                return .failure(ToolAuthorizationPolicy.unavailableConfirmationMessage(name))
            }
            NSLog("[NativeToolRouter] Confirmation required for %@: %@", name, summary)
            let approved = await coordinator.requestConfirmation(toolName: name, summary: summary)
            guard approved else {
                NSLog("[NativeToolRouter] User declined %@", name)
                return .failure(ToolAuthorizationPolicy.declineMessage(name))
            }
        }

        // Only a model's own root call speaks "still working" — a composed child runs inside its
        // parent's execution, which is already reporting, and the non-model origins have no turn to
        // narrate.
        let reportProgress = call.context.origin == .model && call.context.depth == 0

        // 1. Check native tools first.
        if let tool = registry.tool(named: name) {
            NSLog("[NativeToolRouter] Executing native tool: %@", name)
            return await executeWithTimeout(name: name, reportProgress: reportProgress) {
                // The executing call is task-local so a tool that composes another one names its
                // own invocation as the parent instead of inventing a fresh root.
                try await ToolInvocationScope.$current.withValue(call) {
                    try await tool.execute(args: args)
                }
            }
        }

        // A composition binds a native tool by name and nothing else. Falling through to MCP or the
        // gateway here would let an authored binding reach a third-party server the user never
        // pointed it at.
        guard !call.context.origin.isComposition else {
            return .failure("This skill's underlying tool '\(name)' isn't available on this device.")
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
            return await executeWithTimeout(name: name, reportProgress: reportProgress) {
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
    private func executeWithTimeout(name: String, reportProgress: Bool = true,
                                    work: @escaping () async throws -> String) async -> ToolResult {
        let startTime = Date()

        // "Still working" timer: fires every 10 seconds during long operations
        let stillWorkingTask = Task { @MainActor [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard !Task.isCancelled else { break }
                elapsed += 10
                NSLog("[NativeToolRouter] Tool %@ still running after %ds", name, elapsed)
                if reportProgress { self?.onLongRunningUpdate?(elapsed) }
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
