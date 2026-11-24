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
/// ### Starting a procedure
/// Gemma 4 E2B started none of the vault's procedures when asked (0 of 3). A start is routed only
/// on an imperative start ("Start the no ignition procedure", "let's run the E270 procedure") with
/// no procedure running, and only when the words name exactly one entry of the vault's catalogue
/// (`Context.procedures`): every word said about it is in that title and in no other's. Anything
/// more, or anything said after it, goes to the model.
///
/// ### Job commands, evidence and a reading's follow-up (part 2)
/// On the same runs Gemma asked back instead of calling `field_session` for a job opened, a work
/// order number given, a job resumed, the next unit or the job's time, and wrote `evidence` and a
/// second reading ("and the other one?") as prose or a broken call. These are routed on the same
/// rule: an imperative at the front of the turn (after "right", "OK", "that's it"…) or a fixed
/// question, with nothing after it but an aside. A turn that defers, denies or conditions it ("I'll
/// start the job later", "don't log anything yet", "once I've had a look") never routes, and nor
/// does one that asks for something else in the same breath. Each passes only what the turn said:
/// a work order number as said, the next unit's model only when it is the one model named, and no
/// photo id (none is ever said). A follow-up records the other of exactly two values the last
/// message gave for one quantity, once the reply logged the first; anything less certain is the
/// model's. All three hand their result to the model: `field_session` writes for a model, and the
/// others' short results are spoken by the loop if the model says nothing.
///
/// ### A reading logged in one breath
/// Asked to "Log manifold, natural gas, Low at 0.68 in. w.c.", Gemma asked back which model or
/// what was measured (6 of 9 failed on the phone), though the turn said both. A turn that is the
/// log command and nothing else — "Log <what> at <value> [unit]", or "<what> reads <value>, log
/// it" — is routed with exactly one number in it, what was measured said, and nothing deferred,
/// denied or asked for besides. A question ("can you log…"), two values, a correction ("not 140")
/// and a log with a calculation after it go to the model.
///
/// ### Log it, then work out the voltage drop
/// "Line voltage at the control is 115. Log it, then work out the voltage drop at 15 amps over 50
/// feet of 14 gauge copper" asks for two calls, and Gemma made both right on most runs but not all:
/// prose with no call, a call in a form nothing reads, a resistance it made up. When the part before
/// "then" is a reading logged in one breath and the part after it asks for a voltage drop with one
/// current and one length said with their units, both are routed in order: the reading, then
/// `domain_calc` with the operation, the current and the length as said. The loop completes the
/// calculation as it does a model's (`LocalArgumentCompletion`): the wire, the metal and the supply
/// come from the technician's words, never from the router. The model says the result.
///
/// ### What is not routed
/// Error codes through `table_lookup`: it needs a real table id, which only the passages give.
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
        /// The procedures the vault lets this turn start, by id and title. Empty: no start is routed.
        var procedures: [CatalogueEntry] = []
        /// What the running step takes as its answer, when nothing is recorded for it yet: its
        /// `expected_input` and its branch conditions. A step whose instruction asks no question
        /// ("…The control stores it and resets.") still takes a reply that says one of these.
        var stepReplies: [String] = []

        init(offered: Set<String>, procedureActive: Bool, procedureAwaitsConfirmation: Bool = false,
             procedures: [CatalogueEntry] = [], stepReplies: [String] = []) {
            self.offered = offered
            self.procedureActive = procedureActive
            self.procedureAwaitsConfirmation = procedureAwaitsConfirmation
            self.procedures = procedures
            self.stepReplies = stepReplies
        }
    }

    /// One procedure a turn may start.
    struct CatalogueEntry: Equatable, Sendable, Decodable {
        let id: String
        let title: String
    }

    enum Kind: String, CaseIterable, Sendable {
        case errorCode, modelNumber, procedureStart, procedureNext, procedureRepeat, procedureAnswer
        case jobCommand, evidence, readingFollowUp, readingLogged, voltageDrop
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
            case .errorCode, .modelNumber, .jobCommand, .evidence, .readingFollowUp, .readingLogged, .voltageDrop:
                return .model
            case .procedureStart, .procedureNext, .procedureRepeat, .procedureAnswer: return .result
            }
        }
    }

    // MARK: - Routing

    /// Every call `turn` asks for, in order, or none when the model should decide: a reading logged
    /// then a voltage drop worked out (`loggedReadingThenVoltageDrop`), else `route(turn:…)`'s one.
    static func routes(turn: String, history: [LocalToolLoop.Message], context: Context) -> [Route] {
        let text = turn.trimmingCharacters(in: .whitespacesAndNewlines)
        if context.offered.isSuperset(of: ["reading", "domain_calc"]),
           let pair = loggedReadingThenVoltageDrop(text) {
            return [Route(kind: .readingLogged, tool: "reading", arguments: pair.reading),
                    Route(kind: .voltageDrop, tool: "domain_calc", arguments: pair.voltageDrop)]
        }
        return route(turn: turn, history: history, context: context).map { [$0] } ?? []
    }

    /// The one call `turn` asks for, or nil when the model should decide.
    static func route(turn: String, history: [LocalToolLoop.Message], context: Context) -> Route? {
        let text = turn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let procedure = context.procedureActive && context.offered.contains("procedure_runner")

        if procedure, let kind = stepCommand(text) {
            return Route(kind: kind, tool: "procedure_runner",
                         arguments: ["action": kind == .procedureNext ? "next" : "repeat"])
        }
        if !context.procedureActive, context.offered.contains("procedure_runner"),
           let id = startedProcedure(text, catalogue: context.procedures) {
            return Route(kind: .procedureStart, tool: "procedure_runner",
                         arguments: ["action": "start", "procedure_id": id])
        }
        if context.offered.contains("field_session"),
           let arguments = jobCommand(text, procedureActive: context.procedureActive) {
            return Route(kind: .jobCommand, tool: "field_session", arguments: arguments)
        }
        if context.offered.contains("evidence"), let action = evidenceChoice(text) {
            return Route(kind: .evidence, tool: "evidence", arguments: ["action": action])
        }
        if context.offered.contains("reading"), let arguments = readingFollowUp(text, history: history) {
            return Route(kind: .readingFollowUp, tool: "reading", arguments: arguments)
        }
        if context.offered.contains("reading"), let arguments = loggedReading(text) {
            return Route(kind: .readingLogged, tool: "reading", arguments: arguments)
        }
        let lookup = context.offered.contains("equipment_lookup") && !asksAnotherTool(text)
        if lookup, let code = askedErrorCode(text) {
            return Route(kind: .errorCode, tool: "equipment_lookup", arguments: ["query": code])
        }
        if lookup, let model = identifiedModelNumber(text) {
            return Route(kind: .modelNumber, tool: "equipment_lookup", arguments: ["query": model])
        }
        if procedure, !context.procedureAwaitsConfirmation,
           isStepAnswer(text, history: history, stepReplies: context.stepReplies) {
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

    // MARK: - Starting a procedure

    /// The id of the one catalogue procedure `text` tells the assistant to start, or nil. The turn
    /// opens with a start verb (after "ok", "please", "can you", "let's"…); the words up to
    /// "procedure" name it, and nothing but filler follows. Without the word "procedure", the whole
    /// title must be said, so "open the pressure switch" is not a start. The words name it when every
    /// one of them is in its title (case, punctuation, "the" and a code list in brackets ignored),
    /// and in no other title; one word alone must be a code or at least five letters. Past tense
    /// and statements ("I already ran the no ignition procedure") have no start verb in front.
    static func startedProcedure(_ text: String, catalogue: [CatalogueEntry]) -> String? {
        guard !catalogue.isEmpty, !asksAnotherTool(text) else { return nil }
        var words = ArraySlice(titleWords(text))
        var letUs = false
        while let first = words.first, startOpeners.contains(first) {
            if first == "let's" || first == "lets" || first == "let" { letUs = true }
            words = words.dropFirst()
        }
        guard let verb = words.first, startVerbs.contains(verb) || (letUs && verb == "do") else { return nil }
        let rest = Array(words.dropFirst())
        let named: [String]
        if let mark = rest.firstIndex(where: { procedureWords.contains($0) }) {
            guard rest[(mark + 1)...].allSatisfy({ trailingStartFiller.contains($0) }) else { return nil }
            named = Array(rest[..<mark])
        } else {
            guard verb != "open" else { return nil }
            named = rest
        }
        let said = Set(named.filter { !nameFiller.contains($0) })
        guard !said.isEmpty else { return nil }
        if said.count == 1, let only = said.first,
           !(only.count >= 5 || only.range(of: #"^e\d{3}$"#, options: .regularExpression) != nil) { return nil }
        let matches = catalogue.filter { said.isSubset(of: titleTokens($0.title)) }
        guard matches.count == 1, let match = matches.first else { return nil }
        if !rest.contains(where: { procedureWords.contains($0) }) {
            // The whole title, said: the words outside its brackets, codes aside.
            guard titleCore(match.title).isSubset(of: said) else { return nil }
        }
        return match.id
    }

    /// `normalised(_:)` split into words, hyphenated words split too ("no-ignition").
    static func titleWords(_ text: String) -> [String] {
        normalised(text).split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init).filter { !$0.isEmpty }
    }

    /// A title's words, brackets included, without filler.
    static func titleTokens(_ title: String) -> Set<String> {
        Set(titleWords(title).filter { !nameFiller.contains($0) })
    }

    /// A title's words outside brackets, without codes or filler: what saying the whole title says.
    static func titleCore(_ title: String) -> Set<String> {
        let unbracketed = title.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        return titleTokens(unbracketed).filter { $0.range(of: #"^e\d{3}$"#, options: .regularExpression) == nil }
    }

    static let startOpeners: Set<String> = [
        "ok", "okay", "right", "alright", "so", "now", "please", "can", "could", "would", "will", "you", "go",
        "ahead", "and", "then", "yeah", "yes", "cool", "great", "let's", "lets", "let", "us", "just",
    ]
    static let startVerbs: Set<String> = ["start", "run", "begin", "open", "launch"]
    static let procedureWords: Set<String> = ["procedure", "procedures"]
    /// Words that may follow "procedure" in a start.
    static let trailingStartFiller: Set<String> = ["please", "now", "then", "for", "me", "us", "again", "thanks", "mate"]
    /// Words that name no procedure.
    static let nameFiller: Set<String> = ["the", "a", "an", "for", "me", "us", "please", "now", "again", "then"]

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
    ///
    /// A step whose instruction asks nothing still takes its answer when the turn plainly says
    /// one of `stepReplies` (`saysStepReply`): "The code stopped blinking and the control reset"
    /// after "…hold the button until the code stops blinking. The control stores it and resets."
    static func isStepAnswer(_ text: String, history: [LocalToolLoop.Message], stepReplies: [String] = []) -> Bool {
        guard let last = history.last, last.role == .assistant, !text.contains("?"),
              asksForReply(last.content) || saysStepReply(text, replies: stepReplies) else { return false }
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

    /// Whether `text` says one of the step's expected replies: it shares at least two content
    /// words with one of them, and those are at least half of its own. "The code stopped blinking
    /// and the control reset" says the stored branch; "it's hot in here" and "the control" say
    /// nothing.
    static func saysStepReply(_ text: String, replies: [String]) -> Bool {
        let said = contentWords(text)
        guard said.count >= 2 else { return false }
        return replies.contains { reply in
            let shared = said.intersection(contentWords(reply)).count
            return shared >= 2 && shared * 2 >= said.count
        }
    }

    /// The words of `text` that carry meaning: `normalised(_:)`, without function words.
    static func contentWords(_ text: String) -> Set<String> {
        Set(normalised(text).split(separator: " ").map(String.init)).subtracting(functionWords)
    }

    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from",
        "it", "its", "it's", "is", "was", "are", "were", "be", "been", "has", "have", "had", "this", "that",
        "then", "there", "now", "just", "so", "yes", "yeah", "ok", "okay", "i", "i've", "we", "you", "my",
        "our", "up", "out", "off", "all", "any", "some", "no",
    ]

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

    // MARK: - Commands

    /// A turn read as a command: its first clause that is not only "right", "OK", "that's it"…,
    /// with those openers off the front, and the clauses after it.
    struct Command: Equatable {
        /// The command clause's words, openers taken off.
        let words: [String]
        /// The later clauses' words.
        let trailing: [[String]]
        /// The turn holds a question mark.
        let question: Bool
        /// It opens "can you", "could you", "would you", "will you": a request, though asked.
        let polite: Bool

        /// Every word of the turn after the openers.
        var allWords: [String] { words + trailing.flatMap { $0 } }

        /// A question that is not a polite request is not a command.
        var isImperative: Bool { !question || polite }
    }

    /// `text` as a command, or nil when nothing is left once the openers are off. "now" stays at
    /// the front when `keepingNow` ("now the second furnace" is the move, not an opener).
    static func readCommand(_ text: String, keepingNow: Bool = false) -> Command? {
        let clauses = clauseWords(text)
        guard let index = clauses.firstIndex(where: { !$0.allSatisfy(clauseOpeners.contains) }) else { return nil }
        var words = ArraySlice(clauses[index])
        var polite = false
        while let first = words.first, commandOpeners.contains(first) || (!keepingNow && first == "now") {
            if ["can", "could", "would", "will"].contains(first) { polite = true }
            words = words.dropFirst()
        }
        guard !words.isEmpty else { return nil }
        return Command(words: Array(words), trailing: Array(clauses[(index + 1)...]), question: text.contains("?"),
                       polite: polite)
    }

    /// `text` split at commas, semicolons, question and exclamation marks and full stops (not a
    /// decimal point), each clause `normalised(_:)` into words; empty clauses dropped.
    static func clauseWords(_ text: String) -> [[String]] {
        let marked = clauseBreak.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\u{1F}")
        return marked.split(separator: "\u{1F}").map { normalised(String($0)).split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
    }

    private static let clauseBreak = try! NSRegularExpression(pattern: #"[,;!?]|\.(?!\d)"#)

    /// Words that open a command and say nothing of it.
    static let commandOpeners: Set<String> = [
        "ok", "okay", "right", "alright", "so", "and", "then", "yeah", "yes", "yep", "cool", "great", "please",
        "just", "actually", "oh", "um", "uh", "can", "could", "would", "will", "you", "let's", "lets", "let", "us",
        "go", "ahead",
    ]

    /// A clause of these alone ("That's it,", "Right,", "All done.") comes before the command.
    static let clauseOpeners: Set<String> = commandOpeners.union([
        "that's", "thats", "that", "is", "it", "all", "done", "good", "sorted", "lovely", "perfect", "brilliant",
        "now", "finished",
    ])

    /// Words that defer, deny or condition what the turn says ("I'll start the job later", "don't
    /// close it yet", "once I've had a look"): a turn holding one is the model's.
    static let deferredOrDenied: Set<String> = [
        "later", "tomorrow", "yesterday", "tonight", "once", "after", "afterwards", "before", "soon", "yet",
        "minute", "minutes", "when", "if", "until", "unless", "not", "don't", "dont", "didn't", "didnt", "won't",
        "wont", "never", "wait", "hang", "already", "earlier", "maybe", "might", "should", "shouldn't",
    ]

    /// The same, said as a phrase.
    static let deferredPhrases = ["hold on", "in a bit", "in a sec", "in a second", "in a moment"]

    /// Words that ask for something else, so a clause holding one is not an aside: a reading, a
    /// photo, a calculation, the report.
    static let otherRequests: Set<String> = [
        "log", "record", "photo", "photos", "picture", "pictures", "snap", "take", "calculate", "send", "email",
        "report", "summary", "deliver", "share", "forward", "call", "text", "show", "look", "find", "procedure",
        "order", "remind", "check",
    ]

    /// Whether `words` (or the turn's text) defer, deny or condition, leaving `allowing` aside.
    static func defers(_ words: [String], text: String, allowing: Set<String> = []) -> Bool {
        if words.contains(where: { deferredOrDenied.contains($0) && !allowing.contains($0) }) { return true }
        let spoken = " " + normalised(text) + " "
        return deferredPhrases.contains { spoken.contains(" \($0) ") }
    }

    /// A clause after the command that only remarks ("I'm going for lunch", "it's all working"):
    /// nothing deferred and nothing else asked for.
    static func isAside(_ clause: [String], allowing: Set<String> = []) -> Bool {
        !clause.contains { (deferredOrDenied.contains($0) || otherRequests.contains($0)) && !allowing.contains($0) }
    }

    // MARK: - Job commands

    /// The `field_session` call a turn gives about the job, or nil. A status question; or an
    /// imperative to open, number, pause, resume, close the job, or move to the next unit, at the
    /// front of the turn with nothing after it but an aside. A start and the next unit are not
    /// routed while a procedure runs: a job is then open and on a unit, and the model has the step.
    static func jobCommand(_ text: String, procedureActive: Bool) -> [String: String]? {
        if jobStatusAsked(text) { return ["action": "status"] }
        guard let command = readCommand(text), command.isImperative,
              !defers(command.allWords, text: text) else { return nil }
        if !procedureActive, let started = jobStart(command, text: text) { return started }
        if let reference = statedJobReference(command, text: text) {
            return ["action": "set_job_reference", "job_reference": reference]
        }
        if isJobPause(command) { return ["action": "pause"] }
        if isJobResume(command) { return ["action": "resume"] }
        if isJobEnd(command) { return ["action": "end"] }
        if !procedureActive, let moved = readCommand(text, keepingNow: true), let next = nextUnit(moved, text: text) {
            return next
        }
        return nil
    }

    /// The words after the job noun, filler only.
    static let commandFiller: Set<String> = ["please", "now", "thanks", "mate", "then", "for", "me", "us"]

    private static let jobDeterminers: Set<String> = ["the", "this", "my", "our"]

    /// "Open a new job for the SLP99 furnace at 14 Hill Street", "Start job 1005", "New job, work
    /// order 2231". What follows "job" is a number, filler, or a "for/on/at/with" phrase; a later
    /// clause is an aside or says the number. The number is the one the turn gives, as said.
    static func jobStart(_ command: Command, text: String) -> [String: String]? {
        var words = ArraySlice(command.words)
        if words.first == "new", words.dropFirst().first == "job" {
            words = words.dropFirst(2)
        } else {
            guard let verb = words.first, ["start", "open", "begin", "create"].contains(verb) else { return nil }
            words = words.dropFirst()
            while let first = words.first, ["a", "an", "the", "new", "another", "fresh"].contains(first) {
                words = words.dropFirst()
            }
            guard words.first == "job" else { return nil }
            words = words.dropFirst()
        }
        let references = jobReferences(in: text)
        guard references.count <= 1 else { return nil }
        let reference = references.first
        for word in words {
            if ["for", "on", "at", "with"].contains(word) { break }
            guard commandFiller.contains(word) || ["number", "no", "ref", "reference"].contains(word)
                    || word == reference?.lowercased() else { return nil }
        }
        for clause in command.trailing where !isAside(clause) {
            guard let reference, isReferenceClause(clause, reference: reference) else { return nil }
        }
        var arguments = ["action": "start"]
        if let reference { arguments["job_reference"] = reference }
        return arguments
    }

    /// "The work order number is 2231", "Job number 1005", "Set the work order to 2231", "It's work
    /// order 2231": the whole clause, the number as said. "was" is not among the links: a number
    /// said in the past tense is about another job.
    static func statedJobReference(_ command: Command, text: String) -> String? {
        let clause = command.words.joined(separator: " ")
        let range = NSRange(clause.startIndex..., in: clause)
        guard let match = referenceClausePattern.firstMatch(in: clause, range: range),
              let said = Range(match.range(at: 1), in: clause).map({ String(clause[$0]) }),
              command.trailing.allSatisfy({ isAside($0) }) else { return nil }
        let references = jobReferences(in: text)
        guard references.count == 1, let reference = references.first, reference.lowercased() == said else { return nil }
        return reference
    }

    private static let referenceNoun = #"(?:work order(?: (?:number|no|ref|reference))?|job (?:number|no|ref|reference)|"#
        + #"reference number|wo(?: number)?)(?:'s)?"#

    private static let referenceClausePattern = try! NSRegularExpression(pattern:
        #"^(?:(?:set|change|update|correct|record|make|put) )?(?:(?:it's|its|the|my|our|this) )?"# + referenceNoun
        + #"(?: (?:is|to|as|should be|it's|its))?(?: number)? ([a-z]{0,4}-?\d[a-z0-9-]*)(?: (?:please|thanks|now|actually|mate))*$"#)

    /// Whether a later clause only gives the job's number ("work order 2231").
    static func isReferenceClause(_ clause: [String], reference: String) -> Bool {
        let joined = clause.joined(separator: " ")
        guard let match = referenceClausePattern.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)),
              let said = Range(match.range(at: 1), in: joined) else { return false }
        return String(joined[said]) == reference.lowercased()
    }

    /// Every job or work-order number `text` gives after "job", "job number", "work order"…, as
    /// written. A number holds a digit; letters before it are kept ("WO-2231").
    static func jobReferences(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return Array(Set(jobReferencePattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }))
    }

    private static let jobReferencePattern = try! NSRegularExpression(pattern:
        #"(?i)(?<![\w-])(?:job|work\s+order|wo)(?:\s+(?:number|no\.?|ref(?:erence)?))?(?:'s)?(?:\s*(?:is|to|as|=|:|#))?"#
        + #"\s*#?\s*([A-Za-z]{0,4}-?\d[\w-]*)(?![\w-])"#)

    /// "Pause the job", "Pause the job, I'm going for lunch", "Put the job on hold".
    static func isJobPause(_ command: Command) -> Bool {
        var words = ArraySlice(command.words)
        if words.first == "pause" {
            words = words.dropFirst()
            if let first = words.first, jobDeterminers.contains(first) { words = words.dropFirst() }
            guard words.first == "job" else { return false }
            words = words.dropFirst()
            // "for lunch": the reason, said.
            if words.first != "for", !words.allSatisfy(commandFiller.contains) { return false }
        } else {
            guard Array(words.prefix(4)) == ["put", "the", "job", "on"] || Array(words.prefix(4)) == ["put", "this", "job", "on"],
                  words.dropFirst(4).first == "hold", words.dropFirst(5).allSatisfy(commandFiller.contains) else { return false }
        }
        return command.trailing.allSatisfy { isAside($0) }
    }

    /// Words that may stand between "the" and "job" in a resume ("back on the furnace job"): what
    /// it is on, never which job ("the other job", "the Smith job" may be another).
    static let resumedJobWords: Set<String> = [
        "furnace", "boiler", "unit", "heater", "heating", "cooling", "condenser", "ac", "aircon", "hvac", "system",
        "appliance", "same", "current",
    ]

    /// "Resume the job", "Right, back on the furnace job", "I'm back on the job", "Carry on with the job".
    static func isJobResume(_ command: Command) -> Bool {
        var words = ArraySlice(command.words)
        if let first = words.first, ["i'm", "im", "we're"].contains(first) { words = words.dropFirst() }
        if let first = words.first, ["resume", "unpause", "continue"].contains(first) {
            words = words.dropFirst()
            if first == "continue", words.first == "with" { words = words.dropFirst() }
        } else if words.first == "back", let to = words.dropFirst().first, ["on", "to", "at", "onto"].contains(to) {
            words = words.dropFirst(2)
        } else if Array(words.prefix(3)) == ["carry", "on", "with"] {
            words = words.dropFirst(3)
        } else {
            return false
        }
        if let first = words.first, jobDeterminers.contains(first) { words = words.dropFirst() }
        var named = 0
        while let first = words.first, resumedJobWords.contains(first) { words = words.dropFirst(); named += 1 }
        guard named <= 2, words.first == "job", words.dropFirst().allSatisfy(commandFiller.contains) else { return false }
        return command.trailing.allSatisfy { isAside($0) }
    }

    /// "Close the job", "That's it, close the job", "End this job", "Wrap up the job". A later
    /// clause asking for the report too is the model's: the close's result offers it.
    static func isJobEnd(_ command: Command) -> Bool {
        var words = ArraySlice(command.words)
        if let first = words.first, ["close", "end"].contains(first) {
            words = words.dropFirst()
            if let next = words.first, ["out", "off"].contains(next) { words = words.dropFirst() }
        } else if Array(words.prefix(2)) == ["wrap", "up"] {
            words = words.dropFirst(2)
        } else if words.first == "wrap", words.count >= 4, words[words.startIndex + 3] == "up" {
            words = words.dropFirst()
            words = ArraySlice(Array(words.prefix(2)) + Array(words.dropFirst(3)))
        } else {
            return false
        }
        if let first = words.first, jobDeterminers.contains(first) { words = words.dropFirst() }
        guard words.first == "job" else { return false }
        words = words.dropFirst()
        if let next = words.first, ["up", "off", "out", "down"].contains(next) { words = words.dropFirst() }
        guard words.allSatisfy(commandFiller.contains) else { return false }
        return command.trailing.allSatisfy { isAside($0) }
    }

    private static let unitNouns: Set<String> = [
        "unit", "furnace", "boiler", "machine", "condenser", "system", "appliance", "heater", "ahu", "rtu",
    ]
    private static let unitOrdinals: Set<String> = ["next", "second", "third", "fourth", "fifth", "other", "another"]
    /// The moves to another unit: "moving on to", "on to", "now"…
    private static let unitMoves: [[String]] = [
        ["moving", "on", "to"], ["move", "on", "to"], ["moving", "onto"], ["move", "onto"], ["moving", "to"],
        ["move", "to"], ["now", "on", "to"], ["now", "onto"], ["on", "to"], ["onto"], ["over", "to"],
        ["starting", "on"], ["start", "on"], ["now"],
    ]
    /// Words that make what follows the unit a statement about it ("the next furnace is in the loft").
    private static let unitStatementWords: Set<String> = [
        "is", "was", "has", "had", "have", "needs", "need", "looks", "seems", "isn't", "wasn't", "doesn't", "will",
        "can't", "can", "could", "did", "does", "do", "also", "too", "same", "like", "as",
    ]

    /// "Moving on to the second furnace in the plant room", "Next unit", "Now the other boiler,
    /// it's a 090XV36C". Without a move in front, only "next" names one ("the second furnace" alone
    /// is a statement about it). `unit` is passed only when the turn names exactly one model.
    static func nextUnit(_ command: Command, text: String) -> [String: String]? {
        var words = ArraySlice(command.words)
        if let first = words.first, ["i'm", "im", "we're"].contains(first) { words = words.dropFirst() }
        let move = unitMoves.first { words.starts(with: $0) }
        if let move { words = words.dropFirst(move.count) }
        if words.first == "the" { words = words.dropFirst() }
        guard let ordinal = words.first, unitOrdinals.contains(ordinal), move != nil || ordinal == "next",
              let noun = words.dropFirst().first, unitNouns.contains(noun) else { return nil }
        let rest = Array(words.dropFirst(2)) + command.trailing.flatMap { $0 }
        guard !command.question, !rest.contains(where: unitStatementWords.contains),
              command.trailing.allSatisfy({ isAside($0) }) else { return nil }
        var arguments = ["action": "next_unit"]
        let models = Set(modelNumbers(in: text))
        if models.count == 1, let model = models.first { arguments["unit"] = model }
        return arguments
    }

    /// "How long have I been on this job?", "What's the job status?", "How much time is on this
    /// job?": the whole turn, openers aside.
    static func jobStatusAsked(_ text: String) -> Bool {
        var words = ArraySlice(normalised(text).split(separator: " ").map(String.init))
        while let first = words.first, commandOpeners.contains(first) || clauseOpeners.contains(first) {
            words = words.dropFirst()
        }
        let phrase = words.joined(separator: " ")
        return jobStatusPattern.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)) != nil
    }

    private static let jobStatusPattern = try! NSRegularExpression(pattern:
        #"^(?:how long (?:have|'ve) (?:i|we) been (?:on|at|doing|working on) (?:this|the) job"#
        + #"|how long (?:has|is) (?:this|the) job been (?:going|running|open|on)(?: for)?"#
        + #"|how long (?:has|have) (?:i|we) (?:spent|had) on (?:this|the) job"#
        + #"|(?:what's|whats|what is) the (?:job status|status of (?:this|the) job)"#
        + #"|(?:give me|tell me) the (?:job status|status of (?:this|the) job)"#
        + #"|job status|status of (?:this|the) job"#
        + #"|how much time (?:is|has gone|have i (?:spent|done|put in)|have we (?:spent|done|put in)) on (?:this|the) job"#
        + #"|(?:what's|whats|what is) the time on (?:this|the) job)"#
        + #"(?: so far| now| then| please| today)*$"#)

    // MARK: - Evidence

    private static let mediaNouns: Set<String> = [
        "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "clip", "clips", "video", "videos",
        "shot", "shots",
    ]
    /// Words between the verb and the photo that make it a new one, not one of the job's ("keep
    /// taking photos", "keep a photo of this").
    private static let newMediaWords: Set<String> = [
        "a", "an", "taking", "take", "snap", "snapping", "getting", "get", "shooting", "shoot", "more", "another",
    ]

    /// The `evidence` action an imperative about the job's photos gives, or nil: "Keep the photo of
    /// the gas valve label" (keep), "Exclude the blurry photo of the inducer", "Leave that photo
    /// out", "Don't include the photo" (exclude), "Include that photo", "Put the last picture back"
    /// (include), with "all" or "every" before the photo the action on all of them. The tool's own
    /// default item (the latest) is left to it: a photo is described, never given by id.
    static func evidenceChoice(_ text: String) -> String? {
        guard let command = readCommand(text), command.isImperative else { return nil }
        let words = command.words
        var action: String
        var start = 1
        switch words.first ?? "" {
        case "keep": action = "keep"
        case "exclude", "drop", "remove", "omit": action = "exclude"
        case "leave": action = "exclude"
        case "include": action = "include"
        case "put", "add": action = "include"
        case "don't", "dont":
            guard words.count > 1, ["include", "send", "use", "attach"].contains(words[1]) else { return nil }
            action = "exclude"
            start = 2
        default: return nil
        }
        // The negation that is the exclusion ("don't include") is not a denial; any other is.
        guard !defers(Array(command.allWords.dropFirst(start == 2 ? 1 : 0)), text: text) else { return nil }
        if words.first == "leave", !words.contains("out") { return nil }
        if ["put", "add"].contains(words.first ?? ""), !words.contains("back") { return nil }
        if ["keep", "include"].contains(words.first ?? ""), words.contains("out") { return nil }
        if words.first == "leave", words.dropFirst().first == "out" { start = 2 }
        guard let noun = words.indices.first(where: { $0 >= start && mediaNouns.contains(words[$0]) }) else { return nil }
        let between = words[start..<noun]
        guard between.count <= 5, !between.contains(where: newMediaWords.contains) else { return nil }
        let rest = Array(words[(noun + 1)...])
        let allowed: Set<String> = mediaNouns.union(["back", "out"])
        guard isAside(rest, allowing: allowed), command.trailing.allSatisfy({ isAside($0, allowing: mediaNouns) }) else {
            return nil
        }
        if action != "keep", between.contains(where: ["all", "every", "any"].contains) { action += "_all" }
        return action
    }

    // MARK: - A reading's follow-up

    /// The `reading` call for "and the other one?" after "X reads A …, and B …. Log the first."
    /// and a reply that logged A, or nil. Only when the turn is the follow-up alone, the last
    /// user message gave exactly two different values with the second introduced as another of
    /// the same ("and B", ", B": "and return air 72" is another quantity), what was said after it
    /// logged exactly one of them, and the quantity can be stated. The quantity and unit are the
    /// first's: from the earlier `reading` call when the history carries it, else the words before
    /// the first value and the unit said with a value, or the one the reply logged it in.
    static func readingFollowUp(_ text: String, history: [LocalToolLoop.Message]) -> [String: String]? {
        guard isOtherOneFollowUp(text),
              let userIndex = history.lastIndex(where: { $0.role == .user }), userIndex < history.count - 1 else { return nil }
        let stated = history[userIndex].content
        let values = statedValues(in: stated)
        guard values.count == 2, let firstNumber = Double(values[0].text), let secondNumber = Double(values[1].text),
              firstNumber != secondNumber else { return nil }
        let beforeSecond = stated[..<values[1].range.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
        guard beforeSecond.hasSuffix(",") || [" and", " then", "&"].contains(where: beforeSecond.hasSuffix) else { return nil }

        var logged: Set<Int> = []
        var earlierCall: [String: Any]?
        for message in history[(userIndex + 1)...] {
            switch message.role {
            case .tool:
                guard message.toolName == "reading", message.content.hasPrefix("Recorded") else { continue }
                logged.formUnion(indices(of: values, in: message.content))
            case .assistant:
                if message.toolName == "reading", let canonical = message.toolArguments,
                   let data = canonical.data(using: .utf8),
                   let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    earlierCall = arguments
                } else if saysLogged(message.content) {
                    logged.formUnion(indices(of: values, in: message.content))
                }
            case .user:
                return nil
            }
        }
        guard logged.count == 1, let first = logged.first else { return nil }
        let other = 1 - first
        if let earlierCall {
            let callValue = (earlierCall["value"] as? String) ?? (earlierCall["value"] as? NSNumber)?.stringValue
            guard let callValue, Double(callValue) == Double(values[first].text) else { return nil }
        }

        let units = values.map { unit(after: $0.range.upperBound, in: stated) }
        if let a = units[0], let b = units[1], a.lowercased() != b.lowercased() { return nil }
        let calledQuantity = (earlierCall?["quantity"] as? String)?.trimmingCharacters(in: .whitespaces)
        guard let quantity = calledQuantity.flatMap({ $0.isEmpty ? nil : $0 })
                ?? quantitySaid(before: values[0].range.lowerBound, in: stated) else { return nil }
        let calledUnit = (earlierCall?["unit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var arguments = ["action": "record_reading", "quantity": quantity, "value": values[other].text]
        if let unit = calledUnit ?? units[other] ?? units[first] ?? loggedUnit(of: values[first].text, history[(userIndex + 1)...]) {
            arguments["unit"] = unit
        }
        return arguments
    }

    /// The `reading` call for a turn that logs one value and says what it was: "Log <what> at
    /// <value> [unit] [qualifier]" (the command first, after "OK", "right"…), or "<what> reads
    /// <value> [unit], log it" (the command last, alone in its clause). Nil for anything else:
    /// no number or more than one, nothing said of what was measured, a turn that defers, denies
    /// or conditions, asks a question, or asks another tool for something too. A qualifier said
    /// after the value ("7 inches natural", "0.6 on low fire") joins the quantity, or is the
    /// quantity when nothing was said before the value.
    static func loggedReading(_ text: String) -> [String: String]? {
        guard !text.contains("?") else { return nil }
        let values = statedValues(in: text)
        guard values.count == 1, let value = values.first else { return nil }
        let words = normalised(text).split(separator: " ").map(String.init)
        guard !defers(words, text: text) else { return nil }

        var leading = ArraySlice(words)
        while let first = leading.first, logOpeners.contains(first) { leading = leading.dropFirst() }
        let commandFirst = leading.first.map(logVerbs.contains) ?? false

        let unit = unit(after: value.range.upperBound, in: text)
        var rest = String(text[value.range.upperBound...])
        if let unit, let said = rest.range(of: unit) { rest = String(rest[said.upperBound...]) }
        var restClauses = clauseWords(rest)
        let qualifierFollows = rest.first(where: { !$0.isWhitespace }).map { $0.isLetter } ?? false
        var qualifier: [String] = []
        if qualifierFollows, let first = restClauses.first {
            qualifier = first
            restClauses.removeFirst()
            while let word = qualifier.first, qualifierLinks.contains(word) { qualifier.removeFirst() }
            guard !qualifier.isEmpty, qualifier.count <= 4,
                  qualifier.allSatisfy({ !otherRequests.contains($0) && !logVerbs.contains($0) }) else { return nil }
        }

        if commandFirst {
            let before = clauseWords(String(text[..<value.range.lowerBound])).flatMap { $0 }
            guard before.filter(logVerbs.contains).count == 1, before.allSatisfy({ !otherRequests.contains($0) || logVerbs.contains($0) }),
                  restClauses.allSatisfy({ isAside($0) }) else { return nil }
        } else {
            // The command last, alone: "…, log it".
            guard let last = restClauses.last, isLogItClause(last) else { return nil }
            restClauses.removeLast()
            let before = clauseWords(String(text[..<value.range.lowerBound])).flatMap { $0 }
            guard restClauses.isEmpty, before.allSatisfy({ !otherRequests.contains($0) }),
                  let opener = before.first, !requestOpeners.contains(opener) else { return nil }
        }
        guard !asksAnotherTool(rest.replacingOccurrences(of: "log", with: "", options: .caseInsensitive)
                                .replacingOccurrences(of: "record", with: "", options: .caseInsensitive)) else { return nil }

        // The command first is one sentence, whatever its full stops ("in. w.c."); the command
        // last follows what was measured in its own sentence.
        let saidBefore = quantitySaid(before: value.range.lowerBound, in: text, maxWords: 14, cuttingSentences: !commandFirst)
        let qualifierText = qualifier.joined(separator: " ")
        let quantity: String
        switch (saidBefore, qualifierText.isEmpty) {
        case (let said?, true): quantity = said
        case (let said?, false): quantity = said + ", " + qualifierText
        case (nil, false): quantity = qualifierText
        case (nil, true): return nil
        }
        var arguments = ["action": "record_reading", "quantity": quantity, "value": value.text]
        if let unit { arguments["unit"] = unit }
        return arguments
    }

    /// The reading and the voltage drop of "<what> is <value>. Log it, then work out the voltage
    /// drop at <current> amps over <length> feet …", or nil. The part before "then" must route as
    /// `loggedReading`; the part after it must ask for a voltage drop (`voltageDropAsks`), say one
    /// current and one length with their units, and defer nothing.
    static func loggedReadingThenVoltageDrop(_ text: String) -> (reading: [String: String], voltageDrop: [String: String])? {
        guard !text.contains("?"),
              let split = thenPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(split.range, in: text) else { return nil }
        let head = String(text[..<range.lowerBound]), tail = String(text[range.upperBound...])
        guard let reading = loggedReading(head) else { return nil }
        let words = normalised(tail).split(separator: " ").map(String.init)
        guard !defers(words, text: tail), voltageDropAsks(words),
              let current = onlyMatch(currentPattern, in: tail) else { return nil }
        // Every number after "then" is the current, the length or the wire's size: "15 or 20 amps"
        // is not one current.
        let sizes = wireSizePattern.numberOfMatches(in: tail, range: NSRange(tail.startIndex..., in: tail))
        guard statedValues(in: tail).count == 2 + sizes else { return nil }
        var arguments = ["operation": "voltage_drop", "current_a": current]
        let feet = onlyMatch(feetPattern, in: tail), metres = onlyMatch(metresPattern, in: tail)
        switch (feet, metres) {
        case (let ft?, nil): arguments["length_ft"] = ft
        case (nil, let m?): arguments["length_m"] = m
        default: return nil
        }
        return (reading, arguments)
    }

    /// "work out the voltage drop", "calculate the voltage drop", "figure out the drop", "what's
    /// the voltage drop" at the front of the clause.
    static func voltageDropAsks(_ words: [String]) -> Bool {
        var rest = ArraySlice(words)
        while let first = rest.first, logOpeners.contains(first) { rest = rest.dropFirst() }
        let joined = rest.joined(separator: " ")
        guard ["work out ", "calculate ", "figure out ", "what's ", "whats ", "give me ", "check "]
                .contains(where: joined.hasPrefix) else { return false }
        return joined.contains("voltage drop") || joined.contains(" the drop")
    }

    private static let thenPattern = try! NSRegularExpression(pattern: #"(?i)[,;.]?\s*(?:and\s+)?\bthen\b\s*"#)
    private static let currentPattern = try! NSRegularExpression(pattern: #"(?i)(?<![\w.])(\d+(?:\.\d+)?)\s*(?:amps?|amperes?|a)\b"#)
    private static let feetPattern = try! NSRegularExpression(pattern: #"(?i)(?<![\w.])(\d+(?:\.\d+)?)\s*(?:feet|foot|ft)\b"#)
    private static let wireSizePattern = try! NSRegularExpression(pattern:
        #"(?i)(?<![\w.])\d+(?:\.\d+)?\s*(?:gauge|awg|ga|mm²|mm2|mm|sq|square)\b|(?:#|number\s+)\d+\b"#)
    private static let metresPattern = try! NSRegularExpression(pattern: #"(?i)(?<![\w.])(\d+(?:\.\d+)?)\s*(?:metres?|meters?|m)\b(?!\s*m)"#)

    /// The number of `pattern`'s one match in `text`, or nil for none or more than one.
    private static func onlyMatch(_ pattern: NSRegularExpression, in text: String) -> String? {
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static let logVerbs: Set<String> = ["log", "record"]
    private static let logOpeners: Set<String> = ["ok", "okay", "right", "so", "now", "and", "alright", "please", "then", "um"]
    private static let qualifierLinks: Set<String> = ["on", "at", "for", "in", "with"]

    /// "log it", "log that", "record it please", "log" — the whole clause.
    static func isLogItClause(_ clause: [String]) -> Bool {
        var words = ArraySlice(clause)
        while let first = words.first, logOpeners.contains(first) { words = words.dropFirst() }
        while let last = words.last, ["please", "thanks", "mate", "now", "too"].contains(last) { words = words.dropLast() }
        guard let verb = words.first, logVerbs.contains(verb) else { return false }
        let object = Array(words.dropFirst())
        return object.isEmpty || [["it"], ["that"], ["this"], ["that", "one"], ["this", "one"], ["that", "reading"]].contains(object)
    }

    /// "and the other one?", "the second one", "log the other", "the rest" — the whole turn, with
    /// no number in it.
    static func isOtherOneFollowUp(_ text: String) -> Bool {
        guard !text.contains(where: \.isNumber) else { return false }
        var words = ArraySlice(normalised(text).split(separator: " ").map(String.init))
        while let first = words.first, ["and", "now", "ok", "okay", "right", "so", "then", "yeah", "cool", "great", "also"]
            .contains(first) { words = words.dropFirst() }
        if Array(words.suffix(2)) == ["as", "well"] { words = words.dropLast(2) }
        while let last = words.last, ["please", "too", "then", "now", "thanks", "mate", "also"].contains(last) {
            words = words.dropLast()
        }
        if let first = words.first, ["log", "record"].contains(first) { words = words.dropFirst() }
        return otherOnePhrases.contains(words.joined(separator: " "))
    }

    static let otherOnePhrases: Set<String> = [
        "the other one", "the other", "other one", "the other reading", "the other value", "the other number",
        "the second one", "the second", "the second reading", "the second value", "the rest",
    ]

    /// Plain numbers in `text`, in order, as written: not a code's or a model's digits ("E223",
    /// "090XV60C"), a fraction or a date.
    static func statedValues(in text: String) -> [(text: String, range: Range<String.Index>)] {
        valuePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { (text: String(text[$0]), range: $0) }
        }
    }

    private static let valuePattern = try! NSRegularExpression(pattern: #"(?<![\w./-])(\d+(?:\.\d+)?|\.\d+)(?![\w/]|\.\d)"#)

    /// Which of `values` `text` names, by number.
    private static func indices(of values: [(text: String, range: Range<String.Index>)], in text: String) -> Set<Int> {
        let named = Set(statedValues(in: text).compactMap { Double($0.text) })
        return Set(values.indices.filter { Double(values[$0].text).map(named.contains) ?? false })
    }

    /// A reply that says a reading went on the record.
    static func saysLogged(_ reply: String) -> Bool {
        let words = Set(normalised(reply).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["logged", "recorded"])
            && words.isDisjoint(with: ["not", "couldn't", "didn't", "can't", "cannot", "won't", "unable"])
    }

    /// The unit said straight after a value, as written, or nil.
    static func unit(after index: String.Index, in text: String) -> String? {
        let rest = String(text[index...])
        guard let match = unitPattern.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let range = Range(match.range(at: 1), in: rest) else { return nil }
        return String(rest[range])
    }

    private static let unitPattern = try! NSRegularExpression(pattern:
        #"(?i)^\s*(in\.?\s?w\.?\s?c\.?|inches of water(?: column)?|inch(?:es)?|inwc|iwc|psig|psi|kpa|mbar|°\s?[fc]|degrees(?: [fc])?"#
        + #"|volts?|vac|v|millivolts?|mv|amps?|milliamps?|microamps?|µa|ohms?|Ω|hz|%|percent|cfm|rpm)(?![\w°])"#)

    /// The unit a reply or a `reading` result logged `value` in.
    private static func loggedUnit(of value: String, _ messages: ArraySlice<LocalToolLoop.Message>) -> String? {
        for message in messages.reversed() where message.role != .user {
            for said in statedValues(in: message.content) where Double(said.text) == Double(value) {
                if let unit = unit(after: said.range.upperBound, in: message.content) { return unit }
            }
        }
        return nil
    }

    /// What was measured: the words of the first value's sentence before it, without "reads",
    /// "is", "at" and the like at the end or "log" at the front ("Manifold, natural gas reads 0.68"
    /// → "Manifold, natural gas"). Nil when that leaves nothing, or more than `maxWords` words.
    static func quantitySaid(before index: String.Index, in text: String, maxWords: Int = 8,
                             cuttingSentences: Bool = true) -> String? {
        var sentence = String(text[..<index])
        if cuttingSentences, let cut = sentence.range(of: #"[.!?]\s"#, options: [.regularExpression, .backwards]) {
            sentence = String(sentence[cut.upperBound...])
        }
        var words = sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let trim = CharacterSet(charactersIn: ",:;=-")
        func bare(_ word: String) -> String { word.lowercased().trimmingCharacters(in: trim) }
        while let last = words.last, quantityLinks.contains(bare(last)) || bare(last).isEmpty { words.removeLast() }
        while let first = words.first, ["log", "record", "ok", "okay", "right", "so", "and", "then", "um"].contains(bare(first)) {
            words.removeFirst()
        }
        if let last = words.last, last.lowercased().hasSuffix("'s") { words[words.count - 1] = String(last.dropLast(2)) }
        let quantity = words.joined(separator: " ").trimmingCharacters(in: trim.union(.whitespaces))
        guard !quantity.isEmpty, words.count <= maxWords, quantity.contains(where: \.isLetter) else { return nil }
        return quantity
    }

    private static let quantityLinks: Set<String> = [
        "reads", "read", "reading", "is", "was", "at", "of", "measures", "measured", "shows", "showing", "came", "comes",
        "in", "to", "on", "were", "are",
    ]

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
            if line.hasPrefix("⚠️ SAFETY: ") || leadLines.contains(line) || line.hasPrefix("Started procedure ") {
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

    /// Lines before a step that are said: where the run now is. A start's own line ("Started
    /// procedure '…'.") is said too.
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
