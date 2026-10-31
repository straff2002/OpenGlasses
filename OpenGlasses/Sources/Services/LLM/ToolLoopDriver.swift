import Foundation

// MARK: - Provider-neutral tool-loop primitives (Plan BG P3)
//
// The Anthropic, OpenAI-compatible, and Gemini send paths were four near-identical copies of the
// same tool-execution loop — request → parse → dispatch tools → append results → repeat until the
// model stops calling tools or the iteration cap is hit. Every tool-loop fix (Plan BF history
// hygiene, yield-to-human, malformed-arg handling) had to be made in each copy. This file holds the
// single shared loop (`runToolLoop`) and the single shared tool-dispatch step (`ToolDispatcher`);
// each provider now supplies only its wire-format translation via a `ProviderLoopAdapter`.

/// A tool call the model requested, normalised across providers.
struct ToolInvocation {
    /// Anthropic `tool_use.id` / OpenAI `tool_call.id`. Gemini is name-keyed, so `nil` there.
    let id: String?
    let name: String
    /// Parsed arguments. `nil` means the arguments failed to parse — the dispatcher returns a
    /// correctable parse error instead of executing the tool (preserves the OpenAI-path behaviour).
    let arguments: [String: Any]?
    /// The original argument string, when the provider delivered one (OpenAI). Used for the
    /// OpenClaw bridge fallback (`task`) and error messages.
    let rawArguments: String?
    /// An id the provider wants echoed back with the result and nothing more: Gemini's
    /// `functionCall.id`, which its `functionResponse` repeats. Kept apart from `id` on purpose.
    /// `id` is what the operation journal keys at-most-once execution off, and nothing has shown
    /// that a Gemini id never repeats across calls.
    let responseID: String?

    init(id: String?, name: String, arguments: [String: Any]?, rawArguments: String? = nil,
         responseID: String? = nil) {
        self.responseID = responseID
        self.id = id
        self.name = name
        self.arguments = arguments
        self.rawArguments = rawArguments
    }
}

/// One model turn as the driver sees it.
struct AssistantTurn {
    /// Concatenated text blocks (the final answer when `toolCalls` is empty).
    let text: String
    /// The tool calls the model requested this turn — empty means it produced a final answer.
    let toolCalls: [ToolInvocation]
    /// Opaque provider payload (Anthropic content blocks / OpenAI message dict / Gemini parts) that
    /// the adapter appends to history verbatim. The driver never inspects it.
    let payload: Any?

    init(text: String, toolCalls: [ToolInvocation] = [], payload: Any? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.payload = payload
    }
}

/// The result of dispatching one tool call.
struct ToolDispatchOutcome {
    let invocation: ToolInvocation
    /// What the authority decided, typed. The wire text is the same string it always was, but the
    /// driver and its callers can now read the retry disposition instead of inferring it from prose.
    let outcome: ToolExecutionOutcome
    /// Non-nil when this was a successful `yield_to_human` — the loop returns this to hand control
    /// back to the user.
    let yieldReason: String?

    /// The provider wire shape the adapters append to history.
    var result: ToolResult { outcome.toolResult }
    /// Whether anything may repeat this call. `unsafeToRetry` means the effect may already have
    /// landed even though nothing confirmed it.
    var retryDisposition: ToolRetryDisposition { outcome.retryDisposition }
}

/// Runs a single tool call: parses guard, executes via the injected executor, tracks status, and
/// detects `yield_to_human`. Provider-neutral and free of `LLMService`, so it is unit-testable with
/// a mock executor.
struct ToolDispatcher {
    /// Executes a well-formed native/gateway tool call. `rawArguments` is the original arg string
    /// (OpenAI) for the bridge `task` fallback. `callID` is the provider's own id for this call —
    /// the identity a redelivery repeats, and what the operation journal keys at-most-once
    /// execution off; nil where the provider is name-keyed (Gemini) and no such identity exists.
    let execute: (_ name: String, _ args: [String: Any], _ rawArguments: String?,
                  _ callID: String?) async -> ToolExecutionOutcome
    /// Reports status transitions (executing → completed/failed/unknown) to the UI.
    let onStatus: (ToolCallStatus) -> Void

    func dispatch(_ invocation: ToolInvocation) async -> ToolDispatchOutcome {
        onStatus(.executing(invocation.name))
        let outcome: ToolExecutionOutcome
        if let args = invocation.arguments {
            outcome = await execute(invocation.name, args, invocation.rawArguments, invocation.id)
        } else {
            // Malformed arguments never reached a tool, so this is authoritative.
            outcome = .failedBeforeExecution(reason: "Could not parse the arguments for '\(invocation.name)' as JSON. Re-issue the call with valid JSON arguments.")
        }
        switch outcome {
        case .completed:
            onStatus(.completed(invocation.name))
        case .outcomeUnknown:
            // Neither done nor failed — the user is told we're still finding out rather than being
            // told something didn't happen when it may well have.
            onStatus(.outcomeUnknown(invocation.name))
        case .rejected, .failedBeforeExecution:
            onStatus(.failed(invocation.name, "Failed"))
        }
        return ToolDispatchOutcome(
            invocation: invocation,
            outcome: outcome,
            yieldReason: Self.yieldReason(name: invocation.name, result: outcome.toolResult)
        )
    }

    /// Identifies one call for the purpose of "this exact thing was already attempted". Name plus a
    /// digest of the arguments, so a *different* call to the same tool is unaffected.
    static func signature(of invocation: ToolInvocation) -> String {
        "\(invocation.name)#\(ToolCallBreaker.argsKey(invocation.arguments ?? [:]))"
    }

    /// What the model is told when it re-issues a call whose first attempt is still unresolved.
    static func repeatOfUnresolvedCall(_ name: String) -> String {
        "'\(name)' was already attempted with these arguments and may still be in progress, so it "
            + "was not run a second time. Do not call it again. Tell the user you're checking "
            + "whether the first attempt went through."
    }

    /// What the model is told about a call it made in the same turn as a `yield_to_human` that
    /// came first. Nothing ran, so it is free to ask again once the user has answered.
    static func notRunAfterYield(_ name: String) -> String {
        "'\(name)' was not run: control went back to the user first. Nothing happened. Call it "
            + "again if it is still needed once the user has answered."
    }

    /// A successful `yield_to_human` result carries `YIELD_TO_HUMAN: <reason>` — extract the reason
    /// so the loop can break and speak it. Returns `nil` for every other call.
    static func yieldReason(name: String, result: ToolResult) -> String? {
        guard name == "yield_to_human",
              case .success(let text) = result,
              text.hasPrefix("YIELD_TO_HUMAN:") else { return nil }
        return text
            .replacingOccurrences(of: "YIELD_TO_HUMAN: ", with: "")
            .replacingOccurrences(of: "\nWaiting for you to say \"done\" or \"continue\" when ready.", with: "")
    }
}

/// Per-provider wire-format translation the shared loop drives. Everything here is closures so an
/// adapter can capture the live `LLMService` (history, config, streaming helpers) without moving
/// that state into new types — while the loop itself stays provider-neutral and testable.
struct ProviderLoopAdapter {
    /// Provider name for error messages (e.g. "Anthropic").
    let label: String
    /// Shared dispatcher (built once per send with the provider's executor).
    let dispatcher: ToolDispatcher
    /// Perform one request against the current history and parse the model's turn.
    let performTurn: () async throws -> AssistantTurn
    /// Append the assistant's tool-calling message to history (provider wire shape).
    let appendAssistantToolCall: (AssistantTurn) -> Void
    /// Append the results of this iteration's tool calls to history. Anthropic/OpenAI append one
    /// message per result; Gemini batches them into a single `function` message.
    let appendToolResults: ([ToolDispatchOutcome]) -> Void
    /// Append the final assistant text to history and return it. Throwing on an empty reply is how
    /// a provider sends the turn to the next model in the cascade; one that does not throw keeps the
    /// empty reply, and `asksAgainWhenSilent` is for those.
    let finalize: (AssistantTurn) throws -> String
    /// Append a note from the app as a user message, for the one re-ask the loop makes when the
    /// model stalls after a tool has answered (`StallReplyPolicy`). Nil means the loop cannot
    /// re-ask on this provider and speaks the stall as before.
    var appendUserNote: ((String) -> Void)? = nil
    /// The budget-spent wrap-up: the same history, sent with tools withheld (`tool_choice` none,
    /// or the provider's equivalent), so the model can only answer in words. Nil means the
    /// provider cannot withhold them, and the wrap-up is an ordinary `performTurn`.
    var performWrapUp: (() async throws -> AssistantTurn)? = nil
    /// Ask once more when a reply has no words in it, instead of finalizing it (`StallReplyPolicy`).
    /// Only for a provider whose `finalize` keeps an empty reply, where it would reach the speech
    /// layer as silence. Off where `finalize` throws: that throw hops to the next model at once, and
    /// on a degraded provider an extra request first is a wait the technician hears.
    var asksAgainWhenSilent = false
}

/// Whether the request being built is the loop's wrap-up, which offers the model no tool.
///
/// A flag rather than a second copy of each provider's request builder: the adapter's
/// `performTurn` reads it while it builds the body, and `ProviderLoopAdapter.withholdingTools(_:)`
/// raises it for the one request the wrap-up makes. The tools stay declared — a history holding
/// tool calls needs them on some providers — and only the choice is closed.
final class ToolWithholding: @unchecked Sendable {
    private(set) var active = false

    init() {}

    func during<T>(_ body: () async throws -> T) async rethrows -> T {
        active = true
        defer { active = false }
        return try await body()
    }
}

extension ProviderLoopAdapter {
    /// This adapter, with a wrap-up that runs `performTurn` while `flag` is raised.
    func withholdingTools(_ flag: ToolWithholding) -> ProviderLoopAdapter {
        var adapter = self
        let perform = performTurn
        adapter.performWrapUp = { try await flag.during { try await perform() } }
        return adapter
    }
}

/// The single shared tool-execution loop. Iterates up to `maxIterations`: performs a turn, and if
/// the model called tools, appends the assistant message, dispatches each call, appends the results,
/// and loops; otherwise finalises and returns the answer. Breaks early on `yield_to_human`.
///
/// `@MainActor` because it drives `LLMService`'s published `toolCallStatus` and history through the
/// adapter closures; it is still testable by passing a synthetic adapter with an in-memory history.
@MainActor
func runToolLoop(
    maxIterations: Int,
    adapter: ProviderLoopAdapter,
    repeatGuard: ToolRepeatGuard = ToolRepeatGuard(),
    setStatus: (ToolCallStatus) -> Void
) async throws -> String {
    // What this turn already knows and has not changed since (Plan KE P1).
    var repeatGuard = repeatGuard
    // Calls this turn whose outcome could not be established. The wire text tells the model not to
    // retry, but "don't retry" is exactly the instruction a model reasons its way around ("I'll
    // just check by doing it again"), so the loop enforces it rather than asking.
    var unresolvedCalls: Set<String> = []
    // Whether any tool has answered in this turn: only then can a reply that promises to look
    // something up be a stall rather than an honest opener.
    var toolsHaveAnswered = false
    // One re-ask per turn, whether the reply stalled or said nothing.
    var reasked = false
    // Every completed call this turn, by signature, with what it answered. A model doing its
    // bookkeeping can call the same thing four or five times and be told the same thing each
    // time, spending the whole budget on it and leaving nothing to say what was done.
    var completedResults: [String: String] = [:]
    // Signatures whose repeat came back with the same answer as the first time: the next one is
    // not run. A read may legitimately change between two calls, so the first repeat always runs.
    var settledSignatures: Set<String> = []
    var identicalRepeats = 0
    // Everything this turn answered, in order, for the words the turn ends in when the model has
    // none of its own (`ToolLoopBudget.spoken(from:)`).
    var turnOutcomes: [ToolDispatchOutcome] = []
    // The question a tool result ended the turn on (`ToolTurnEnd.afterReply`): the model puts it
    // into words with every tool withheld, and it is what is said if the model says nothing.
    var endedOnQuestion: String?

    rounds: for _ in 0..<maxIterations {
        try Task.checkCancellation()
        let turn = try await adapter.performTurn()

        if turn.toolCalls.isEmpty {
            // The results are in history and the model narrated an intention instead of reading
            // them ("Vou pesquisar… um momento"). Once, ask again with them still there; the
            // stalled reply itself is not kept, so nothing speaks it. A second stall is the
            // answer, as before.
            if toolsHaveAnswered, !reasked, let appendUserNote = adapter.appendUserNote,
               StallReplyPolicy.isStall(turn.text) {
                reasked = true
                PrivacyLog.model(.stallReplyReasked, characters: turn.text.count,
                                 detail: PrivacyToken(adapter.label))
                appendUserNote(StallReplyPolicy.nudge)
                continue
            }
            // No words at all, on a provider that would keep that as the answer. Asked once, like a
            // stall, and the empty reply is not kept. After that, what the tools answered is said,
            // if any did; a turn with nothing to say from ends as it did.
            if adapter.asksAgainWhenSilent,
               StallReplyPolicy.isSilent(turn.text, toolsRun: turnOutcomes.map(\.invocation.name)) {
                if !reasked, let appendUserNote = adapter.appendUserNote {
                    reasked = true
                    PrivacyLog.model(.silentReplyReasked, characters: turn.text.count,
                                     detail: PrivacyToken(adapter.label))
                    appendUserNote(StallReplyPolicy.silenceNudge)
                    continue
                }
                if toolsHaveAnswered {
                    setStatus(.idle)
                    return try adapter.finalize(AssistantTurn(text: ToolLoopBudget.spoken(from: turnOutcomes)))
                }
            }
            let text = try adapter.finalize(turn)
            setStatus(.idle)
            return text
        }

        adapter.appendAssistantToolCall(turn)

        // Plan CU P1: one round trip's execution, held apart from the model's own time. With 36+
        // native tools behind this loop, a turn that spent four seconds inside a HomeKit call
        // otherwise reports four seconds of model latency and we go and optimise the model. The
        // `defer` covers the yield-to-human return below as well as the normal exit.
        let toolsStartedAt = Date()
        defer { TurnRecorder.addToolTime(since: toolsStartedAt) }

        var outcomes: [ToolDispatchOutcome] = []
        for (index, call) in turn.toolCalls.enumerated() {
            let signature = ToolDispatcher.signature(of: call)
            guard !unresolvedCalls.contains(signature) else {
                outcomes.append(ToolDispatchOutcome(
                    invocation: call,
                    outcome: .rejected(reason: ToolDispatcher.repeatOfUnresolvedCall(call.name)),
                    yieldReason: nil))
                continue
            }

            // An answer that cannot have changed: told once, and a call made after being told
            // counts as a repeat, so the wrap-up below stays the backstop for a model that keeps
            // going, whatever it passes as arguments.
            let reading = repeatGuard.reading(of: call)
            if let reading, repeatGuard.isSettled(reading) {
                if repeatGuard.markTold(reading) { identicalRepeats += 1 }
                outcomes.append(ToolDispatchOutcome(
                    invocation: call,
                    outcome: .rejected(reason: ToolRepeatGuard.youHaveThis(call.name)),
                    yieldReason: nil))
                continue
            }

            if settledSignatures.contains(signature), let previous = completedResults[signature] {
                identicalRepeats += 1
                outcomes.append(ToolDispatchOutcome(
                    invocation: call,
                    outcome: .rejected(reason: ToolLoopBudget.alreadyAnswered(call.name, previous: previous)),
                    yieldReason: nil))
                continue
            }

            let outcome = await adapter.dispatcher.dispatch(call)
            if outcome.retryDisposition == .unsafeToRetry { unresolvedCalls.insert(signature) }
            repeatGuard.note(call, reading: reading, outcome: outcome.outcome)
            if case .completed(let text) = outcome.outcome {
                if completedResults[signature] == text {
                    identicalRepeats += 1
                    settledSignatures.insert(signature)
                }
                completedResults[signature] = text
            }
            outcomes.append(outcome)
            // A result that ends the turn (Plan KD P2): nothing after it in this round runs, and
            // no further round is offered.
            if case .completed(let text) = outcome.outcome,
               ToolTurnEnd.mayEndTurn(outcome.invocation.name), let end = ToolTurnEnd.parse(text) {
                for unrun in turn.toolCalls.dropFirst(index + 1) {
                    outcomes.append(ToolDispatchOutcome(
                        invocation: unrun,
                        outcome: .failedBeforeExecution(reason: ToolTurnEnd.notRun(unrun.name)),
                        yieldReason: nil))
                }
                adapter.appendToolResults(outcomes)
                turnOutcomes += outcomes
                switch end {
                case .saying(let words):
                    // Said and shown as the tool wrote them; the model is not asked to repeat them.
                    setStatus(.idle)
                    return try adapter.finalize(AssistantTurn(text: words))
                case .afterReply(let question):
                    endedOnQuestion = question
                    break rounds
                }
            }
            if let reason = outcome.yieldReason {
                // The turn ends here, but the assistant message already in history names every
                // call it made. Each one needs an answer or the next request is malformed: only
                // the Anthropic path repairs that afterwards, and the others are rejected outright.
                for unrun in turn.toolCalls.dropFirst(index + 1) {
                    outcomes.append(ToolDispatchOutcome(
                        invocation: unrun,
                        outcome: .failedBeforeExecution(reason: ToolDispatcher.notRunAfterYield(unrun.name)),
                        yieldReason: nil))
                }
                adapter.appendToolResults(outcomes)
                setStatus(.yielded(call.name))
                // The yield reason is written by the tool for the wearer to read — it names
                // whatever the model was about to do on their behalf.
                PrivacyLog.model(.yieldedToHuman, characters: reason.count,
                                 detail: PrivacyToken(call.name))
                return reason
            }
        }
        adapter.appendToolResults(outcomes)
        turnOutcomes += outcomes
        toolsHaveAnswered = true
        // The same call, the same answer, twice over: another round will only repeat it. Every
        // call of this round has its answer, so the history is whole; go straight to the words.
        if identicalRepeats >= ToolLoopBudget.repeatsBeforeWrapUp {
            PrivacyLog.model(.toolRepeatsStopped, count: identicalRepeats,
                             detail: PrivacyToken(adapter.label))
            break rounds
        }
    }

    // The budget is spent (or the model was repeating itself), but the tools already ran: a task
    // closed, a part was requested, a message went out. Throwing here reported the turn as a
    // server failure and threw away the only words that would have told the technician what had
    // just been done on their behalf. One more request puts it into words — with tools withheld
    // where the provider can, so the model cannot spend it on one more call; anything it still
    // asks to run is answered, not run.
    try Task.checkCancellation()
    let wrapUp: AssistantTurn
    if let performWrapUp = adapter.performWrapUp {
        do {
            wrapUp = try await performWrapUp()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A server that will not take a closed tool choice still gets asked the ordinary way:
            // the wrap-up exists to save the turn's words, not to add a way for it to fail.
            try Task.checkCancellation()
            wrapUp = try await adapter.performTurn()
        }
    } else {
        wrapUp = try await adapter.performTurn()
    }
    setStatus(.idle)
    let said = wrapUp.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if wrapUp.toolCalls.isEmpty, !said.isEmpty {
        return try adapter.finalize(wrapUp)
    }
    if !wrapUp.toolCalls.isEmpty {
        if endedOnQuestion == nil {
            PrivacyLog.model(.toolBudgetSpent, count: wrapUp.toolCalls.count,
                             detail: PrivacyToken(adapter.label))
        }
        adapter.appendAssistantToolCall(wrapUp)
        adapter.appendToolResults(wrapUp.toolCalls.map {
            ToolDispatchOutcome(invocation: $0,
                                outcome: .failedBeforeExecution(reason: endedOnQuestion == nil
                                    ? ToolLoopBudget.notRun($0.name) : ToolTurnEnd.notRun($0.name)),
                                yieldReason: nil)
        })
    }
    let fallback = endedOnQuestion ?? ToolLoopBudget.spoken(from: turnOutcomes)
    return try adapter.finalize(AssistantTurn(text: said.isEmpty ? fallback : said))
}

/// A tool result that ends the turn (Plan KD P2).
///
/// The partner's retest had a rule chain answered several steps at once: every question result
/// invited the next call, and the model filled it with the last thing the technician had said. A
/// question put to the technician has its answer in their next turn, so the result that puts it
/// ends this one — and a list the technician asked for is theirs to hear as the tool wrote it,
/// not paraphrased. The result carries its own marker line, worded as an instruction, so a live
/// session (which has no loop to stop) is told the same thing in words. Pure.
enum ToolTurnEnd: Equatable {
    /// The model puts the result into words with every tool withheld, and the turn ends there.
    /// `question` is what is said when the model says nothing.
    case afterReply(question: String)
    /// The turn ends on these words, said and shown exactly as the tool wrote them; the model is
    /// not asked again.
    case saying(String)

    /// The only tools whose results may end the turn. A marker line in anything else — a web page,
    /// a document, a gateway or MCP result — is text like any other: honouring it would let that
    /// content end the turn and have its own words said aloud without the model reading them.
    static let tools: Set<String> = ["rule_chain"]

    static func mayEndTurn(_ tool: String) -> Bool { tools.contains(tool) }

    /// Opens the line that ends the turn on a question; the question follows it.
    static let afterReplyPrefix = "End of turn — ask the technician this and stop; their answer comes in "
        + "their next turn, and no tool runs until then: "

    /// The line before words that are said word for word.
    static let sayingLine = "Say this to the technician word for word, and nothing else; the turn ends with it:"

    /// The line a result ends with to end the turn on `question`.
    static func afterReplyLine(asking question: String) -> String {
        afterReplyPrefix + question
    }

    /// A result that is `words`, said word for word and ending the turn. Whatever comes before the
    /// marker line in a result is for the model only.
    static func saying(_ words: String) -> String {
        sayingLine + "\n" + words
    }

    /// What `result` asks of the turn, or nil for a result that leaves it open.
    static func parse(_ result: String) -> ToolTurnEnd? {
        let lines = result.components(separatedBy: "\n")
        if let marker = lines.firstIndex(of: sayingLine) {
            let words = lines[(marker + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : .saying(words)
        }
        for line in lines where line.hasPrefix(afterReplyPrefix) {
            let question = String(line.dropFirst(afterReplyPrefix.count)).trimmingCharacters(in: .whitespaces)
            return question.isEmpty ? nil : .afterReply(question: question)
        }
        return nil
    }

    /// The model's answer to a call made after a result ended the turn. Nothing ran.
    static func notRun(_ name: String) -> String {
        "'\(name)' was not run: an earlier result ended this turn. Nothing happened. Call it again "
            + "in a later turn if it is still needed."
    }
}

/// The calls a turn cannot learn anything new from (Plan KE P1).
///
/// A job ran `equipment_lookup` and `field_session status` round after round, four calls and no
/// manual search, until the repeat stop ended it (build 581). Replayed, the model asks the same
/// thing in different words: `set_equipment` with the unit, then a free-text query opening with the
/// unit and the symptom. Same arguments would miss those, so what counts here is what a call could
/// change. Status changes only when something else does; a unit lookup that restates the unit
/// already active changes nothing however it is phrased; a fault code beside it, another model or a
/// correction is a real call and runs. The answer goes to every call, so the history stays whole.
///
/// Live sessions have no loop to guard; `ToolLoopBudget.repeatsBeforeWrapUp` stays the backstop.
struct ToolRepeatGuard {
    /// What a call answers, and whether it could change anything.
    struct Reading: Equatable {
        fileprivate let answer: Answer
        fileprivate let changes: Bool
    }

    fileprivate enum Answer: Hashable { case status, unit, query(String) }

    /// Whether a text names the active unit and nothing that could change it. A seam so a test
    /// states the unit; read when a call is made, because an earlier call may have just changed it.
    private let namesActiveUnit: @MainActor (String) -> Bool
    private var answered: Set<Answer> = []
    private var told: Set<Answer> = []

    init(namesActiveUnit: @escaping @MainActor (String) -> Bool = { FieldSessionService.shared.namesOnlyActiveUnit($0) }) {
        self.namesActiveUnit = namesActiveUnit
    }

    /// What the model is told instead of the call's answer. Nothing ran.
    static func youHaveThis(_ name: String) -> String {
        "'\(name)' was not run: you have this; search the manual for the symptom or answer."
    }

    /// Tools that read the manuals and change nothing a status or a unit lookup reports.
    private static let readsManuals: Set<String> = ["manual_lookup", "table_lookup", "manual_figure", "show_source"]

    /// The reading of a call about to be made, for the calls this guards.
    @MainActor func reading(of call: ToolInvocation) -> Reading? {
        guard let args = call.arguments else { return nil }
        if call.name == "field_session" {
            return Self.text("action", in: args)?.lowercased() == "status" ? Reading(answer: .status, changes: false) : nil
        }
        guard call.name == "equipment_lookup" else { return nil }
        // Each of these writes to the unit, or reads the camera, which sees what it sees now.
        let writes = args["clear_equipment"] as? Bool == true || args["use_camera"] as? Bool == true
            || ["serial", "field_name", "file"].contains { Self.text($0, in: args) != nil }
        guard !writes else { return nil }
        if let unit = Self.text("set_equipment", in: args) {
            return namesActiveUnit(unit) ? Reading(answer: .unit, changes: false) : nil
        }
        guard let query = Self.text("query", in: args) else { return nil }
        if namesActiveUnit(query) { return Reading(answer: .unit, changes: false) }
        return Reading(answer: .query(query.lowercased()), changes: !VaultModelIndex.modelLikeTokens(in: query).isEmpty)
    }

    /// Whether this turn already has what the call would answer, with nothing changed since.
    func isSettled(_ reading: Reading) -> Bool { answered.contains(reading.answer) }

    /// Records that the model has been told; true when it had been told before.
    mutating func markTold(_ reading: Reading) -> Bool { !told.insert(reading.answer).inserted }

    /// What a dispatched call leaves known, given its `reading` from before it ran. A call that may
    /// have changed something forgets everything first, because a status from before it is no
    /// longer the status. One refused or failed changed nothing and answered nothing; one whose
    /// outcome is unknown may have changed something.
    @MainActor mutating func note(_ call: ToolInvocation, reading: Reading?, outcome: ToolExecutionOutcome) {
        switch outcome {
        case .rejected, .failedBeforeExecution: return
        case .completed, .outcomeUnknown: break
        }
        if reading?.changes ?? !Self.readsManuals.contains(call.name) { answered = [] }
        guard case .completed = outcome else { return }
        if let reading { answered.insert(reading.answer) }
        // A lookup that has just recorded the unit has answered for it, however it was asked.
        if call.name == "equipment_lookup", let args = call.arguments,
           let said = Self.text("set_equipment", in: args) ?? Self.text("query", in: args), namesActiveUnit(said) {
            answered.insert(.unit)
        }
    }

    private static func text(_ key: String, in args: [String: Any]) -> String? {
        let value = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

/// What a turn says when it has used every tool round, or stopped repeating itself.
enum ToolLoopBudget {
    /// How many identical repeats a turn may make before the loop stops offering rounds: one is
    /// a model checking its work, two is a model stuck in its bookkeeping.
    static let repeatsBeforeWrapUp = 2

    /// The model's answer to a call made after the budget was spent. Nothing ran.
    static func notRun(_ name: String) -> String {
        "'\(name)' was not run: this turn has used all its tool calls. Nothing happened. Tell the "
            + "user what was done so far and ask before doing more."
    }

    /// The model's answer to a call it already made this turn and was told the same thing twice.
    /// Nothing ran; the earlier answer is repeated, so nothing is lost by not running it.
    static func alreadyAnswered(_ name: String, previous: String) -> String {
        "'\(name)' already ran this turn with the same input and gave the same answer: \(previous)\n"
            + "Do not call it again; say what was done."
    }

    /// Spoken when the wrap-up produced no words of its own and nothing this turn succeeded.
    static let spokenFallback = "I've done several steps on that and stopped there. "
        + "Ask me what was done, or tell me what to do next."

    /// The opening of the words built from the turn's own results.
    static let doneSoFarPrefix = "Done so far: "

    /// The ceiling on those words, so a wrap-up never reads out a page of tool output.
    static let summaryCharacterLimit = 240

    /// The words a turn ends in when the wrap-up produced none: the first sentence of each
    /// distinct successful result, in the order they came, after "Done so far: ". Only when
    /// nothing succeeded is it the canned sentence — which used to replace everything the tools
    /// had returned, so a technician who had just closed a task heard only that it had stopped.
    static func spoken(from outcomes: [ToolDispatchOutcome]) -> String {
        var seen: Set<String> = []
        var sentences: [String] = []
        for outcome in outcomes {
            guard case .completed(let text) = outcome.outcome,
                  let sentence = firstSentence(of: text),
                  seen.insert(sentence).inserted else { continue }
            sentences.append(sentence)
        }
        guard !sentences.isEmpty else { return spokenFallback }

        var summary = doneSoFarPrefix
        var used = 0
        for sentence in sentences {
            let candidate = used == 0 ? summary + sentence : summary + " " + sentence
            if used > 0, candidate.count > summaryCharacterLimit { break }
            summary = candidate
            used += 1
        }
        if summary.count > summaryCharacterLimit {
            // One sentence longer than the whole allowance: cut at a word, and show it was cut.
            let cut = summary.prefix(summaryCharacterLimit - 1)
            let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            summary = String(atWord) + "…"
        }
        return summary
    }

    /// A result's first sentence, ending in its own stop — or nil for one that is not prose: an
    /// empty result, a JSON document, or a photo's marker with nothing around it.
    static func firstSentence(of text: String) -> String? {
        let prose = ToolResultImage.extract(from: text).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = prose.first, first != "{", first != "[" else { return nil }
        let line = prose.split(whereSeparator: \.isNewline).first.map(String.init) ?? prose
        var sentence = line
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            sentence = String(line[..<line.index(after: end.lowerBound)])
        }
        sentence = sentence.trimmingCharacters(in: .whitespaces)
        guard !sentence.isEmpty else { return nil }
        if let last = sentence.last, !".!?…".contains(last) { sentence += "." }
        return sentence
    }
}
