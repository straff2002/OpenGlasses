import Foundation

/// What the wearer hears when a sentence trips the reply check (Plan NA §3). Pure.
///
/// | Action | Meaning |
/// |---|---|
/// | `replace(line)` | The sentence is not said; the line is said in its place. |
/// | `speakThenCorrect(line)` | The sentence is said, the line straight after it. |
/// | `stopAndCorrect(line)` | A live session: stop now, then the line. |
/// | `drop` | Not said, nothing in its place. |
/// | `count` | Said unchanged; counted. |
///
/// A sentence that names a hazard is never withheld (decision 4): "kerb ahead, then it's clear"
/// withheld loses the kerb. One line per reply, and per loop session on the ambient loops: a
/// second trip is dropped, or said unchanged if it names a hazard.
enum BlindReplyGuard {

    enum Surface: String, CaseIterable, Sendable {
        /// A Direct turn's reply, streamed or whole.
        case direct
        /// Navigation assist's callouts.
        case navigation
        /// Assistive scene and social mode.
        case assistive
        /// Scene narration.
        case narration
        /// A live session (Gemini Live, OpenAI Realtime).
        case live

        var isAmbient: Bool { self == .navigation || self == .assistive || self == .narration }
    }

    enum Action: Equatable, Sendable {
        case replace(BlindReplyLine)
        case speakThenCorrect(BlindReplyLine)
        case stopAndCorrect(BlindReplyLine)
        case drop
        case count

        /// The case name, for the log and the tally.
        var token: String {
            switch self {
            case .replace: return "replaced"
            case .speakThenCorrect: return "corrected"
            case .stopAndCorrect: return "stopped"
            case .drop: return "dropped"
            case .count: return "counted"
            }
        }

        var line: BlindReplyLine? {
            switch self {
            case .replace(let line), .speakThenCorrect(let line), .stopAndCorrect(let line): return line
            case .drop, .count: return nil
            }
        }
    }

    /// `urgency`: an ambient loop's grading of the advice; nil elsewhere (and read as low on an
    /// ambient surface that has none, narration). `alreadyCorrected`: a line has already been said
    /// in this reply, or in this loop session on an ambient surface.
    static func decide(surface: Surface, findings: [BlindReplyCheck.Finding], namesHazard: Bool,
                       urgency: AssistiveAdvice.Urgency?, alreadyCorrected: Bool) -> Action {
        let acting = findings.filter(\.acts)
        guard !acting.isEmpty else { return .count }
        let line: BlindReplyLine = acting.contains { $0.flag != .ungroundedReadingNumber }
            ? .safety : .readingNumber
        if alreadyCorrected { return namesHazard ? .count : .drop }
        switch surface {
        case .direct:
            return namesHazard ? .speakThenCorrect(line) : .replace(line)
        case .live:
            // The hazard is already playing: let it finish, and correct at the turn's end.
            return namesHazard ? .speakThenCorrect(line) : .stopAndCorrect(line)
        case .navigation, .assistive, .narration:
            let level = urgency ?? .low
            if level == .low, !namesHazard { return .drop }
            return .speakThenCorrect(line)
        }
    }

    // MARK: - Hazards

    /// Words that name something the wearer must know about. Read unnegated: "no steps" names
    /// none. A miss costs an assurance followed by its correction; a hit can never cost a hazard.
    static let hazardWords: Set<String> = [
        "step", "steps", "stair", "stairs", "staircase", "stairway", "kerb", "kerbs", "curb", "curbs",
        "edge", "ledge", "drop", "drop-off", "dropoff", "hole", "holes", "pothole", "potholes",
        "car", "cars", "vehicle", "vehicles", "bike", "bikes", "bicycle", "bicycles", "cyclist",
        "cyclists", "scooter", "scooters", "motorbike", "motorcycle", "bus", "truck", "lorry",
        "van", "train", "tram", "traffic", "pole", "poles", "post", "bollard", "bollards",
        "barrier", "door", "doors", "wet", "slippery", "ice", "icy", "slope", "ramp", "gap",
        "platform", "obstacle", "obstruction", "branch", "branches", "puddle", "construction",
        "roadworks", "scaffolding", "dog", "glass", "hazard",
    ]

    static let hazardNegations = [" no ", " not ", "n't ", " without ", " free of ", " never ", " zero "]

    /// Whether the sentence names a hazard the wearer would lose if it were withheld.
    static func namesHazard(_ sentence: String) -> Bool {
        guard let regex = hazardPattern else { return false }
        let text = ReplyPhraseMechanics.normalised(sentence)
        return ReplyPhraseMechanics.matches(of: regex, in: text).contains { range in
            let before = ReplyPhraseMechanics.window(text, before: range, width: 24)
            return !hazardNegations.contains(where: before.contains)
        }
    }

    /// Whole words only: "car" is not in "scary".
    private static let hazardPattern: NSRegularExpression? = {
        let words = hazardWords.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        return try? NSRegularExpression(pattern: #"(?<![a-z])("# + words.joined(separator: "|") + #")(?![a-z])"#)
    }()
}

/// The two lines the app says when it withholds or stops a sentence (Plan NA decision 6). Short,
/// with no assurance in either direction, in the app's language. "Correction:" only live, where
/// the wearer may already have heard the start of what is corrected.
enum BlindReplyLine: String, CaseIterable, Sendable {
    case safety
    case readingNumber

    func text(live: Bool) -> String {
        switch (self, live) {
        case (.safety, false):
            return String(localized: "I can't tell from the camera whether it's safe. Check with your cane or guide dog, or ask someone nearby.",
                          comment: "Said in place of a sentence that told a blind wearer a way was safe or clear. Must not assure in either direction.")
        case (.safety, true):
            return String(localized: "Correction: I can't tell from the camera whether it's safe. Check with your cane or guide dog, or ask someone nearby.",
                          comment: "Said in the app's own voice after it stopped a live answer that told a blind wearer a way was safe or clear.")
        case (.readingNumber, false):
            return String(localized: "I couldn't read one of the numbers clearly, so I've left it out. Ask me to read it again with it held steady.",
                          comment: "Said in place of a sentence with a dose, date or amount the on-device reading did not show.")
        case (.readingNumber, true):
            return String(localized: "Correction: I couldn't confirm one of those numbers from the text I could read. Ask me to read it again with it held steady.",
                          comment: "Said in the app's own voice after it stopped a live answer with a number the on-device reading did not show.")
        }
    }

    /// What the live model is told at the turn's end, so its next answer does not repeat it. Sent
    /// to the model, never spoken; English, as the session's instructions are.
    var modelNote: String {
        switch self {
        case .safety:
            return "App note: the app stopped your last answer and told the user it cannot tell whether it is safe. Do not tell the user that moving or crossing is safe, or that a way is clear."
        case .readingNumber:
            return "App note: the app stopped your last answer and told the user it could not confirm one of its numbers from the text it read on the device. Do not state a dose, amount, date or time the captured text does not show; say which part you cannot read."
        }
    }
}

/// One reply's sentences through the check and the guard, in order (Plan NA §4).
///
/// The same function screens a streamed sentence and the final reply, so the two agree exactly and
/// `StreamSpeechGate.reconcile(reply:spoken:)` finds what was streamed in the final reply
/// unchanged: what was heard is what is shown. Holds the reply so far (for its language and to
/// know its first sentence) and whether a line has been said. Pure.
struct BlindReplyScreen: Sendable {

    /// What the check may run on for this reply.
    struct Scope: Equatable, Sendable {
        /// The phrase tables: Blind Assistant selected, or an assistive loop.
        var phrases: Bool
        /// The reading-number check, whenever the turn has reading evidence.
        var numbers: Bool

        static let off = Scope(phrases: false, numbers: false)
        var isOff: Bool { !phrases && !numbers }
    }

    /// One sentence, screened.
    struct Screened: Equatable, Sendable {
        let sentence: String
        let result: BlindReplyCheck.Result
        let action: BlindReplyGuard.Action
        /// What is said in the sentence's place, in order: the sentence, the line, both, or neither.
        let output: [String]
    }

    let surface: BlindReplyGuard.Surface
    let scope: Scope
    var question: String?
    let appLanguageIsEnglish: Bool
    /// A line has been said in this reply (or loop session).
    var alreadyCorrected: Bool
    private(set) var replySoFar = ""
    private(set) var screened: [Screened] = []

    init(surface: BlindReplyGuard.Surface, scope: Scope, question: String? = nil,
         appLanguageIsEnglish: Bool = true, alreadyCorrected: Bool = false) {
        self.surface = surface
        self.scope = scope
        self.question = question
        self.appLanguageIsEnglish = appLanguageIsEnglish
        self.alreadyCorrected = alreadyCorrected
    }

    /// Screen the next sentence of the reply.
    mutating func screen(_ sentence: String, evidence: ReadingEvidence?,
                         urgency: AssistiveAdvice.Urgency? = nil) -> Screened {
        let input = BlindReplyCheck.Input(
            sentence: sentence, replyBefore: replySoFar, question: question,
            evidence: scope.numbers ? evidence : nil, checkPhrases: scope.phrases,
            appLanguageIsEnglish: appLanguageIsEnglish)
        let result = scope.isOff
            ? BlindReplyCheck.Result(findings: [], language: .outOfScope)
            : BlindReplyCheck.check(input)
        let action = BlindReplyGuard.decide(
            surface: surface, findings: result.findings,
            namesHazard: result.acts && BlindReplyGuard.namesHazard(sentence),
            urgency: urgency, alreadyCorrected: alreadyCorrected)
        let live = surface == .live
        let output: [String]
        switch action {
        case .replace(let line): output = [line.text(live: live)]
        case .speakThenCorrect(let line):
            // Live, the sentence is already the provider's audio; the line follows at the turn's end.
            output = live ? [sentence] : [sentence, line.text(live: live)]
        case .stopAndCorrect(let line): output = [line.text(live: live)]
        case .drop: output = []
        case .count: output = [sentence]
        }
        if action.line != nil { alreadyCorrected = true }
        replySoFar = replySoFar.isEmpty ? sentence : replySoFar + " " + sentence
        let item = Screened(sentence: sentence, result: result, action: action, output: output)
        screened.append(item)
        return item
    }

    /// Whether any sentence so far tripped something that acts.
    var tripped: Bool { screened.contains { $0.result.acts } }

    /// Whether this reply went unchecked by the phrase tables because of its language.
    var languageSkipped: Bool { screened.contains { $0.result.language == .notEnglish } }

    // MARK: - A whole reply

    struct WholeReply: Equatable, Sendable {
        /// The reply with every sentence screened, joined as the stream would say it.
        let text: String
        let screened: [Screened]

        /// Each sentence whose output differs from it, with what replaced it, in order. Used to
        /// rewrite the reply in the model's history so its next turn sees what was heard.
        var replacements: [(original: String, replacement: String)] {
            screened.compactMap { item in
                item.output == [item.sentence] ? nil : (item.sentence, item.output.joined(separator: " "))
            }
        }

        var changed: Bool { screened.contains { $0.output != [$0.sentence] } }

        static func == (lhs: WholeReply, rhs: WholeReply) -> Bool {
            lhs.text == rhs.text && lhs.screened == rhs.screened
        }
    }

    /// Screen a finished reply sentence by sentence, split as the stream splits it
    /// (`SentenceStreamSplitter`). A reply with nothing to change comes back byte for byte.
    static func screenWhole(_ reply: String, surface: BlindReplyGuard.Surface, scope: Scope,
                            question: String?, evidence: ReadingEvidence?,
                            appLanguageIsEnglish: Bool,
                            urgency: AssistiveAdvice.Urgency? = nil,
                            alreadyCorrected: Bool = false) -> WholeReply {
        guard !scope.isOff else { return WholeReply(text: reply, screened: []) }
        var splitter = SentenceStreamSplitter()
        let sentences = splitter.ingest(reply) + splitter.flush()
        var screen = BlindReplyScreen(surface: surface, scope: scope, question: question,
                                      appLanguageIsEnglish: appLanguageIsEnglish,
                                      alreadyCorrected: alreadyCorrected)
        for sentence in sentences { _ = screen.screen(sentence, evidence: evidence, urgency: urgency) }
        let items = screen.screened
        guard items.contains(where: { $0.output != [$0.sentence] }) else {
            return WholeReply(text: reply, screened: items)
        }
        return WholeReply(text: replacingInPlace(reply, items) ?? items.flatMap(\.output).joined(separator: " "),
                          screened: items)
    }

    /// The reply with each changed sentence replaced where it stands, so line breaks and list
    /// layout around it survive. The splitter only trims a sentence, so each is found verbatim;
    /// nil if one is not (the caller then joins the outputs).
    private static func replacingInPlace(_ reply: String, _ items: [Screened]) -> String? {
        var result = ""
        var cursor = reply.startIndex
        for item in items {
            guard let range = reply.range(of: item.sentence, range: cursor..<reply.endIndex) else { return nil }
            result += reply[cursor..<range.lowerBound]
            result += item.output.joined(separator: " ")
            cursor = range.upperBound
        }
        result += reply[cursor...]
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Scope (decision 8)

extension BlindReplyScreen.Scope {

    /// A Direct turn's or a live session's scope. The phrase tables run while the Blind Assistant
    /// preset is selected, the app's only signal that the wearer cannot see; the reading-number
    /// check whenever the turn has reading evidence. Never the spoken interpreter, whose words are
    /// the other person's as often as the wearer's. Nothing with the kill switch off.
    static func forTurn(activeModeId: String, enabled: Bool) -> Self {
        guard enabled, activeModeId != LiveAIMode.interpreterID else { return .off }
        return Self(phrases: activeModeId == BlindAssistanceContract.presetID, numbers: true)
    }

    /// Navigation, assistive scene/social and narration always carry the contract, whatever is
    /// selected. They read no text, so there is no number check.
    static func ambient(enabled: Bool) -> Self {
        enabled ? Self(phrases: true, numbers: false) : .off
    }
}

extension BlindReplyScreen {
    /// The app's language is English: the fallback until a reply holds enough letters to detect.
    static var appLanguageIsEnglish: Bool {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("en")
    }

    /// Screen one ambient callout (navigation, assistive, narration) under the loop session's
    /// one-line latch. Returns what is said — empty text when the callout is dropped; the caller
    /// records it (`BlindReplyCheckRecorder`). `alreadyCorrected` is the loop session's latch, set once its line has been said.
    static func screenAmbient(_ text: String, surface: BlindReplyGuard.Surface,
                              urgency: AssistiveAdvice.Urgency?, enabled: Bool,
                              alreadyCorrected: inout Bool,
                              appLanguageIsEnglish: Bool) -> WholeReply {
        let whole = screenWhole(text, surface: surface, scope: .ambient(enabled: enabled),
                                question: nil, evidence: nil,
                                appLanguageIsEnglish: appLanguageIsEnglish,
                                urgency: urgency, alreadyCorrected: alreadyCorrected)
        if whole.screened.contains(where: { $0.action.line != nil }) { alreadyCorrected = true }
        return whole
    }
}
