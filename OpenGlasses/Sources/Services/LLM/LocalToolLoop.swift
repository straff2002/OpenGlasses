import Foundation

/// A bounded tool loop for the downloaded (MLX and GGUF) models that writes every call back into
/// the conversation (Plan MQ P0). Pure: the model and the tools are injected closures, so every
/// branch runs headlessly against a scripted model.
///
/// ### What it replaces
/// `LLMService.sendLocal` runs at most one tool, then puts the model's prose (or "Let me check that
/// for you.") in place of the call and hands the result back as a **user** message. The research
/// behind Plan MQ traced most small-model tool failures to exactly that: the model never sees its
/// own call in the history, so it calls again, or answers as if the result came from the person.
/// This driver keeps the call: each round appends the assistant's call (with an id) and a `tool`
/// message carrying the result, the tool's name and the same id, in the roles a chat template
/// expects. It is not wired into `sendLocal` yet; that is P1, behind a flag.
///
/// ### Bounds
/// - **Round cap** (`Configuration.roundCap`, 3 by the plan's decision 2): after that many calls,
///   one last generation runs with tools withheld and answers from the results gathered. Every
///   call one generation asks for runs, in order, each counted against the cap (Plan MQ P3: Gemma 4
///   E2B asks for a two-step turn's both calls at once); a call past the cap is counted, not run.
/// - **Repeats**: a call whose name and arguments match an earlier round's — compared as
///   `AttemptToolLedger.canonicalArguments`, so `{"a":1,"b":2}` and `{"b":2,"a":1}` are the same
///   call whatever order Swift's dictionary gives — ends the loop instead of running again.
/// - **Cancellation** is checked before every generation and every tool, and a `CancellationError`
///   from either closure propagates unwrapped, as a barge-in must.
///
/// ### Round 0's recovery
/// The "I'll check that" stall keeps its one corrective re-generation (`Configuration.correction`),
/// exactly where `sendLocal` runs it: on the first output, only when it is prose. The correction
/// exchange is the turn's own scaffolding and is not kept in the transcript.
///
/// ### Claims of work not done
/// On the phone Gemma 4 E2B often answered a "log it, then work out…" turn with "I have logged the
/// line voltage as 120 volts" and called nothing (Plan MQ P3). A reply that says an action was done
/// (`unbackedClaim(in:executed:)`) with no successful call of a tool that does it this turn gets the
/// turn's one correction while tools are still offered; a final reply that still claims it is
/// never spoken: the miss line is, and the turn ends `.unbackedClaim`.
///
/// ### Promises of work not done
/// After the correction Gemma 4 E2B still ended three of twelve two-step turns on the phone with a
/// promise ("I will calculate the voltage drop now.", "I will now call the domain_calc tool…") and
/// no call (Plan MQ P3). A reply that promises to act (`unbackedPromise(in:executed:)`) with no
/// successful call this turn of a tool that does what it promises gets the turn's one correction
/// while tools are still offered; a final reply that is still such a promise is never spoken: the
/// miss line is, and the turn ends `.unbackedPromise`, as `sendLocal` speaks it for an announced
/// intent. A promise a call that ran backs stays.
///
/// ### Routed calls
/// With `Configuration.routing` set, a turn `LocalTurnRouter` recognises (an error code, a model
/// number to identify, a procedure to start, a step of the running procedure, a job command, an
/// evidence choice, a reading's "and the other one?") has its call run through `execute` before
/// any generation, so the dispatcher's offer check, coercion and approval gates still decide. A
/// lookup's, job command's, evidence choice's or reading's result then goes to the model as round
/// 1; a procedure's result is
/// said as the runner wrote it, with no generation, unless it is an error or needs the model's next
/// call.
/// Without routing the loop is as it was.
///
/// ### Numbers nobody said
/// A model-made call loses every plain-number argument the conversation does not hold
/// (`LocalArgumentGrounding`): Gemma 4 E2B made up conductor figures for a voltage drop the tool
/// would have worked out from (Plan MQ P3). The call runs without them; the model reads which were
/// not used after the result, and the outcome counts them (`argumentsDropped`).
///
/// ### What the technician said, filled in
/// After that filter, a model-made call gets what the conversation said and the call left off
/// (`LocalArgumentCompletion`): Gemma 4 E2B never sends a voltage drop's `wire_awg`, so "14 gauge
/// copper" became a refusal and a question about resistance. Here rather than in the dispatcher's
/// coercion because the loop is the one step the app and the eval both run. The model reads what
/// was filled after the result; the outcome counts it (`argumentsCompleted`).
enum LocalToolLoop {

    // MARK: - Messages

    enum Role: String, Equatable, Sendable {
        case user, assistant, tool
    }

    /// One call the model asked for, with the id that pairs it with its result.
    struct Call {
        let id: String
        let name: String
        let arguments: [String: Any]
        /// `AttemptToolLedger.canonicalArguments(arguments)`: sorted keys, so equal calls compare
        /// equal whatever order the arguments arrived in.
        let canonicalArguments: String
        /// True when the call arrived inside a `<think>` block and was taken from there.
        let fromReasoning: Bool

        init(id: String, name: String, arguments: [String: Any], fromReasoning: Bool = false) {
            self.id = id
            self.name = name
            self.arguments = arguments
            self.canonicalArguments = AttemptToolLedger.canonicalArguments(arguments)
            self.fromReasoning = fromReasoning
        }

        /// Name and canonical arguments: what makes two calls the same call.
        var signature: String { name + "\u{1F}" + canonicalArguments }
    }

    /// One history entry, in the roles a chat template renders. An assistant message may carry a
    /// call; a `tool` message carries a result with the call's id and the tool's name.
    struct Message: Equatable {
        let role: Role
        let content: String
        var toolCallID: String?
        var toolName: String?
        /// For an assistant message that made a call: the call's canonical arguments.
        var toolArguments: String?

        static func user(_ text: String) -> Message { Message(role: .user, content: text) }
        static func assistant(_ text: String) -> Message { Message(role: .assistant, content: text) }

        static func assistant(_ text: String, calling call: Call) -> Message {
            Message(role: .assistant, content: text, toolCallID: call.id, toolName: call.name,
                    toolArguments: call.canonicalArguments)
        }

        static func toolResult(_ text: String, for call: Call) -> Message {
            Message(role: .tool, content: text, toolCallID: call.id, toolName: call.name)
        }
    }

    // MARK: - Inputs

    /// Why a generation is being run, so the caller can render the prompt that fits.
    enum Purpose: String, Equatable, Sendable {
        /// The turn's first answer.
        case initial
        /// Round 0's recovery after an "I'll check" stall.
        case correction
        /// The answer after one or more tool results.
        case afterTools
        /// The last answer, with tools withheld: the round cap was reached, or a repeat ended the
        /// loop with nothing said.
        case final
    }

    struct GenerationRequest {
        let messages: [Message]
        /// False when the generation must answer without calling anything. The caller drops the
        /// tool definitions from the prompt; a call that still arrives is not executed.
        let toolsOffered: Bool
        let purpose: Purpose
        /// Tool rounds already run this turn.
        let round: Int
        /// Of those, the calls the router ran before the first generation: a scripted model plays
        /// its script from after them.
        var routedCalls: Int = 0
    }

    struct ExecutionResult: Equatable {
        let text: String
        let isError: Bool

        init(text: String, isError: Bool = false) {
            self.text = text
            self.isError = isError
        }
    }

    struct Configuration {
        /// The most tool rounds one turn may run (decision 2: 3).
        var roundCap: Int = defaultRoundCap
        /// Round 0's recovery: given the first output's prose and the turn, the correction to send,
        /// or nil when none is needed. Nil disables the recovery, and the later claim correction
        /// with it; a claim nothing backs is still never spoken.
        var correction: ((_ prose: String, _ turn: String) -> String?)? = { LocalToolLoop.standardCorrection(for: $0, turn: $1) }
        /// What the wearer hears when the model said nothing but protocol.
        var missText: String = LLMService.localMissMessage
        /// The assistant's own name, taken off the front of a reply that opens by addressing it
        /// (`withoutLeadingName`). Empty takes nothing off.
        var assistantName: String = Config.assistantName
        /// What `LocalTurnRouter` reads to run a call before the model. Nil: no routing.
        var routing: LocalTurnRouter.Context? = nil
        /// Text beside the conversation whose numbers a call may use (`LocalArgumentGrounding`):
        /// the job context the model reads in its prompt. The turn, the history and this turn's
        /// tool results are always grounding.
        var groundingText: [String] = []
        /// The conductor file `LocalArgumentCompletion` sizes a wire against, read only when a call
        /// needs it.
        var conductors: () -> ConductorTable? = { ConductorTableCatalog.table() }
    }

    static let defaultRoundCap = 3

    // MARK: - Outputs

    enum EndReason: String, Equatable, Sendable {
        /// The model answered in prose.
        case answered
        /// The model asked for a call it had already made; the loop stopped rather than run it again.
        case repeatedCall
        /// The round cap was reached and the last generation answered with tools withheld.
        case roundCap
        /// The model produced only protocol (or nothing usable); the miss line is spoken.
        case protocolOnly
        /// The model said nothing after a call that succeeded, so the call's own short result is
        /// spoken (`spokenResult(of:)`) rather than the miss line: Gemma 4 E2B on the phone
        /// logged the reading and then ended its turn in 24 of 38 calls (Plan MQ P3).
        case toolResult
        /// A routed procedure step's result was said as the runner wrote it; nothing was generated.
        case routedResult
        /// The last reply said an action was done that no call this turn did (`unbackedClaim`), so
        /// the miss line was spoken instead of it.
        case unbackedClaim
        /// The last reply promised an action no call this turn did (`unbackedPromise`), so the miss
        /// line was spoken instead of it.
        case unbackedPromise
    }

    /// A call the loop ran, with what came back. Arguments are kept in memory for the caller's
    /// ledger and are never logged.
    struct Executed {
        let call: Call
        let result: ExecutionResult
        /// Run by `LocalTurnRouter` before the model, not asked for by it.
        var routed = false
    }

    struct Outcome {
        /// What may be spoken and stored: protocol removed by `LocalOutputPolicy`, never empty.
        let text: String
        let endReason: EndReason
        /// The turn as the chat template should see it next time: the user message, each round's
        /// call and result, and the final answer.
        let transcript: [Message]
        let executed: [Executed]
        /// Generations run, the correction included.
        let generations: Int
        let usedCorrection: Bool
        /// Calls taken from inside a `<think>` block.
        let callsFromReasoning: Int
        /// Calls the model made that the loop did not run: a repeat, or a call after the cap.
        let callsNotRun: Int
        /// Generations that asked for more than one call (Plan MQ P3). A count only.
        var multiCallGenerations = 0
        /// Calls `LocalTurnRouter` ran before the model (0 or 1).
        var routedCalls = 0
        /// Arguments taken off model-made calls because nobody said their number
        /// (`LocalArgumentGrounding`). A count only.
        var argumentsDropped = 0
        /// Arguments set, replaced or taken off model-made calls from what the technician said
        /// (`LocalArgumentCompletion`). A count only.
        var argumentsCompleted = 0
    }

    // MARK: - Parsing

    /// One generation's output, read by the shipped policy, with a call inside `<think>` taken
    /// rather than dropped.
    struct Parsed {
        let classification: LocalOutputPolicy.Classification
        /// The usable calls, in order: the spoken part's when it has any, else those found in the
        /// reasoning.
        let invocations: [LocalOutputPolicy.Invocation]
        let fromReasoning: Bool
        /// The first usable call.
        var invocation: LocalOutputPolicy.Invocation? { invocations.first }
        /// Speakable text: protocol and reasoning removed.
        var text: String { classification.text }
    }

    /// Classify `raw` with `LocalOutputPolicy`. A `<think>` block is removed first, the way
    /// `LLMService` strips one (a close tag with no opening means the template opened it). When the
    /// spoken part holds no usable call but the reasoning does, that call is the one taken: Qwen3
    /// and Qwen3.5 are known to put a call inside `<think>` and stop.
    static func parse(_ raw: String) -> Parsed {
        let hasOpen = raw.contains("<think>")
        let hasClose = raw.contains("</think>")
        guard hasOpen || hasClose else {
            let classification = LocalOutputPolicy.classify(raw)
            return Parsed(classification: classification, invocations: classification.invocations,
                          fromReasoning: false)
        }
        let (spoken, reasoning) = ThinkStreamFilter.strip(raw, startsInThink: hasClose && !hasOpen)
        let classification = LocalOutputPolicy.classify(spoken)
        if classification.invocations.isEmpty, let reasoning {
            let inThought = LocalOutputPolicy.classify(reasoning).invocations
            if !inThought.isEmpty {
                return Parsed(classification: classification, invocations: inThought, fromReasoning: true)
            }
        }
        return Parsed(classification: classification, invocations: classification.invocations,
                      fromReasoning: false)
    }

    /// One generation's output: the raw text, and the calls the runtime's own parser took out of the
    /// stream (mlx-swift-lm's `.toolCall` events, Plan MQ P1). A text-only runtime returns none.
    struct Generation {
        let text: String
        let toolCalls: [LocalToolCallEvent]
        /// The runtime's report (Plan MQ P3): token counts, timings and the cap. Not read by the
        /// loop; the qualification graders read it for zero-token and cut replies.
        let stats: LocalGenerationStats?
        /// What the runtime sent of the offered tools (`LocalToolFit`): nil when it fitted nothing
        /// (a text-only runtime, a test double). A call to a tool the fit dropped was never
        /// declared to the model, so the dispatcher treats it as not offered.
        let toolFit: LocalToolFit.Report?

        init(text: String, toolCalls: [LocalToolCallEvent] = [], stats: LocalGenerationStats? = nil,
             toolFit: LocalToolFit.Report? = nil) {
            self.text = text
            self.toolCalls = toolCalls
            self.stats = stats
            self.toolFit = toolFit
        }
    }

    /// `parse(_:)` over the text, then, when the text holds no usable call, every call the runtime
    /// parsed, in order — the rule `LocalOutputPolicy.classify(_:parsedCalls:)` follows. A runtime
    /// parser consumes the frames it reads, so the two are not both present. Any protocol left in
    /// the text is still removed from what is spoken.
    static func parse(_ generation: Generation) -> Parsed {
        let parsed = parse(generation.text)
        guard parsed.invocations.isEmpty, !generation.toolCalls.isEmpty else { return parsed }
        return Parsed(classification: parsed.classification, invocations: generation.toolCalls.map(\.invocation),
                      fromReasoning: false)
    }

    // MARK: - The loop

    /// Run one turn over a text-only model: `run(history:userMessage:configuration:generateTurn:execute:)`
    /// with no parsed calls.
    static func run(history: [Message],
                    userMessage: String,
                    configuration: Configuration = Configuration(),
                    generate: (GenerationRequest) async throws -> String,
                    execute: (Call) async throws -> ExecutionResult) async throws -> Outcome {
        try await run(history: history, userMessage: userMessage, configuration: configuration,
                      generateTurn: { Generation(text: try await generate($0)) }, execute: execute)
    }

    /// Run one turn.
    ///
    /// - Parameters:
    ///   - history: earlier turns, in the template's roles.
    ///   - userMessage: what the wearer said.
    ///   - generate: one generation over the given messages; returns the raw output.
    ///   - execute: run one call; the result is what the model reads in the `tool` message.
    static func run(history: [Message],
                    userMessage: String,
                    configuration: Configuration = Configuration(),
                    generateTurn generate: (GenerationRequest) async throws -> Generation,
                    execute: (Call) async throws -> ExecutionResult) async throws -> Outcome {
        let cap = max(0, configuration.roundCap)
        var transcript = history + [.user(userMessage)]
        var executed: [Executed] = []
        var seen = Set<String>()
        var generations = 0
        var usedCorrection = false
        var fromReasoning = 0
        var notRun = 0
        var routed = 0
        var multiCall = 0
        var dropped = 0
        var completedArguments = 0
        // The turn first, then the earlier user messages, newest first.
        let completion = LocalArgumentCompletion.Context(
            userMessages: [userMessage] + history.filter { $0.role == .user }.reversed().map(\.content),
            conductors: configuration.conductors)
        // What a model-made call's numbers may come from; this turn's tool results join it as they
        // arrive. Not this turn's own replies: a figure the model wrote itself is not grounding.
        var grounding = LocalArgumentGrounding.Grounding(configuration.groundingText + history.map(\.content)
                                                         + [userMessage])

        func generation(_ purpose: Purpose, messages: [Message], toolsOffered: Bool) async throws -> Parsed {
            try Task.checkCancellation()
            generations += 1
            let raw = try await generate(GenerationRequest(messages: messages, toolsOffered: toolsOffered,
                                                           purpose: purpose, round: executed.count,
                                                           routedCalls: routed))
            try Task.checkCancellation()
            let parsed = parse(raw)
            if parsed.invocations.count > 1 { multiCall += 1 }
            return parsed
        }

        func finish(_ parsed: Parsed, _ reason: EndReason) -> Outcome {
            var reason = reason
            var text = LocalToolLoop.withoutLeadingName(parsed.text, name: configuration.assistantName)
            if text.isEmpty {
                // Only a turn that ended on its own with nothing at all said after the call: not one
                // that tried another call or wrote broken protocol, and not one the cap or a repeat
                // cut short, where the last result is not an answer to what was asked.
                if reason == .answered, parsed.invocation == nil, parsed.classification.kind == .prose,
                   let last = executed.last, let spoken = LocalToolLoop.spokenResult(of: last) {
                    text = spoken
                    reason = .toolResult
                } else {
                    text = configuration.missText
                    if reason == .answered { reason = .protocolOnly }
                }
            } else if LocalToolLoop.unbackedClaim(in: text, executed: executed,
                                                   assistantName: configuration.assistantName) != nil {
                // Never say it was done when nothing did it.
                text = configuration.missText
                reason = .unbackedClaim
            } else if LocalToolLoop.unbackedPromise(in: text, executed: executed,
                                                     assistantName: configuration.assistantName) {
                // Nor that it is about to be, when the turn is over and nothing did it.
                text = configuration.missText
                reason = .unbackedPromise
            }
            transcript.append(.assistant(text))
            var outcome = Outcome(text: text, endReason: reason, transcript: transcript, executed: executed,
                                  generations: generations, usedCorrection: usedCorrection,
                                  callsFromReasoning: fromReasoning, callsNotRun: notRun, routedCalls: routed)
            outcome.multiCallGenerations = multiCall
            outcome.argumentsDropped = dropped
            outcome.argumentsCompleted = completedArguments
            return outcome
        }

        // Routed calls run first, in order, through the same dispatcher a model's call goes through.
        // Each is completed from what the technician said, as a model's is: the router passes only
        // what it read, so a voltage drop it made gets its wire, metal and supply here.
        if cap > 0, let context = configuration.routing {
            for route in LocalTurnRouter.routes(turn: userMessage, history: history, context: context)
                where executed.count < cap {
                let completed = LocalArgumentCompletion.complete(name: route.tool, arguments: route.arguments,
                                                                 context: completion)
                let call = Call(id: "call_\(executed.count + 1)", name: route.tool, arguments: completed.arguments)
                try Task.checkCancellation()
                transcript.append(.assistant("", calling: call))
                let result = try await execute(call)
                try Task.checkCancellation()
                transcript.append(.toolResult(result.text, for: call))
                grounding.add(result.text)
                executed.append(Executed(call: call, result: result, routed: true))
                seen.insert(call.signature)
                routed += 1
                completedArguments += completed.changes
                if route.speech == .result, let spoken = LocalTurnRouter.spokenProcedureResult(result) {
                    transcript.append(.assistant(spoken))
                    return Outcome(text: spoken, endReason: .routedResult, transcript: transcript, executed: executed,
                                   generations: 0, usedCorrection: false, callsFromReasoning: 0, callsNotRun: 0,
                                   routedCalls: routed)
                }
            }
        }

        let atCapAlready = executed.count >= cap
        var parsed = try await generation(routed > 0 ? (atCapAlready ? .final : .afterTools) : .initial,
                                          messages: transcript, toolsOffered: cap > 0 && !atCapAlready)
        if routed > 0, atCapAlready {
            notRun += parsed.invocations.count
            return finish(parsed, .roundCap)
        }

        // An offer to do what the turn asked for ("I can calculate the voltage drop for you"), when
        // it claims nothing: a claim gets the claim correction below.
        func offerCorrection(_ prose: String) -> String? {
            guard LocalToolLoop.unbackedClaim(in: prose, executed: executed,
                                              assistantName: configuration.assistantName) == nil,
                  LocalToolLoop.offersInsteadOfDoing(prose, turn: userMessage,
                                                     assistantName: configuration.assistantName) else { return nil }
            return LLMService.localIntentCorrection
        }

        // Round 0's recovery: the stall `sendLocal` corrects today, corrected the same way, and a
        // turn that asked for an action answered with an offer to do it. Not after a routed call:
        // the call the stall promises has already run.
        if routed == 0, parsed.invocations.isEmpty, parsed.classification.kind == .prose, cap > 0,
           let correctionFor = configuration.correction,
           let correction = correctionFor(parsed.text, userMessage) ?? offerCorrection(parsed.text) {
            usedCorrection = true
            let scaffold = transcript + [.assistant(parsed.text), .user(correction)]
            parsed = try await generation(.correction, messages: scaffold, toolsOffered: true)
        }

        while true {
            let invocations = parsed.invocations
            guard !invocations.isEmpty else {
                // A reply that says it did, or is about to do, what no call did gets the turn's one
                // correction, while tools are still offered (`finish` never speaks it).
                if !usedCorrection, configuration.correction != nil, executed.count < cap,
                   parsed.classification.kind == .prose {
                    let name = configuration.assistantName
                    let correction = LocalToolLoop.unbackedClaim(in: parsed.text, executed: executed, assistantName: name) != nil
                        ? LLMService.localClaimCorrection
                        : LocalToolLoop.unbackedPromise(in: parsed.text, executed: executed, assistantName: name)
                            ? LLMService.localIntentCorrection : nil
                    if let correction {
                        usedCorrection = true
                        let scaffold = transcript + [.assistant(parsed.text), .user(correction)]
                        parsed = try await generation(.correction, messages: scaffold, toolsOffered: true)
                        continue
                    }
                }
                break
            }

            // Every call this generation asked for, in order, through the same dispatcher. The prose
            // beside them rides on the first that runs.
            var ran = 0
            for invocation in invocations {
                // What runs is the call less any number nobody said, with what the technician said
                // filled in; the repeat check compares that.
                let filtered = LocalArgumentGrounding.filter(invocation.arguments, grounding: grounding)
                let completed = LocalArgumentCompletion.complete(name: invocation.name, arguments: filtered.arguments,
                                                                 context: completion)
                let call = Call(id: "call_\(executed.count + 1)", name: invocation.name,
                                arguments: completed.arguments, fromReasoning: parsed.fromReasoning)
                // Past the cap: only reachable when the cap is 0, a model calls after tools were
                // withheld, or one generation asked for more calls than the cap has left.
                guard executed.count < cap else { notRun += 1; continue }
                // A reading whose value holds no number records nothing the technician measured
                // ("outside", "not applicable", from "Text the customer that I'm outside" and "Is it
                // going to rain later?" on the phone): not run, as a repeat is not, so the turn is
                // answered without it.
                guard !LocalToolLoop.isReadingWithoutNumber(call) else { notRun += 1; continue }
                guard seen.insert(call.signature).inserted else { notRun += 1; continue }

                if call.fromReasoning { fromReasoning += 1 }
                dropped += filtered.dropped.count
                completedArguments += completed.changes
                try Task.checkCancellation()
                transcript.append(.assistant(ran == 0 ? parsed.text : "", calling: call))
                let result = try await execute(call)
                try Task.checkCancellation()
                // The notes are the model's alone: `Executed` keeps the tool's own result, which is
                // what `spokenResult(of:)` may say. A number dropped where what was said governs is
                // told as replaced, not as one to ask for.
                let unsaid = filtered.dropped.filter { !completed.governs($0) }
                let filledNames = Set(completed.filled.map { $0.name })
                let notUsed = (completed.removed + filtered.dropped.filter { completed.governs($0) && !filledNames.contains($0) })
                    .sorted()
                let notes = [unsaid.isEmpty ? nil : LocalArgumentGrounding.modelNote(dropped: unsaid),
                             LocalArgumentCompletion.modelNote(filled: completed.filled, inferred: completed.inferred,
                                                               notUsed: notUsed)].compactMap { $0 }
                let forModel = ([result.text] + notes).joined(separator: "\n\n")
                transcript.append(.toolResult(forModel, for: call))
                grounding.add(result.text)
                executed.append(Executed(call: call, result: result))
                ran += 1
            }

            if ran == 0 {
                if executed.count >= cap { return finish(parsed, .roundCap) }
                // Nothing but repeats: whatever it said beside them stands; with nothing said,
                // answer from the results already gathered, tools withheld.
                if !parsed.text.isEmpty { return finish(parsed, .repeatedCall) }
                let final = try await generation(.final, messages: transcript, toolsOffered: false)
                notRun += final.invocations.count
                return finish(final, .repeatedCall)
            }

            let atCap = executed.count >= cap
            parsed = try await generation(atCap ? .final : .afterTools, messages: transcript,
                                          toolsOffered: !atCap)
            if atCap {
                notRun += parsed.invocations.count
                return finish(parsed, .roundCap)
            }
        }
        return finish(parsed, .answered)
    }

    /// Words that follow the assistant's name when a reply opens by naming itself ("Avenkin, I
    /// can…", "Avenkin here.", "avenkin I can…", "Avenkin understood.") rather than using it in
    /// a sentence ("Avenkin will log…", which is left alone).
    static let wordsAfterALeadingName: Set<String> = ["i", "yes", "sure", "ok", "okay", "right", "here", "understood"]

    /// `text` without the assistant's name at its front, when the reply opens by naming itself:
    /// the name followed by punctuation, by "here", or by a word in `wordsAfterALeadingName`. A
    /// reply that is only the name becomes empty. Gemma 4 E2B opened 132 of the full phone run's
    /// replies so, spoken as "Avenkin, I can look that up" (Plan MQ P3). Pure.
    static func withoutLeadingName(_ text: String, name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, trimmed.lowercased().hasPrefix(name.lowercased()) else { return text }
        var rest = Substring(trimmed.dropFirst(name.count))
        if let next = rest.first, next.isLetter || next.isNumber { return text }   // a longer word
        let punctuation: Set<Character> = [",", ".", ":", ";", "!", "\u{2014}", "\u{2013}", "-"]
        func dropSpaces() { rest = rest.drop(while: { $0.isWhitespace }) }
        dropSpaces()
        if rest.lowercased().hasPrefix("here"), !(rest.dropFirst(4).first?.isLetter ?? false) {
            rest = rest.dropFirst(4)
            dropSpaces()
            rest = rest.drop(while: { punctuation.contains($0) })
        } else if let first = rest.first, punctuation.contains(first) {
            rest = rest.drop(while: { punctuation.contains($0) })
        } else if !rest.isEmpty {
            let word = rest.prefix(while: { $0.isLetter }).lowercased()
            guard wordsAfterALeadingName.contains(word) else { return text }
        }
        dropSpaces()
        guard let first = rest.first else { return "" }
        return first.uppercased() + rest.dropFirst()
    }

    /// A `reading` record or correction whose `value` is there but holds no number, as digits or as a number
    /// word ("seven", "twelve point five"): the tool takes "the number alone", so a value like
    /// "outside" or "not applicable" is the model filling a slot, not a reading.
    static func isReadingWithoutNumber(_ call: Call) -> Bool {
        guard call.name == "reading" else { return false }
        let action = (call.arguments["action"] as? String)?.lowercased() ?? "record_reading"
        guard action == "record_reading" || action == "correct_reading" else { return false }
        // A missing or blank value is the tool's to ask about ("Say what was measured and the
        // value"), as when the grounding filter took off a number nobody said.
        guard let value = (call.arguments["value"] as? String)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, !value.contains(where: \.isNumber) else { return false }
        let words = value.lowercased().split(whereSeparator: { !$0.isLetter })
        return !words.contains { numberWords.contains(String($0)) }
    }

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "half", "quarter", "point",
    ]

    /// The longest tool result `spokenResult(of:)` will say in place of an empty reply.
    static let spokenResultLimit = 240

    /// A finished call's result as the wearer may hear it when the model said nothing after it, or
    /// nil. Only a native tool's own result that succeeded, on one line, short, plain prose: never
    /// an error, never the dispatcher's refusal, and never an untrusted result, which arrives
    /// wrapped (`PromptInjectionPolicy.resultForModel`) and so is never one plain line. What the
    /// wearer hears is then what the tool says it did ("Recorded line pressure 7.5 inWC, as the
    /// technician reported it."), which is true, rather than the miss line, which isn't.
    static func spokenResult(of executed: Executed) -> String? {
        let result = executed.result
        guard !result.isError, !isUnofferedToolResult(result.text, name: executed.call.name) else { return nil }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= spokenResultLimit,
              !text.contains(where: { $0.isNewline || $0 == "<" || $0 == "{" || $0 == "[" }) else { return nil }
        let classification = LocalOutputPolicy.classify(text)
        guard classification.kind == .prose, classification.text == text else { return nil }
        return text
    }

    /// What the model reads when it calls a tool the turn did not offer. Shared by
    /// `LLMService.sendLocalNative` and the qualification runners, so a model is told the same
    /// thing on a phone run as on a turn.
    static func unofferedToolMessage(name: String, offered: Set<String>) -> String {
        unofferedToolPrefix(name) + " Use one of: " + offered.sorted().joined(separator: ", ") + "."
    }

    /// Whether `result` is the dispatcher's not-offered answer to a call to `name`.
    static func isUnofferedToolResult(_ result: String, name: String) -> Bool {
        result.hasPrefix(unofferedToolPrefix(name))
    }

    private static func unofferedToolPrefix(_ name: String) -> String {
        "Error: the tool '\(name)' is not available on this turn."
    }

    // MARK: - Claims of work not done

    /// What a reply may claim was done, and the tools whose successful call this turn backs it
    /// (Plan MQ P3). Small on purpose: the two claims Gemma 4 E2B made on the phone without a call,
    /// in the forms it made them. A "recorded" step answer is the runner's, so it backs a log too.
    /// The assistant's own name claims as "I" does ("Avenkin has logged it"): Gemma talks about
    /// itself in the third person.
    static func actionClaims(assistantName: String = Config.assistantName)
        -> [(tools: Set<String>, patterns: [NSRegularExpression])] {
        let name = assistantName.trimmingCharacters(in: .whitespaces)
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let named = name.isEmpty ? "" : "|\(escaped)|\(escaped) has"
        return [
            (loggingTools, claimPatterns([
                #"\b(i|i've|i have|we've|we have"# + named + #")\s+(just\s+|now\s+|already\s+)?(logged|recorded|saved|noted)\b"#,
                #"\b(i'm|i am|is|are)\s+(now\s+)?(logging|recording)\b"#,
                #"\b(?<!not )(?<!n't )been\s+(logged|recorded|saved)\b"#,
                #"(^|[.!?,;:\u2014]\s*)(ok(ay)?[,.]?\s+)?(logged|recorded)\b"#,
            ])),
            (calculatingTools, claimPatterns([
                #"\b(i|i've|i have|we've|we have"# + named + #")\s+(just\s+|now\s+|already\s+)?(calculated|computed|worked out|figured out)\b"#,
                #"\b(i'm|i am|is)\s+(now\s+)?(calculating|computing)\b"#,
                #"\b(the|your|that)\s+(voltage\s+)?drop\s+(is|would be|will be|comes to|comes out( at)?|works out( at| to)?)\s+(about\s+|around\s+|roughly\s+|approximately\s+|only\s+|just\s+)?\d"#,
                #"(^|[.!?,;:\u2014]\s*)calculated\b"#,
            ])),
        ]
    }

    /// The tools whose successful call backs a log, and a calculation.
    static let loggingTools: Set<String> = ["reading", "procedure_runner", "evidence", "field_session"]
    static let calculatingTools: Set<String> = ["domain_calc"]

    private static func claimPatterns(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    /// The tools that ran this turn and succeeded: not an error, not the dispatcher's not-offered answer.
    private static func succeeded(_ executed: [Executed]) -> Set<String> {
        Set(executed.filter { !$0.result.isError && !isUnofferedToolResult($0.result.text, name: $0.call.name) }
            .map(\.call.name))
    }

    /// The tools one of whose claims `text` makes with no successful call of any of them in
    /// `executed`, or nil. A claim the turn's own calls back ("Logged 120 volts" after `reading`
    /// ran) passes. Pure.
    static func unbackedClaim(in text: String, executed: [Executed],
                              assistantName: String = Config.assistantName) -> Set<String>? {
        let done = succeeded(executed)
        let spoken = text.replacingOccurrences(of: "\u{2019}", with: "'")
        let range = NSRange(spoken.startIndex..., in: spoken)
        for claim in actionClaims(assistantName: assistantName) where claim.tools.isDisjoint(with: done) {
            if claim.patterns.contains(where: { $0.firstMatch(in: spoken, range: range) != nil }) { return claim.tools }
        }
        return nil
    }

    // MARK: - Promises of work not done

    /// Whether `text` promises to act now: `LLMService.announcesToolIntent`, or a promise to call a
    /// tool ("I will now call the domain_calc tool to find the voltage drop.", traced on the phone),
    /// under the same gates: short, asking nothing, not waiting on the wearer. Pure.
    static func promisesToAct(_ text: String, assistantName: String = Config.assistantName) -> Bool {
        if LLMService.announcesToolIntent(text, assistantName: assistantName) { return true }
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard !lowered.contains("<tool_call>"), lowered.count < 280, !lowered.contains("?"),
              !LLMService.waitingOnWearer.contains(where: { lowered.contains($0) }) else { return false }
        let name = NSRegularExpression.escapedPattern(for: assistantName.trimmingCharacters(in: .whitespaces).lowercased())
        let named = name.isEmpty ? "" : #"|\b"# + name + #"(?:\s+will|'ll|\s+is going to|\s+is about to)"#
        let pattern = #"(?:\b(?:i will|i'll|let me|i'm going to|i am going to|i'm about to|i shall)"# + named
            + #")\s+(?:now\s+|first\s+|just\s+|then\s+)?(?:call|use|run|invoke|try)\s+(?:the\s+|a\s+)?"#
            + #"(?:[a-z]+(?:_[a-z0-9]+)+\b|[a-z_]+\s+tool\b|tool\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil
    }

    /// The kinds of work a promise names, each as the tools whose call would back it: a log, a
    /// calculation, a tool named outright.
    private static let promisedWork: [(pattern: NSRegularExpression, tools: Set<String>?)] = [
        (try! NSRegularExpression(pattern: #"\b(?:log|logging|record|recording)\b|\bsave the reading|\bnote the reading"#,
                                  options: [.caseInsensitive]), loggingTools),
        (try! NSRegularExpression(pattern: #"\b(?:calculat\w*|comput\w*|work(?:ing)?\s+(?:it\s+|that\s+|this\s+)?out|"#
                                      + #"figur(?:e|ing)\s+(?:it\s+|that\s+)?out)\b"#, options: [.caseInsensitive]),
         calculatingTools),
        // A tool named as the one to call ("call the domain_calc tool", "use domain_calc"): the set is
        // the name itself, captured as group 1 or 2.
        (try! NSRegularExpression(pattern: #"\b(?:call|use|run|invoke|try)\s+(?:the\s+|a\s+)?([a-z]+(?:_[a-z0-9]+)+)\b|"#
                                      + #"\b([a-z]+(?:_[a-z0-9]+)+)\s+tool\b"#, options: [.caseInsensitive]), nil),
    ]

    /// Whether `text` promises to act (`promisesToAct`) with nothing this turn backing it: some kind
    /// of work it names (a log, a calculation, a tool by name) has no successful call of a tool that
    /// does it, or, naming none, no call succeeded at all. "I will calculate the voltage drop now."
    /// after only the reading ran is unbacked; "Let me check that." after a lookup ran is not. Pure.
    static func unbackedPromise(in text: String, executed: [Executed],
                                assistantName: String = Config.assistantName) -> Bool {
        guard promisesToAct(text, assistantName: assistantName) else { return false }
        let done = succeeded(executed)
        let range = NSRange(text.startIndex..., in: text)
        var promised: [Set<String>] = []
        for work in promisedWork {
            for match in work.pattern.matches(in: text, range: range) {
                if let tools = work.tools { promised.append(tools); break }
                for group in 1...2 {
                    if let token = Range(match.range(at: group), in: text) { promised.append([text[token].lowercased()]) }
                }
            }
        }
        if promised.isEmpty { return done.isEmpty }
        return promised.contains { $0.isDisjoint(with: done) }
    }

    /// Whether a reply offers to do the action the turn asked for instead of doing it ("I can
    /// calculate the voltage drop for you." on "…then work out the voltage drop"). Only when the
    /// turn asks for that action, without a "don't" or a "not yet", so an offer on a turn that
    /// asked for nothing ("I'll give you the readings in a bit") is left alone. Pure.
    static func offersInsteadOfDoing(_ reply: String, turn: String,
                                     assistantName: String = Config.assistantName) -> Bool {
        let said = " " + LocalTurnRouter.normalised(reply)
        let asked = " " + LocalTurnRouter.normalised(turn) + " "
        guard !offerNegations.contains(where: { asked.contains($0) }) else { return false }
        // "Avenkin can calculate…" offers as "I can calculate…" does; the name only as a word.
        let name = LocalTurnRouter.normalised(assistantName)
        for (offers, requests) in offeredActions where requests.contains(where: { asked.contains($0) }) {
            let named: [String] = name.isEmpty ? [] : offers.filter { $0.hasPrefix("i can ") }
                .map { " \(name) can \(String($0.dropFirst("i can ".count)))" }
            if offers.contains(where: { said.contains($0) }) || named.contains(where: { said.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Per action: how a reply offers it, and how a turn asks for it.
    static let offeredActions: [(offers: [String], requests: [String])] = [
        (["i can log", "i can record", "i can save", "want me to log", "want me to record", "like me to log",
          "like me to record", "shall i log", "shall i record", "should i log", "should i record"],
         [" log it ", " log that ", " log this ", " log the ", " record it ", " record that ", " record the "]),
        (["i can calculate", "i can work out", "i can work that out", "i can figure out", "want me to calculate",
          "want me to work out", "like me to calculate", "like me to work out", "shall i calculate",
          "shall i work out", "should i calculate"],
         [" calculate ", " work out ", " figure out "]),
    ]

    static let offerNegations = [" don't ", " dont ", " do not ", " not yet ", " no need ", " never "]

    // MARK: - Round 0's correction

    /// The correction `sendLocal` sends after an "I'll check" stall, or nil when the prose did not
    /// stall: the same two tests (`announcesToolIntent`, `asksUserForLocation`) and the same words.
    /// A reply asking where the wearer is gets the location correction only on a turn whose answer
    /// depends on where they are (`LLMService.turnDependsOnLocation`): on the phone, "It's filthy in
    /// this cupboard" drew "…or tell me where you are?", and the correction made Gemma call
    /// `where_am_i` (Plan MQ P3).
    static func standardCorrection(for prose: String, turn: String,
                                   assistantName: String = Config.assistantName) -> String? {
        if LLMService.asksUserForLocation(prose), LLMService.turnDependsOnLocation(turn) {
            return LLMService.localLocationCorrection
        }
        if LLMService.announcesToolIntent(prose, assistantName: assistantName) { return LLMService.localIntentCorrection }
        return nil
    }
}
