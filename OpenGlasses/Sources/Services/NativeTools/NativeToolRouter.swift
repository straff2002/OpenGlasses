import Foundation
import os.lock

/// The one object allowed to dispatch an acting tool. Composition surfaces (a skill pack's `.tool`
/// binding, a Siri Action) hold this rather than a `NativeTool` instance, so there is no shape in
/// which they can resolve a target and execute it themselves.
@MainActor
protocol ToolExecutionAuthority: AnyObject {
    func execute(_ call: ResolvedToolCall) async -> ToolExecutionOutcome
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
        await executeRoot(name: name, args: args).toolResult
    }

    /// The same root adapter, keeping the typed outcome. Callers that can act on the retry
    /// disposition (the tool-loop driver, the live-session router) use this one; the `ToolResult`
    /// adapter above stays for the provider wires, which only ever needed the text.
    func executeRoot(name: String, args: [String: Any],
                     origin: ToolInvocationOrigin = .model) async -> ToolExecutionOutcome {
        await execute(.root(name: name, arguments: ToolArguments(args), origin: origin))
    }

    /// Authorize and dispatch one resolved call. Routing order: native → MCP → OpenClaw → error.
    ///
    /// Every acting path in the app funnels through here — a model tool call, a deterministically
    /// classified utterance, a Siri Action, and a skill pack's `.tool` binding — so the policy
    /// ladder is evaluated exactly once against the *real* target and its final arguments.
    func execute(_ call: ResolvedToolCall) async -> ToolExecutionOutcome {
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

        // Every verdict below stopped the call before it ran, so they are all `rejected`: nothing
        // happened, and repeating the call reaches the same answer.
        case .refuse(let reason, let message):
            authorizationEvents.record(call: call, verdict: reason.rawValue)
            return .rejected(reason: message)

        case .block(let message):
            NSLog("[NativeToolRouter] Safety supervisor BLOCKED %@", name)
            return .rejected(reason: message)

        case .hold(let summary, let message):
            onActionHeld?(summary)
            NSLog("[NativeToolRouter] Held %@ for re-engagement (autonomy=%@)", name,
                  safetyContext.autonomy.rawValue)
            return .rejected(reason: message)

        case .confirm(let summary):
            guard let coordinator = confirmationCoordinator else {
                // No confirmation UI wired (e.g. headless): fail closed rather than actuate blind.
                NSLog("[NativeToolRouter] No confirmation coordinator; refusing %@", name)
                return .rejected(reason: ToolAuthorizationPolicy.unavailableConfirmationMessage(name))
            }
            NSLog("[NativeToolRouter] Confirmation required for %@: %@", name, summary)
            let approved = await coordinator.requestConfirmation(toolName: name, summary: summary)
            guard approved else {
                NSLog("[NativeToolRouter] User declined %@", name)
                return .rejected(reason: ToolAuthorizationPolicy.declineMessage(name))
            }
        }

        // Only a model's own root call speaks "still working" — a composed child runs inside its
        // parent's execution, which is already reporting, and the non-model origins have no turn to
        // narrate.
        let reportProgress = call.context.origin == .model && call.context.depth == 0

        // 1. Check native tools first.
        if let tool = registry.tool(named: name) {
            NSLog("[NativeToolRouter] Executing native tool: %@", name)
            return await executeWithTimeout(name: name, semantics: tool.executionSemantics,
                                            operationID: call.context.invocationID,
                                            reportProgress: reportProgress) {
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
            return .failedBeforeExecution(
                reason: "This skill's underlying tool '\(name)' isn't available on this device.")
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
                return .rejected(reason: "The arguments to '\(name)' contained sensitive data, so the call to \(server.label) was withheld for safety (\(reason)). Do not retry; tell the user it was blocked.")
            }
            let outboundArgs = verdict.redactedArgs ?? args
            NSLog("[NativeToolRouter] Executing MCP tool: %@", name)
            // A third-party server's tool declares nothing about itself, so it gets the same
            // assumption an unclassified native tool gets: it reached outside, we can't stop it,
            // and we don't know what a timeout left behind.
            return await executeWithTimeout(name: name, semantics: .conservativeDefault,
                                            operationID: call.context.invocationID,
                                            reportProgress: reportProgress) {
                await mcp.performCall(tool: tool, server: server, arguments: outboundArgs)
            }
        }

        // 3. Fall through to OpenClaw for "execute" or unknown tools (BK P0: gateway delegation is
        // an autonomous action, so it needs Agent Mode on, not just a configured gateway).
        if let bridge = openClawBridge, Config.isOpenClawAgentActive {
            let taskDesc = args["task"] as? String ?? String(describing: args)
            NSLog("[NativeToolRouter] Delegating to OpenClaw: %@(%@)", name, String(taskDesc.prefix(100)))
            // The bridge answers authoritatively or not at all — it has no timeout race of its own.
            return ToolExecutionOutcome(await bridge.delegateTask(task: taskDesc, toolName: name))
        }

        return .failedBeforeExecution(reason: "Unknown tool: \(name)")
    }

    // MARK: - Timeout + "Still Working" Updates

    /// Execute a tool with a timeout and periodic "still working" TTS updates.
    ///
    /// The tool's own semantics decide three things here: how long the wait is, whether cancelling
    /// the abandoned work is worth asking for, and what a lost race *means*. Only a read yields an
    /// authoritative failure; anything that writes, sends, or actuates yields `outcomeUnknown`
    /// instead, because its effect may land in the moment after we stopped listening.
    private func executeWithTimeout(name: String, semantics: ToolExecutionSemantics,
                                    operationID: String, reportProgress: Bool = true,
                                    work: @escaping () async throws -> String) async -> ToolExecutionOutcome {
        let startTime = Date()
        let timeoutSeconds = semantics.timeout.resolved(default: toolTimeoutSeconds)

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

        let outcome: ToolExecutionOutcome = await withCheckedContinuation { continuation in
            let workTask = Task {
                let finished: ToolExecutionOutcome
                do {
                    finished = .completed(try await work())
                } catch let relayed as RelayedToolOutcome {
                    // A composing tool handing back the child outcome it can't answer for.
                    finished = relayed.outcome
                } catch {
                    finished = .failedBeforeExecution(
                        reason: "Tool error: \(error.localizedDescription)")
                }
                if claim() {
                    continuation.resume(returning: finished)
                } else {
                    NSLog("[NativeToolRouter] Tool %@ finished after it timed out — its effect landed late",
                          name)
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard claim() else { return }
                // Asking a tool that never checks for cancellation to stop tells the caller nothing
                // and hides that the work is still in flight; only ask when it can answer.
                if semantics.cancellation.respondsToCancellation { workTask.cancel() }
                let seconds = Int(timeoutSeconds)
                continuation.resume(returning: semantics.timeoutIsAuthoritative
                    ? .failedBeforeExecution(
                        reason: ToolExecutionOutcome.timedOutRead(tool: name, seconds: seconds))
                    : .outcomeUnknown(
                        operationID: operationID,
                        message: ToolExecutionOutcome.timedOutUnknown(tool: name, seconds: seconds)))
            }
        }

        stillWorkingTask.cancel()

        let duration = Date().timeIntervalSince(startTime)
        switch outcome {
        case .completed(let text):
            NSLog("[NativeToolRouter] Tool %@ succeeded in %.1fs: %@", name, duration, String(text.prefix(200)))
        case .outcomeUnknown:
            // Not a failure and not a success: the effect may still be in flight. Nothing is fed to
            // the skill-gap signal, and nothing may retry it automatically.
            NSLog("[NativeToolRouter] Tool %@ outcome unknown after %.1fs (%@ / %@)", name, duration,
                  semantics.effect.rawValue, semantics.cancellation.rawValue)
        case .rejected(let reason), .failedBeforeExecution(let reason):
            NSLog("[NativeToolRouter] Tool %@ failed in %.1fs: %@", name, duration, reason)
            // Skill Self-Evolution (Plan AW): a genuine tool-execution error is a skill-gap signal.
            // Record it off the critical path; the service is Agent-Mode-gated and re-checks. Timeouts
            // and intentional outcomes are filtered out so the proposal bank stays clean.
            if Config.agentModeEnabled, ToolFailureFilter.shouldRecord(reason) {
                let sample = FailureSample(kind: .toolError, prompt: "tool: \(name)", response: reason,
                                          toolName: name, at: Date())
                Task { @MainActor in
                    SkillEvolutionService.shared.record(sample)
                    _ = await SkillEvolutionService.shared.evolveIfNeeded()
                }
            }
        }

        return outcome
    }
}
