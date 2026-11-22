import Foundation

/// The Field Assist turns a downloaded model answers from its own knowledge instead of calling the
/// tool, recognised in code and called deterministically before the model runs (Plan MQ P3). Pure:
/// the same turn, history and offer always route the same way.
///
/// ### Why
/// Phone runs of Gemma 4 E2B read manual passages and log readings well, but on three turn shapes
/// it almost never called the tool and answered from memory, sometimes with advice the manual does
/// not hold: an error code (17 of 117 called), a nameplate model number (2 of 25), and a step of a
/// procedure already running (0 of 58). Offering fewer tools did not help (owner, 2026-11-23), so
/// these turns no longer depend on the model choosing the call.
///
/// ### Precision over recall
/// A route fires only on the request's own shape — a code asked about or shown, a number given to
/// identify the unit, a fixed step word while a procedure runs — never on a word alone, so a turn
/// that names a code or a unit without asking ("I've seen that E223 code loads of times") goes to
/// the model as before. A turn that asks another tool for something (log, photo, calculate) is
/// never routed. A route the turn did not offer the tool for never fires.
///
/// ### What is not routed
/// Starting a procedure: it needs the procedure's id from the vault's catalogue, which the model
/// reads in its prompt and the router does not have. Error codes through `table_lookup`: it needs
/// a real table id, which only the passages give.
enum LocalTurnRouter {

    /// What the router reads besides the words.
    struct Context: Equatable, Sendable {
        /// The tools this turn offers. A route needs its tool among them.
        var offered: Set<String>
        /// A Field Assist procedure is running, so step words mean the running step.
        var procedureActive: Bool
        /// The running step waits on a read-back's yes or no, or a corrective note: a short reply
        /// is that, not the step's answer, and is left to the model, which has the step's
        /// instructions in its prompt.
        var procedureAwaitsConfirmation: Bool = false

        init(offered: Set<String>, procedureActive: Bool, procedureAwaitsConfirmation: Bool = false) {
            self.offered = offered
            self.procedureActive = procedureActive
            self.procedureAwaitsConfirmation = procedureAwaitsConfirmation
        }
    }

    enum Kind: String, CaseIterable, Sendable {
        case errorCode, modelNumber, procedureNext, procedureRepeat, procedureAnswer
    }

    /// How a routed call's result reaches the wearer.
    enum Speech: Equatable, Sendable {
        /// The model reads the result and answers (it may call again): a lookup's result is a
        /// passage, not an answer.
        case model
        /// The result is said as the runner wrote it (`spokenProcedureResult(_:)`), with no
        /// generation: a step's authored words, safety lines included, are not the model's to
        /// paraphrase.
        case result
    }

    struct Route: Equatable, Sendable {
        let kind: Kind
        let tool: String
        /// String values only: what the turn said, as said.
        let arguments: [String: String]

        var speech: Speech {
            switch kind {
            case .errorCode, .modelNumber: return .model
            case .procedureNext, .procedureRepeat, .procedureAnswer: return .result
            }
        }
    }

    // MARK: - Routing

    /// The call `turn` asks for, or nil when the model should decide.
    static func route(turn: String, history: [LocalToolLoop.Message], context: Context) -> Route? {
        let text = turn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let procedure = context.procedureActive && context.offered.contains("procedure_runner")

        if procedure, let kind = stepCommand(text) {
            return Route(kind: kind, tool: "procedure_runner",
                         arguments: ["action": kind == .procedureNext ? "next" : "repeat"])
        }
        let lookup = context.offered.contains("equipment_lookup") && !asksAnotherTool(text)
        if lookup, let code = askedErrorCode(text) {
            return Route(kind: .errorCode, tool: "equipment_lookup", arguments: ["query": code])
        }
        if lookup, let model = identifiedModelNumber(text) {
            return Route(kind: .modelNumber, tool: "equipment_lookup", arguments: ["query": model])
        }
        if procedure, !context.procedureAwaitsConfirmation, isStepAnswer(text, history: history) {
            return Route(kind: .procedureAnswer, tool: "procedure_runner",
                         arguments: ["action": "answer", "value": text])
        }
        return nil
    }

    // MARK: - Error codes

    /// The one diagnostic code ("E110", "e 110") a turn asks about or reports on the display, or
    /// nil. Two different codes are not one lookup ("E223, E227 or E272" answers a step).
    static func askedErrorCode(_ text: String) -> String? {
        let codes = Set(errorCodes(in: text))
        guard codes.count == 1, let code = codes.first else { return nil }
        let lowered = normalised(text)
        let asks = text.contains("?") || errorCodeCues.contains { lowered.contains($0) }
        return asks ? code : nil
    }

    /// Words that make a code the subject of the turn: the control shows it now, or its meaning
    /// is asked for. "Seen" and "know" are not among them, so a code named in passing stays the
    /// model's.
    static let errorCodeCues = [
        "showing", "shows", "flashing", "flashes", "blinking", "displaying", "displays", "on the display",
        "throwing", "came up", "coming up", "popped up", "says", "saying", "reads", "reading",
        "look up", "lookup", "mean", "means", "meaning",
    ]

    /// Every `E` + three-digit code in `text`, uppercased, with a space between the letter and the
    /// digits closed up.
    static func errorCodes(in text: String) -> [String] {
        let ns = text as NSString
        return errorCodePattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { "E" + ns.substring(with: $0.range(at: 1)) }
    }

    private static let errorCodePattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}-])[Ee] ?(\d{3})(?![\p{L}\p{N}]|[.,]\d)"#)

    // MARK: - Model numbers

    /// The model number a turn gives to identify the unit ("the nameplate says 070XV36B"), as said,
    /// or nil. A model number named without asking which unit it is ("What's the AFUE on the
    /// 070XV36B?") is a question about the unit, and the model's.
    static func identifiedModelNumber(_ text: String) -> String? {
        let lowered = normalised(text)
        guard identifyCues.contains(where: { lowered.contains($0) }) else { return nil }
        return modelNumbers(in: text).first
    }

    static let identifyCues = [
        "which unit", "what unit", "nameplate", "name plate", "data plate", "rating plate", "model number",
        "model no", "which model", "what model", "identify",
    ]

    /// Tokens shaped like a model number, as written: letters and at least three digits, hyphens
    /// allowed (a leading one too: "-090-060C" is how a nameplate suffix is read out). Not a
    /// diagnostic code, and not a number with a unit on it ("115V", "3.5in").
    static func modelNumbers(in text: String) -> [String] {
        let edges = CharacterSet(charactersIn: ".,;:!?\"'()[]{}\u{2018}\u{2019}\u{201C}\u{201D}")
        return text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let token = String(raw).trimmingCharacters(in: edges)
            guard token.count >= 4, token.count <= 24,
                  token.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }),
                  token.filter(\.isNumber).count >= 3, token.contains(where: \.isLetter),
                  token.range(of: #"^[Ee]\d{3}$"#, options: .regularExpression) == nil,
                  token.range(of: #"^\d+(\.\d+)?[A-Za-z]{1,4}$"#, options: .regularExpression) == nil,
                  !token.hasSuffix("-") else { return nil }
            return token
        }
    }

    // MARK: - Procedure steps

    /// `.procedureNext` or `.procedureRepeat` when the whole turn is a step word, else nil. Whole
    /// short utterances only, the way the no-model procedure voice matches them
    /// (`ProcedureVoiceDecider.command`), so "next" inside a sentence is never taken. A bare
    /// "done" is not "next": on a step that asks yes or no it is the answer.
    static func stepCommand(_ text: String) -> Kind? {
        let words = normalised(text).split(separator: " ").map(String.init)
        var core = Array(words.drop(while: { leadingFiller.contains($0) }))
        while let last = core.last, trailingFiller.contains(last) { core.removeLast() }
        let phrase = core.joined(separator: " ")
        if nextPhrases.contains(phrase) { return .procedureNext }
        if repeatPhrases.contains(phrase) { return .procedureRepeat }
        return nil
    }

    static let leadingFiller: Set<String> = [
        "ok", "okay", "right", "alright", "done", "finished", "yep", "yeah", "yes", "cool", "great", "so",
        "and", "then", "um", "uh", "hey", "sorry", "pardon", "now", "please", "that's", "thats", "it's", "its",
    ]
    static let trailingFiller: Set<String> = ["please", "then", "now", "thanks", "mate"]

    static let nextPhrases: Set<String> = [
        "next", "next step", "next one", "go on", "carry on", "continue", "move on", "keep going",
        "what's next", "whats next", "what's the next step", "whats the next step",
        "on to the next step", "onto the next step", "go to the next step", "the next step",
    ]

    static let repeatPhrases: Set<String> = [
        "repeat", "repeat that", "repeat it", "repeat the step", "repeat step", "repeat that step",
        "say again", "say that again", "say it again", "say that step again", "say the step again",
        "again", "what was that", "read it again", "read that again", "read the step again",
        "come again", "one more time", "i didn't catch that", "didn't catch that",
        "can you say that again", "could you say that again", "can you repeat that", "could you repeat that",
    ]

    /// A short reply to what the running step just asked for: the last thing said asked for a
    /// reply (`asksForReply`), and the turn is not itself a question, a request or another tool's
    /// words. Sixteen words at most: two readings with their ranges are said in about fifteen
    /// ("low 0.20 to 0.40 … and high 0.95 to 1.25"); an aside is usually longer or opens with a
    /// request word ("hang on", "I'll").
    static func isStepAnswer(_ text: String, history: [LocalToolLoop.Message]) -> Bool {
        guard let last = history.last, last.role == .assistant, asksForReply(last.content),
              !text.contains("?") else { return false }
        // Counted as spoken, so "0.20" is one word.
        let spokenWords = text.split(whereSeparator: { $0.isWhitespace }).count
        guard (1...stepAnswerWordLimit).contains(spokenWords),
              let first = normalised(text).split(separator: " ").first.map(String.init),
              !requestOpeners.contains(first), !asksAnotherTool(text),
              // Talk about procedures ("I already ran the no ignition procedure") is not a step's answer.
              !OfflineKeywordRouter.fieldToolHints(text).contains("procedure_runner") else { return false }
        return true
    }

    static let stepAnswerWordLimit = 16

    /// Whether what was said ends by asking the wearer for something: a question, or a last
    /// sentence that asks to be told ("Tell me both readings…", "Report what you find.").
    static func asksForReply(_ said: String) -> Bool {
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let body = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        let lastSentence = body.components(separatedBy: ". ").last ?? body
        let opening = normalised(lastSentence)
        return replyRequests.contains { opening.hasPrefix($0) }
    }

    static let replyRequests = ["tell me", "report", "let me know", "give me", "read me", "read out", "say what"]

    /// First words that make a turn a question or a request rather than an answer.
    static let requestOpeners: Set<String> = [
        "what", "what's", "whats", "how", "why", "where", "when", "who", "which", "can", "could", "would",
        "should", "will", "do", "does", "did", "tell", "show", "start", "stop", "end", "pause",
        "resume", "log", "record", "take", "snap", "keep", "call", "text", "send", "look", "find",
        "calculate", "work", "read", "say", "repeat", "go", "skip", "cancel", "hang", "hold", "wait",
        "give", "put", "remind", "order", "don't", "dont", "let's", "lets", "i'll", "ill", "thanks",
        "cheers", "next", "back", "previous",
    ]

    // MARK: - Shared

    /// Whether the turn asks another tool for something: a reading logged, a photo, a calculation,
    /// the job, a page shown (`OfflineKeywordRouter.fieldToolHints`, and "log" or "record" for a
    /// reading, whose other cues — "pressure", "temperature" — also describe what a step asks).
    static func asksAnotherTool(_ text: String) -> Bool {
        let hinted = Set(OfflineKeywordRouter.fieldToolHints(text))
        if !hinted.isDisjoint(with: ["evidence", "domain_calc", "field_session", "show_source"]) { return true }
        let words = Set(normalised(text).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["log", "record"])
    }

    /// Lowercased, curly apostrophes straightened, punctuation other than apostrophes and hyphens
    /// turned to spaces, spaces collapsed.
    static func normalised(_ text: String) -> String {
        let straightened = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let spaced = String(straightened.map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" ? $0 : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    // MARK: - Speaking a step's result

    /// What the wearer hears after a routed procedure call, from the runner's own result, or nil
    /// when the loop should hand the result to the model instead: an error, a refusal, a read-back
    /// or a corrective note to ask for (those need the model's next call), or text this cannot
    /// read as the runner's.
    ///
    /// `procedure_runner` writes its result for a model: the step's safety line, title and
    /// instruction, then lines telling the model what to call next. Only the authored part is
    /// said, word for word; the lines for the model are not. A result with no step in it (a
    /// one-line confirmation) is said whole when nothing in it speaks to the model.
    static func spokenProcedureResult(_ result: LocalToolLoop.ExecutionResult) -> String? {
        guard !result.isError else { return nil }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("<untrusted"),
              !refusalPrefixes.contains(where: { text.hasPrefix($0) }) else { return nil }

        // An answer the runner recorded: what it recorded, without the call it asks for next.
        if text.hasPrefix("Recorded "), !text.contains("\n"), let cut = text.range(of: " Call '") {
            return prose(String(text[..<cut.lowerBound]))
        }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let header = lines.firstIndex(where: { $0.hasPrefix("Step — ") || $0.hasPrefix("Step: ") }) else {
            guard !modelDirected.contains(where: { text.contains($0) }) else { return nil }
            return prose(lines.joined(separator: " "))
        }
        var spoken: [String] = []
        for line in lines[..<header] {
            if line.hasPrefix("⚠️ SAFETY: ") || leadLines.contains(line) {
                spoken.append(line)
            } else if line.hasPrefix(coachingSafety) {
                spoken.append("SAFETY: " + line.dropFirst(coachingSafety.count))
            }
        }
        let headerLine = lines[header]
        let title = headerLine.hasPrefix("Step — ") ? headerLine.dropFirst(7) : headerLine.dropFirst(6)
        if !title.isEmpty { spoken.append(String(title) + (title.hasSuffix(".") ? "" : ".")) }
        if header + 1 < lines.count {
            var instruction = lines[header + 1]
            if instruction.hasPrefix(coachingInstruction) {
                instruction = String(instruction.dropFirst(coachingInstruction.count))
            }
            if !modelDirected.contains(where: { instruction.contains($0) }) { spoken.append(instruction) }
        }
        return prose(spoken.joined(separator: " "))
    }

    /// The runner's openings for a call that did not go through, or that needs the model next.
    static let refusalPrefixes = [
        "Could not ", "No active ", "No procedure", "No action", "Unknown action", "Field Assist is disabled",
        "Error:", "Read this back", "Recorded, and it needs a corrective note", "Specify ",
    ]

    /// Lines before a step that are said: where the run now is.
    static let leadLines: Set<String> = ["Last step.", "Stepped back."]

    /// Words only a line for the model carries.
    static let modelDirected = [
        "Call '", "call '", "procedure_runner", "Choices for", "(Terminal step", "The route follows",
        "This step takes an answer", "Read this back",
    ]

    private static let coachingSafety = "SAFETY — read this first, before the step: "
    private static let coachingInstruction = "Read exactly as written: "

    /// `text` when it is plain prose the voice can say, else nil.
    private static func prose(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, LocalOutputPolicy.classify(trimmed).kind == .prose else { return nil }
        return trimmed
    }
}
