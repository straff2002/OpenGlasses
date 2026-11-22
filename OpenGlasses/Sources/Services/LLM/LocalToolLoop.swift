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
/// - **Round cap** (`Configuration.roundCap`, 3 by the plan's decision 2): after that many tool
///   rounds, one last generation runs with tools withheld and answers from the results gathered.
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
        /// Round 0's recovery: given the first output's prose, the correction to send, or nil when
        /// none is needed. Nil disables the recovery.
        var correction: ((String) -> String?)? = LocalToolLoop.standardCorrection
        /// What the wearer hears when the model said nothing but protocol.
        var missText: String = LLMService.localMissMessage
        /// The assistant's own name, taken off the front of a reply that opens by addressing it
        /// (`withoutLeadingName`). Empty takes nothing off.
        var assistantName: String = Config.assistantName
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
    }

    /// A call the loop ran, with what came back. Arguments are kept in memory for the caller's
    /// ledger and are never logged.
    struct Executed {
        let call: Call
        let result: ExecutionResult
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
    }

    // MARK: - Parsing

    /// One generation's output, read by the shipped policy, with a call inside `<think>` taken
    /// rather than dropped.
    struct Parsed {
        let classification: LocalOutputPolicy.Classification
        /// The usable call: the spoken part's when it has one, else one found in the reasoning.
        let invocation: LocalOutputPolicy.Invocation?
        let fromReasoning: Bool
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
            return Parsed(classification: classification, invocation: classification.invocation,
                          fromReasoning: false)
        }
        let (spoken, reasoning) = ThinkStreamFilter.strip(raw, startsInThink: hasClose && !hasOpen)
        let classification = LocalOutputPolicy.classify(spoken)
        if classification.invocation == nil, let reasoning,
           let inThought = LocalOutputPolicy.classify(reasoning).invocation {
            return Parsed(classification: classification, invocation: inThought, fromReasoning: true)
        }
        return Parsed(classification: classification, invocation: classification.invocation,
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

    /// `parse(_:)` over the text, then, when the text holds no usable call, the first call the
    /// runtime parsed — the rule `LocalOutputPolicy.classify(_:parsedCalls:)` follows. In practice
    /// only one is present: a runtime parser consumes the frame it reads. Any protocol left in the
    /// text is still removed from what is spoken.
    static func parse(_ generation: Generation) -> Parsed {
        let parsed = parse(generation.text)
        guard parsed.invocation == nil, let first = generation.toolCalls.first else { return parsed }
        return Parsed(classification: parsed.classification, invocation: first.invocation, fromReasoning: false)
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

        func generation(_ purpose: Purpose, messages: [Message], toolsOffered: Bool) async throws -> Parsed {
            try Task.checkCancellation()
            generations += 1
            let raw = try await generate(GenerationRequest(messages: messages, toolsOffered: toolsOffered,
                                                           purpose: purpose, round: executed.count))
            try Task.checkCancellation()
            return parse(raw)
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
            }
            transcript.append(.assistant(text))
            return Outcome(text: text, endReason: reason, transcript: transcript, executed: executed,
                           generations: generations, usedCorrection: usedCorrection,
                           callsFromReasoning: fromReasoning, callsNotRun: notRun)
        }

        var parsed = try await generation(.initial, messages: transcript, toolsOffered: cap > 0)

        // Round 0's recovery: the stall `sendLocal` corrects today, corrected the same way.
        if parsed.invocation == nil, parsed.classification.kind == .prose, cap > 0,
           let correction = configuration.correction?(parsed.text) {
            usedCorrection = true
            let scaffold = transcript + [.assistant(parsed.text), .user(correction)]
            parsed = try await generation(.correction, messages: scaffold, toolsOffered: true)
        }

        while let invocation = parsed.invocation {
            let call = Call(id: "call_\(executed.count + 1)", name: invocation.name,
                            arguments: invocation.arguments, fromReasoning: parsed.fromReasoning)

            guard executed.count < cap else {
                // Only reachable when the cap is 0, or a model calls after tools were withheld.
                notRun += 1
                return finish(parsed, .roundCap)
            }
            guard seen.insert(call.signature).inserted else {
                notRun += 1
                // Whatever it said beside the repeat stands; with nothing said, answer from the
                // results already gathered, tools withheld.
                if !parsed.text.isEmpty { return finish(parsed, .repeatedCall) }
                let final = try await generation(.final, messages: transcript, toolsOffered: false)
                if final.invocation != nil { notRun += 1 }
                return finish(final, .repeatedCall)
            }

            if call.fromReasoning { fromReasoning += 1 }
            try Task.checkCancellation()
            transcript.append(.assistant(parsed.text, calling: call))
            let result = try await execute(call)
            try Task.checkCancellation()
            transcript.append(.toolResult(result.text, for: call))
            executed.append(Executed(call: call, result: result))

            let atCap = executed.count >= cap
            parsed = try await generation(atCap ? .final : .afterTools, messages: transcript,
                                          toolsOffered: !atCap)
            if atCap {
                if parsed.invocation != nil { notRun += 1 }
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

    // MARK: - Round 0's correction

    /// The correction `sendLocal` sends after an "I'll check" stall, or nil when the prose did not
    /// stall: the same two tests (`announcesToolIntent`, `asksUserForLocation`) and the same words.
    static func standardCorrection(for prose: String) -> String? {
        if LLMService.asksUserForLocation(prose) { return LLMService.localLocationCorrection }
        if LLMService.announcesToolIntent(prose) { return LLMService.localIntentCorrection }
        return nil
    }
}
