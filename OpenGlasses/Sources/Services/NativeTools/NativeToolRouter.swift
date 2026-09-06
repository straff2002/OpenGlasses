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

    /// Durable at-most-once record for operations that cannot safely be repeated. Injected so a
    /// test writes to its own directory; the app-wide protected store is the default because
    /// durability here is the safety property, not a wiring detail somebody might forget.
    var operationJournal: any OperationJournal = ProtectedOperationJournal.shared

    /// One operation at a time per logical resource, for the adapters that can't de-duplicate for
    /// themselves.
    private let resourceSerializer = OperationResourceSerializer()

    /// An operation's journal state changed. The one case that matters is a record arriving with
    /// `resolvedLate` set: the caller was already told the outcome was unknown and the turn has
    /// moved on, so the answer belongs to operation status and diagnostics — never to a second
    /// spoken success after the fact.
    var onOperationStatusChange: ((OperationRecord) -> Void)?

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
    ///
    /// `invocationID` is the caller's own identifier for the delivery — a provider's `tool_use` /
    /// `tool_call` id, or a live-session function-call id. Supplying it is what lets a redelivery of
    /// the same call be recognised as the same operation instead of executed a second time; where a
    /// caller has no stable id, the default fresh UUID keeps every delivery distinct.
    func executeRoot(name: String, args: [String: Any],
                     origin: ToolInvocationOrigin = .model,
                     invocationID: String = UUID().uuidString) async -> ToolExecutionOutcome {
        await execute(.root(name: name, arguments: ToolArguments(args), origin: origin,
                            invocationID: invocationID))
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
            PrivacyLog.toolGate(.blockedBySafety, tool: name)
            return .rejected(reason: message)

        case .hold(let summary, let message):
            onActionHeld?(summary)
            PrivacyLog.toolGate(.heldForReengagement, tool: name,
                                detail: PrivacyToken(safetyContext.autonomy.rawValue))
            return .rejected(reason: message)

        case .confirm(let summary):
            guard let coordinator = confirmationCoordinator else {
                // No confirmation UI wired (e.g. headless): fail closed rather than actuate blind.
                PrivacyLog.toolGate(.noConfirmationCoordinator, tool: name)
                return .rejected(reason: ToolAuthorizationPolicy.unavailableConfirmationMessage(name))
            }
            // The confirmation summary quotes the arguments back ("send \'meet at 8\' to …"),
            // which is the very thing the gate is holding — so the tool name is all that is kept.
            PrivacyLog.toolGate(.confirmationRequired, tool: name)
            let approved = await coordinator.requestConfirmation(toolName: name, summary: summary)
            guard approved else {
                PrivacyLog.toolGate(.declinedByUser, tool: name)
                return .rejected(reason: ToolAuthorizationPolicy.declineMessage(name))
            }
        }

        // Only a model's own root call speaks "still working" — a composed child runs inside its
        // parent's execution, which is already reporting, and the non-model origins have no turn to
        // narrate.
        let reportProgress = call.context.origin == .model && call.context.depth == 0

        // Cancelled while it was being authorized — the turn was abandoned, the session torn down.
        // Nothing has been dispatched and nothing is journaled: this is the one place where "it did
        // not happen" is something we actually know.
        if Task.isCancelled {
            return .failedBeforeExecution(reason: Self.cancelledBeforeDispatch(name))
        }

        // 1. Check native tools first.
        if let tool = registry.tool(named: name) {
            PrivacyLog.toolDispatch(.native, tool: name)
            return await dispatch(call, semantics: tool.executionSemantics,
                                  reportProgress: reportProgress) { key in
                // The executing call is task-local so a tool that composes another one names its
                // own invocation as the parent instead of inventing a fresh root; the operation's
                // idempotency key rides alongside for any adapter that can put one on the wire.
                try await ToolInvocationScope.$current.withValue(call) {
                    try await OperationScope.$idempotencyKey.withValue(key) {
                        try await tool.execute(args: args)
                    }
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
                // The screen's reason names the patterns it matched *in the arguments*.
                PrivacyLog.toolGate(.egressWithheld, tool: name)
                return .rejected(reason: "The arguments to '\(name)' contained sensitive data, so the call to \(server.label) was withheld for safety (\(reason)). Do not retry; tell the user it was blocked.")
            }
            let outboundArgs = verdict.redactedArgs ?? args
            PrivacyLog.toolDispatch(.mcp, tool: name)
            // A third-party server's tool declares nothing about itself, so it gets the same
            // assumption an unclassified native tool gets: it reached outside, we can't stop it,
            // and we don't know what a timeout left behind.
            return await dispatch(call, semantics: .conservativeDefault,
                                  reportProgress: reportProgress) { key in
                await mcp.performCall(tool: tool, server: server, arguments: outboundArgs,
                                      idempotencyKey: key)
            }
        }

        // 3. Fall through to OpenClaw for "execute" or unknown tools (BK P0: gateway delegation is
        // an autonomous action, so it needs Agent Mode on, not just a configured gateway).
        if let bridge = openClawBridge, Config.isOpenClawAgentActive {
            let taskDesc = args["task"] as? String ?? String(describing: args)
            // The task description is the request being handed to the gateway agent — the
            // wearer's instruction in full.
            PrivacyLog.toolDispatch(.gateway, tool: name)
            // The bridge answers authoritatively or not at all — it has no timeout race of its own.
            return ToolExecutionOutcome(await bridge.delegateTask(task: taskDesc, toolName: name))
        }

        return .failedBeforeExecution(reason: "Unknown tool: \(name)")
    }

    // MARK: - At-most-once dispatch

    /// Take one authorized call to the tool, at most once.
    ///
    /// Operations whose repetition is harmless — every read, and everything that converges on the
    /// same world state — go straight through: journaling them would buy nothing and would fill a
    /// security store with noise. Everything else is admitted against the journal first, so a second
    /// delivery of a call already recorded is answered from the record instead of being run again,
    /// across a process restart as well as within a session.
    private func dispatch(_ call: ResolvedToolCall, semantics: ToolExecutionSemantics,
                          reportProgress: Bool,
                          work: @escaping (String) async throws -> String) async -> ToolExecutionOutcome {
        let key = OperationIdempotencyKey.derive(call)
        let name = call.name

        guard !semantics.isSafeToRepeat else {
            return await executeWithTimeout(name: name, semantics: semantics,
                                            operationID: call.context.invocationID,
                                            reportProgress: reportProgress) { try await work(key) }
        }

        let journal = operationJournal
        switch journal.admit(call: call, semantics: semantics, key: key, at: Date()) {
        case .storageUnavailable:
            PrivacyLog.toolGate(.operationJournalUnavailable, tool: name,
                                detail: PrivacyToken("operation-journal-unavailable"))
            return .failedBeforeExecution(
                reason: "'\(name)' was not run because its safety record could not be saved. "
                    + "Unlock storage or try again after restarting; no action was taken.")

        case .duplicate(let existing):
            let advice = OperationRetryPolicy.advice(for: existing, semantics: semantics)
            PrivacyLog.toolGate(.alreadyJournaled, tool: name,
                                detail: PrivacyToken(existing.state.rawValue
                                                     + (advice.allowsAutomaticRetry ? "-repeatable" : "-needsReconcile")))
            return journal.replayOutcome(for: existing)

        case .proceed(let record):
            let sink = journalSink(operationID: record.operationID)
            return await resourceSerializer.withResource(name) {
                await executeWithTimeout(name: name, semantics: semantics,
                                         operationID: record.operationID,
                                         reportProgress: reportProgress,
                                         journalSink: sink) { try await work(key) }
            }
        }
    }

    /// Writes an operation's fate to the journal at the moment it is decided — including when it is
    /// decided *after* the router stopped waiting, which is the whole reason the sink exists rather
    /// than a return-value update: by then nobody is awaiting anything to update.
    private func journalSink(operationID: String) -> (ToolExecutionOutcome) -> Void {
        { [weak self] outcome in
            guard let self else { return }
            let resolution = self.operationJournal.resolve(operationID: operationID,
                                                           outcome: outcome, at: Date())
            switch resolution {
            case .recorded(let record):
                self.onOperationStatusChange?(record)
            case .late(let record):
                PrivacyLog.toolRun(.resolvedLate, tool: record.toolName,
                                   detail: PrivacyToken(record.state.rawValue))
                self.onOperationStatusChange?(record)
            case .unknownOperation:
                break
            }
        }
    }

    /// Ask tools that can answer what became of operations a previous process left in flight.
    ///
    /// Records nothing can answer for stay `unknown` — that is the honest state, and converting them
    /// to failures is exactly the lie this phase exists to stop.
    @discardableResult
    func reconcileRecoveredOperations(at now: Date = Date()) async -> Int {
        var settled = 0
        for record in operationJournal.recoveredOperations {
            guard let reconciler = registry.tool(named: record.toolName) as? OperationReconciling,
                  let outcome = await reconciler.reconcile(operationID: record.operationID,
                                                           idempotencyKey: record.idempotencyKey)
            else { continue }
            operationJournal.resolve(operationID: record.operationID, outcome: outcome, at: now)
            settled += 1
        }
        if settled > 0 {
            PrivacyLog.toolRun(.reconciled, count: settled)
        }
        return settled
    }

    static func cancelledBeforeDispatch(_ tool: String) -> String {
        "'\(tool)' was cancelled before it ran, so it had no effect."
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
                                    journalSink: ((ToolExecutionOutcome) -> Void)? = nil,
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
                PrivacyLog.toolRun(.stillRunning, tool: name, seconds: Double(elapsed))
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
                // Both branches journal, and both journal *here*, at the instant the fate is
                // decided. The late branch is the one that could not be done by returning a value:
                // nobody is awaiting this call any more, so the record is the only place the truth
                // can still land.
                if claim() {
                    journalSink?(finished)
                    continuation.resume(returning: finished)
                } else {
                    PrivacyLog.toolRun(.lateCompletion, tool: name)
                    journalSink?(finished)
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard claim() else { return }
                // Asking a tool that never checks for cancellation to stop tells the caller nothing
                // and hides that the work is still in flight; only ask when it can answer.
                if semantics.cancellation.respondsToCancellation { workTask.cancel() }
                let seconds = Int(timeoutSeconds)
                let timedOut: ToolExecutionOutcome = semantics.timeoutIsAuthoritative
                    ? .failedBeforeExecution(
                        reason: ToolExecutionOutcome.timedOutRead(tool: name, seconds: seconds))
                    : .outcomeUnknown(
                        operationID: operationID,
                        message: ToolExecutionOutcome.timedOutUnknown(tool: name, seconds: seconds))
                journalSink?(timedOut)
                continuation.resume(returning: timedOut)
            }
        }

        stillWorkingTask.cancel()

        let duration = Date().timeIntervalSince(startTime)
        switch outcome {
        case .completed(let text):
            // A tool result describes the wearer's world back to them — a message body, a
            // health reading, a home entity's state. Length only.
            PrivacyLog.toolRun(.succeeded, tool: name, seconds: duration, characters: text.count)
        case .outcomeUnknown:
            // Not a failure and not a success: the effect may still be in flight. Nothing is fed to
            // the skill-gap signal, and nothing may retry it automatically.
            PrivacyLog.toolRun(.outcomeUnknown, tool: name, seconds: duration,
                               detail: PrivacyToken(semantics.effect.rawValue + "-"
                                                    + semantics.cancellation.rawValue))
        case .rejected(let reason), .failedBeforeExecution(let reason):
            PrivacyLog.toolRun(.failed, tool: name, seconds: duration,
                               characters: reason.count)
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
