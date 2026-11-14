import Foundation

/// What a hop between models may do once a tool has run in the turn (Plan KL P2, decision 5).
///
/// `ModelCascade.run` restarts every attempt from the pre-turn history. Before this, a hop after
/// a tool had run either ended the turn (the two overflow paths, which knew a tool had run) or
/// started it again from nothing on the next model (every other failure class). In the build 615
/// report Apple Intelligence ran three tools successfully, failed, and the next model began the
/// turn without any of their results. Starting again from nothing can also repeat a tool that
/// changed something: a second note, a second message.
///
/// One rule now decides, for every failure that would hop:
///
/// - **Nothing ran:** the next model starts the turn from the beginning, as before.
/// - **Only read-only tools ran:** the next model starts from the pre-turn history too, with the
///   results it would otherwise fetch again given to it as already fetched (`AttemptToolLedger`).
/// - **Any tool may have changed something:** the turn ends, and says what ran and that it was not
///   run again. An unclassified tool counts as a change (`ToolExecutionSemantics.conservativeDefault`).
/// - **The request overflowed a window after a tool ran:** the turn ends, as it always has. The
///   results are the bulk that did not fit, and the chain's next model is not known to have a
///   bigger window, so carrying them would only meet the same wall.
///
/// Pure: the ledger's summary and whether the error is an overflow go in.
enum HopAfterTools {

    /// What the tools that ran this turn did to the world, as far as the app can tell.
    enum ToolsRan: String, Equatable, Sendable {
        /// No tool ran, or every call was refused or never reached.
        case none
        /// Every tool that ran is declared read-only.
        case readOnly
        /// At least one tool that ran may have written, sent or actuated something — including one
        /// that declares nothing about itself.
        case changedState
    }

    enum Decision: String, Equatable, Sendable {
        /// Hop and start the turn from the beginning.
        case restart
        /// Hop, starting from the pre-turn history plus the read-only results already fetched.
        case carryForward
        /// Do not hop: the turn ends here.
        case endTurn
    }

    /// The rule. `overflow` is whether the failure is a window that would not hold the request.
    static func decide(toolsRan: ToolsRan, overflow: Bool) -> Decision {
        switch toolsRan {
        case .none: return .restart
        case .changedState: return .endTurn
        case .readOnly: return overflow ? .endTurn : .carryForward
        }
    }

    /// The chain's class for an overflow that knows only whether a tool had run in the attempt
    /// (`RequestContextBudget.CapacityError`, `LLMError.contextOverflow`). Something having run with
    /// its effect unknown reads as the worst case — which for an overflow ends the turn either way.
    static func overflowClass(toolsRan: Bool) -> ModelFallbackChain.FailureClass {
        decide(toolsRan: toolsRan ? .changedState : .none, overflow: true) == .endTurn
            ? .terminalForTurn : .retryOtherModel
    }

    /// Whether `error` says the request would not fit a window: checked before sending
    /// (`CapacityError`), reported by the model (`contextOverflow`), or a provider's own overflow.
    static func isOverflow(_ error: Error) -> Bool {
        if error is RequestContextBudget.CapacityError { return true }
        if case LLMError.contextOverflow = error { return true }
        return RequestContextBudget.isOverflow(error: error)
    }

    // MARK: - The turn ended

    /// Thrown in place of a hop when a tool that may have changed something had already run. The
    /// chain reads it as terminal for the turn; the spoken reason says what ran.
    struct TurnEnded: LocalizedError {
        /// The tools that may have changed something, as the wearer hears them, in the order they
        /// ran, each once.
        let tools: [String]
        /// What the attempt failed on, for the log and the report. The error itself is not kept.
        let underlying: SafeErrorSummary

        /// The reason half of the line, framed by `ModelSwitchNarrator.exhaustionPhrase`.
        var reason: String {
            let pronoun = tools.count == 1 ? "it" : "them"
            return "\(HopAfterTools.spokenList(tools)) had already run, so I didn't run \(pronoun) again on another model"
        }

        var errorDescription: String? {
            "The answer stopped after \(HopAfterTools.spokenList(tools)) had run, so it wasn't run again on another model."
        }
    }

    /// How a tool is named aloud. A native tool's id with its underscores spoken as spaces
    /// ("save_note" → "save note"); anything else — an MCP server's tool, the gateway — is not this
    /// app's to name, so it is "a connected tool".
    static func spokenToolName(_ name: String, isNative: Bool) -> String {
        guard isNative else { return "a connected tool" }
        let spoken = name.split(separator: "_").joined(separator: " ")
        return spoken.isEmpty ? "a tool" : spoken
    }

    /// "save note", "save note and set timer", "save note, set timer and 2 other tools".
    static func spokenList(_ names: [String]) -> String {
        switch names.count {
        case 0: return "a tool"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) other tools"
        }
    }

    // MARK: - Bounds

    /// The most the carried block may add to a cloud model's instructions, in characters.
    static let cloudBlockLimit = 8_000
    /// …and to an on-device model's, whose whole window is a few thousand tokens.
    static let onDeviceBlockLimit = 2_400
    /// A result is kept at capture up to the larger bound; the block cuts it further.
    static let capturedResultLimit = cloudBlockLimit
    /// Arguments are kept up to this many characters.
    static let capturedArgumentsLimit = 600
}

/// The tools one turn has run, across its attempts, and what each did (Plan KL P2).
///
/// Every model tool call is entered when it is dispatched — by the shared dispatcher every cloud
/// provider's tool loop uses, by the on-device Apple tool runner and by the MLX model's single
/// call — with the effect its tool declares (`NativeTool.executionSemantics.effect`). The entry
/// counts as having run from that moment: only an outcome the router gives authoritatively as
/// "nothing happened" (refused, never reached) takes that back. A call whose attempt failed while
/// it ran therefore counts, and so does an unresolved outcome.
///
/// The entries hold the tool name, the arguments and the result, because a carried block has to
/// say all three. They are model-request material only: nothing here is logged.
struct AttemptToolLedger: Equatable {

    struct Call: Equatable {
        /// Unique for the life of the ledger, across resets, so a call still in flight when a
        /// turn ends can never land on the next turn's entry.
        let id: Int
        let tool: String
        /// The arguments as canonical JSON, bounded.
        let arguments: String
        let effect: ToolEffect
        /// False only when the outcome said nothing ran.
        var ran = true
        /// The tool's output when it completed; nil while it runs and for any other outcome.
        var result: String?
        /// Plan LA: a tool this app ships (the registry holds it), not an MCP server's or the
        /// gateway's. Only a native tool can vouch for what it did.
        var isNative = false
        /// Plan LA: how the call ended, by class; `.running` until it finishes.
        var outcome: QuietTurnCall.Outcome = .running
        /// Plan LA: what the tool reported about the request landing (`ActionCompletionReport`).
        var completion: ActionCompletion?

        /// The call as the quiet-ending judge reads it.
        var quietCall: QuietTurnCall {
            QuietTurnCall(tool: tool, effect: effect, outcome: outcome, completion: completion,
                          isNative: isNative)
        }
    }

    private(set) var calls: [Call] = []
    private var nextID = 0
    /// Plan LA: how many times the ledger has been reset. A turn that reads the ledger compares it
    /// with the count when the turn began: unchanged, the calls are an earlier turn's (a brain that
    /// keeps no ledger answered), and nothing may be concluded from them.
    private(set) var generation = 0

    /// Forget the calls — a new turn. Ids keep counting.
    mutating func reset() {
        calls.removeAll()
        generation += 1
    }

    /// Enter a call as it is dispatched; returns its id for `finished(_:outcome:)`.
    @discardableResult
    mutating func dispatched(tool: String, arguments: String, effect: ToolEffect,
                             isNative: Bool = false) -> Int {
        nextID += 1
        var call = Call(id: nextID, tool: tool,
                        arguments: String(arguments.prefix(HopAfterTools.capturedArgumentsLimit)),
                        effect: effect)
        call.isNative = isNative
        calls.append(call)
        return nextID
    }

    /// Record how a call ended. A completed call keeps its result; a refusal or a call that was
    /// never reached did not run; an unresolved outcome may have landed, and has no result to carry.
    mutating func finished(_ id: Int, outcome: ToolExecutionOutcome, completion: ActionCompletion? = nil) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        calls[index].outcome = QuietTurnCall.Outcome(outcome)
        // A report only stands for a call that completed: a timed-out or refused call's tool may
        // have said "done" about work nobody waited for.
        calls[index].completion = outcome.isCompleted ? completion : nil
        switch outcome {
        case .completed(let text):
            calls[index].result = String(text.prefix(HopAfterTools.capturedResultLimit))
        case .rejected, .failedBeforeExecution:
            calls[index].ran = false
        case .outcomeUnknown:
            break
        }
    }

    /// The calls that ran, or may have.
    var ran: [Call] { calls.filter(\.ran) }

    /// Plan LA: every call of the turn, refused ones included, as the quiet-ending judge reads
    /// them; `from` skips the calls an earlier round already accounted for.
    func quietCalls(from start: Int = 0) -> [QuietTurnCall] {
        guard start < calls.count else { return [] }
        return calls[max(0, start)...].map(\.quietCall)
    }

    /// Plan LN §3: whether a tool whose output is untrusted ran, or may have, this turn — the web,
    /// OCR, translation, captions, mail, an MCP server, the gateway
    /// (`PromptInjectionPolicy.isUntrustedOutput`). An inferred memory from such a turn is not
    /// kept: what the page or the sign said is not something the wearer told us.
    var readUntrustedOutput: Bool {
        ran.contains { PromptInjectionPolicy.isUntrustedOutput(toolName: $0.tool, isKnownNativeTool: $0.isNative) }
    }

    /// Plan LT §2: the calls as the private-span rule reads them — the tool, whether it is ours,
    /// and its captured result. The results are the ledger's own strings, not copies.
    var privateSpanReads: [PrivateSpanCheck.Read] {
        ran.map { PrivateSpanCheck.Read(tool: $0.tool, isNative: $0.isNative, result: $0.result) }
    }

    /// Plan LT §2: an untrusted tool whose content came from outside the wearer ran this turn —
    /// `readUntrustedOutput` without our own stores, so a memory lookup alone never counts.
    var readExternalUntrusted: Bool { PrivateSpanCheck.readExternalUntrusted(privateSpanReads) }

    /// Plan LT §2: a tool marked private (`PrivateSpanCheck.privateOutputTools`) returned something
    /// this turn.
    var readPrivateOutput: Bool { !PrivateSpanCheck.privateOutputs(privateSpanReads).isEmpty }

    /// Plan LT §2: whether a call to `tool` is in flight in this ledger — entered at dispatch and
    /// not yet finished. The private-span rule is applied only to a call the ledger knows, so a
    /// tool call from a session that keeps no ledger is never judged against an earlier turn.
    func hasCallInFlight(tool: String?) -> Bool {
        calls.contains { $0.ran && $0.outcome == .running && (tool == nil || $0.tool == tool) }
    }

    var toolsRan: HopAfterTools.ToolsRan {
        let ran = self.ran
        if ran.isEmpty { return .none }
        return ran.allSatisfy { $0.effect == .readOnly } ? .readOnly : .changedState
    }

    /// The tools that ran and may have changed something, each once, in the order they first ran.
    var changingTools: [String] {
        var seen = Set<String>()
        return ran.filter { $0.effect != .readOnly }.map(\.tool).filter { seen.insert($0).inserted }
    }

    /// The tools that ran, each once, with whether each is read-only — for the log.
    var ranTools: [(tool: String, effect: ToolEffect)] {
        var seen = Set<String>()
        return ran.filter { seen.insert($0.tool).inserted }.map { ($0.tool, $0.effect) }
    }

    // MARK: - The carried block

    struct CarriedBlock: Equatable {
        let text: String
        /// Results in the block, cut ones included.
        let carried: Int
        /// Results cut short to fit.
        let cut: Int
        /// Results left out for room; the model may fetch those again.
        let omitted: Int
    }

    /// The already-fetched block for the next model: every completed read-only call, the latest
    /// of identical calls, as tool name, arguments and result, within `limit` characters (a closing
    /// line naming how many were left out may follow). Nil when
    /// there is nothing to carry, or when anything that ran may have changed something — the
    /// turn does not hop then, and nothing should suggest otherwise.
    ///
    /// `wrap` is applied to each result as the tool loop applies it to a tool message
    /// (`PromptInjectionPolicy`'s envelope for untrusted output), so a result is never more
    /// trusted in the block than it was in the turn. A result is cut before it is wrapped, so the
    /// envelope always closes. `excluding` names tools whose output is not worth carrying
    /// (`lookup_tools`: the next model has its own definitions).
    func carriedBlock(limit: Int, excluding: Set<String> = [],
                      wrap: (_ tool: String, _ content: String) -> String = { $1 }) -> CarriedBlock? {
        guard toolsRan == .readOnly else { return nil }
        // The latest result of each identical call, in the order the calls first ran.
        var latest: [String: Call] = [:]
        var order: [String] = []
        for call in calls where call.ran && call.result != nil && !excluding.contains(call.tool) {
            let key = call.tool + "\u{0}" + call.arguments
            if latest[key] == nil { order.append(key) }
            latest[key] = call
        }
        let entries = order.compactMap { latest[$0] }
        guard !entries.isEmpty else { return nil }

        var text = Self.header
        var carried = 0, cut = 0
        let marker = " [cut short to fit; call the tool again only for what is missing]"
        let minimumResult = 200
        for (index, call) in entries.enumerated() {
            let prefix = "\n- \(call.tool) \(call.arguments): "
            let result = call.result ?? ""
            let whole = prefix + wrap(call.tool, result)
            if text.count + whole.count <= limit {
                text += whole
                carried += 1
                continue
            }
            // Cut the last one that fits at all, then stop: the rest are left to be fetched again.
            let envelope = wrap(call.tool, "").count
            let room = limit - text.count - prefix.count - envelope - marker.count
            if room >= minimumResult {
                text += prefix + wrap(call.tool, String(result.prefix(room)) + marker)
                carried += 1
                cut += 1
            }
            let omitted = entries.count - index - (room >= minimumResult ? 1 : 0)
            return carried == 0 ? nil : CarriedBlock(text: text + Self.omissionLine(omitted),
                                                     carried: carried, cut: cut, omitted: omitted)
        }
        return CarriedBlock(text: text, carried: carried, cut: cut, omitted: 0)
    }

    static let header = "Already fetched this turn: another model ran these tools for the user's current request and stopped before it answered. Use these results as they are and do not call these tools again with the same arguments."

    private static func omissionLine(_ omitted: Int) -> String {
        guard omitted > 0 else { return "" }
        return "\n(\(omitted) more \(omitted == 1 ? "result" : "results") did not fit here; call \(omitted == 1 ? "that tool" : "those tools") again if you need \(omitted == 1 ? "it" : "them").)"
    }

    // MARK: - Arguments

    /// Arguments as canonical JSON (sorted keys), the shape a model reads back most easily.
    static func canonicalArguments(_ args: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The same for arguments that arrived as a JSON string (the on-device runner's); a string
    /// that is not an object is kept as it came.
    static func canonicalArguments(json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json.isEmpty ? "{}" : json
        }
        return canonicalArguments(object)
    }
}
