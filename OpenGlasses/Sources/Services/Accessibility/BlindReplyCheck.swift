import Foundation
import NaturalLanguage

/// Checks one sentence of a real reply against what the blind-assistance contract forbids, before
/// the app says it or while it is being said (Plan NA §1).
///
/// The offline answer audit (`BlindAssistanceResponseAudit`) runs over hand-written transcripts,
/// where a false positive costs nothing. Here one costs a blind wearer a sentence, so the tables
/// are narrower and scoped to movement: "safe to cross", not "safe to eat"; "the path is clear",
/// not "there is nothing written on the back". The mechanics are the audit's, shared through
/// `ReplyPhraseMechanics`.
///
/// What it finds:
///
/// | Flag | Runs on | Acts? |
/// |---|---|---|
/// | `assertedSafety` | English sentences, and an English reply opening "yes" to a safety question | Yes |
/// | `assertedAbsenceOfHazard` | English sentences, and an English reply opening "no" to "is anything in my way" | Yes |
/// | `ungroundedReadingNumber` | A turn with on-device reading text, any language | Yes |
/// | `visualAssumption` | English sentences | Counted only |
///
/// A finding that does not act carries its `Exemption`: `negated` (a refusal to assure, "I can't
/// tell whether it's safe to cross"), `quoted` (the wearer's sign or label read faithfully).
/// A reply not in English is not phrase-checked at all (`Result.language`); its digits still are.
///
/// It is a smoke detector, not a certification. A clean result means only that nothing this
/// checker recognises went wrong; nothing the app says may claim more. Pure and deterministic.
enum BlindReplyCheck {

    // MARK: - Results

    enum Flag: String, CaseIterable, Sendable {
        /// Told the wearer that moving, crossing or proceeding is safe — in words, or by answering
        /// "yes" to a safety question.
        case assertedSafety
        /// Told the wearer a way is clear or a hazard absent — in words, or by answering "no" to
        /// "is anything in my way".
        case assertedAbsenceOfHazard
        /// A dose, amount, date or time on a reading turn that the on-device text does not show.
        case ungroundedReadingNumber
        /// Phrasing that assumes the wearer can see. Counted, never acted on.
        case visualAssumption

        /// Whether a finding of this flag can withhold or stop a sentence.
        var acts: Bool { self != .visualAssumption }
    }

    enum Exemption: String, CaseIterable, Sendable {
        /// A refusal to assure: the phrase follows a negation, or "if"/"whether" after a verb of
        /// not knowing or asking.
        case negated
        /// The phrase is in quotation marks, or in a clause reading out a sign or a label.
        case quoted
        /// The reply is not in English, so the phrase tables were not run.
        case notEnglish
    }

    /// Whether a match came from a phrase, or from a one-word answer to the wearer's question.
    enum Basis: String, Sendable {
        case phrase
        case answeredQuestion
        case reading
    }

    struct Finding: Equatable, Sendable {
        let flag: Flag
        let basis: Basis
        /// Why this finding does not act, or nil when it acts (or is counted only).
        let exemption: Exemption?

        /// Whether this finding withholds or stops the sentence.
        var acts: Bool { exemption == nil && flag.acts }
    }

    enum Language: String, Sendable {
        /// Phrase-checked.
        case english
        /// Not phrase-checked: the reply is in another language.
        case notEnglish
        /// Not phrase-checked: this turn is outside the phrase check's scope.
        case outOfScope
    }

    struct Result: Equatable, Sendable {
        var findings: [Finding]
        var language: Language

        var acting: [Finding] { findings.filter(\.acts) }
        var acts: Bool { findings.contains(where: \.acts) }
    }

    /// One sentence and everything the check may know about it.
    struct Input: Sendable {
        /// The sentence about to be said.
        var sentence: String
        /// The reply before this sentence, for the reply's language and to know whether this is
        /// its first sentence.
        var replyBefore: String = ""
        /// The wearer's question, when the turn knows it.
        var question: String?
        /// The turn's reading evidence, when there is any.
        var evidence: ReadingEvidence?
        /// Whether the phrase tables apply to this turn (Blind Assistant selected, or an
        /// assistive loop). The reading-number check runs whenever there is evidence.
        var checkPhrases: Bool = true
        /// The app's language is English: the reply's language until it holds enough letters to
        /// detect.
        var appLanguageIsEnglish: Bool = true
    }

    // MARK: - Entry point

    static func check(_ input: Input) -> Result {
        let reply = input.replyBefore.isEmpty ? input.sentence : input.replyBefore + " " + input.sentence
        let english = isEnglish(reply: reply, appLanguageIsEnglish: input.appLanguageIsEnglish)
        var findings: [Finding] = []
        let language: Language
        if !input.checkPhrases {
            language = .outOfScope
        } else if !english {
            language = .notEnglish
        } else {
            language = .english
            findings += phraseFindings(in: input.sentence)
            if input.replyBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let answered = answeredQuestion(input.question, with: input.sentence) {
                findings.append(Finding(flag: answered, basis: .answeredQuestion, exemption: nil))
            }
        }
        if let evidence = input.evidence,
           !ReadingQuantityReader.ungrounded(in: input.sentence, evidence: evidence,
                                             question: input.question, english: english).isEmpty {
            findings.append(Finding(flag: .ungroundedReadingNumber, basis: .reading, exemption: nil))
        }
        return Result(findings: findings, language: language)
    }

    // MARK: - Language

    /// Letters the reply must hold before its own language is trusted over the app's.
    static let languageDetectionMinimumLetters = 20

    /// Whether the reply's dominant language is English: detected once the reply holds
    /// `languageDetectionMinimumLetters` letters, the app's language before that.
    static func isEnglish(reply: String, appLanguageIsEnglish: Bool) -> Bool {
        guard reply.filter(\.isLetter).count >= languageDetectionMinimumLetters else {
            return appLanguageIsEnglish
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(reply)
        guard let dominant = recognizer.dominantLanguage else { return appLanguageIsEnglish }
        return dominant == .english
    }

    // MARK: - Phrase tables (runtime, movement-scoped)

    /// Saying any of these, unexempted, tells the wearer it is safe to move. "Safe to eat", "safe
    /// for children" and "you can go ahead and ask" are not here.
    static let safetySources = [
        #"\bsafe to (cross|proceed|go|walk|step|move|continue|turn)\b"#,
        // "It's safe" ending a clause, or followed by "now", "here" or "ahead".
        #"\b(it's|it is|its) (perfectly |completely |totally )?safe(?=\s*([.,;:!?]|$|now\b|here\b|ahead\b))"#,
        #"\byou can (cross|walk|step|proceed|carry on)\b"#,
        // "You can go ahead" ending a clause; "you can go ahead and ask" is not about moving.
        #"\byou can go ahead(?=\s*([.,;:!?]|$|now\b))"#,
        #"\bgo ahead and (cross|step|walk)\b"#,
        #"\b(you're|you are) (fine|good|safe|ok|okay) to (go|cross|walk)\b"#,
    ]

    /// Saying any of these, unexempted, asserts a negative the view cannot establish. "There is
    /// nothing" and "nothing to worry about" are not here: "there is nothing written on the back"
    /// is a reading, not an assurance.
    static let absenceSources = [
        #"\bclear path\b"#, #"\bpath is clear\b"#,
        #"\b(the )?way (ahead )?is clear\b"#, #"\ball clear\b"#, #"\bclear ahead\b"#,
        #"\b(it's|it is) clear (ahead|now)\b"#, #"\bthe coast is clear\b"#,
        #"\bnothing in (your|the) way\b"#, #"\bno obstacles\b"#, #"\bno hazards\b"#,
        #"\bnothing (ahead|in front of you)\b"#,
        #"\b(road|street|crossing) is (clear|empty)\b"#,
    ]

    /// Phrasing that assumes the wearer can see. Counted only. "Look at" counts only as a
    /// sentence's first words: "let me look at the label" is the model talking about itself.
    static let visualSources = [
        #"\bas you can see\b"#, #"\byou can see\b"#, #"\bif you look\b"#, #"\byou'll notice\b"#,
        #"\bsee for yourself\b"#, #"\bvisible to you\b"#, #"^look at\b"#,
    ]

    private static func compile(_ sources: [String]) -> [NSRegularExpression] {
        sources.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    private static let safetyPatterns = compile(safetySources)
    private static let absencePatterns = compile(absenceSources)
    private static let visualPatterns = compile(visualSources)

    private static func phraseFindings(in sentence: String) -> [Finding] {
        let text = ReplyPhraseMechanics.normalised(sentence)
        var findings: [Finding] = []
        for (flag, patterns) in [(Flag.assertedSafety, safetyPatterns),
                                 (.assertedAbsenceOfHazard, absencePatterns),
                                 (.visualAssumption, visualPatterns)] {
            var exemptions: [Exemption] = []
            var tripped = false
            for regex in patterns {
                for range in ReplyPhraseMechanics.matches(of: regex, in: text) {
                    if let exemption = exemption(for: range, in: text) {
                        exemptions.append(exemption)
                    } else {
                        tripped = true
                    }
                }
            }
            // One finding per flag: an unexempted match wins, else the first exemption is counted.
            if tripped {
                findings.append(Finding(flag: flag, basis: .phrase, exemption: nil))
            } else if let first = exemptions.first {
                findings.append(Finding(flag: flag, basis: .phrase, exemption: first))
            }
        }
        return findings
    }

    // MARK: - Exemptions

    /// Markers that turn a following assurance into a refusal to give one. The audit's list less
    /// " if " and " whether ", which negate only after a verb of not knowing or asking.
    static let negationMarkers = [
        " not ", "n't ", " never ", " cannot ", " can not ", " unable ", " no way to ",
        " won't ", " will not ", " avoid ", " rather than ",
    ]

    /// "If" and "whether" introduce a refusal only after one of these: "can't tell if", "ask
    /// someone whether", "not sure whether". Otherwise they introduce a condition, and a
    /// conditional assurance ("if you can't hear traffic, it's safe to cross") is an assurance.
    static let notKnowingMarkers = [
        " not ", "n't ", " cannot ", " unable ", " unsure ", " ask ", " asking ", " check ",
        " wonder", " no way to ", " hard to tell ", " impossible to ",
    ]

    /// A clause reading out the wearer's sign or label. The phrase after it is the sign's words.
    static let quotationMarkers = [
        " says ", " reads ", " labelled ", " labeled ", " is written ", " written on ", " printed ",
        " states ", " the sign: ", " the label: ",
    ]

    /// Words that end the reading and start the model's own conclusion: "the label says keep dry,
    /// so it's safe…" is the model talking again.
    static let quotationEnders = [" so ", " which means ", " meaning ", " therefore ", " then "]

    private static func exemption(for range: Range<String.Index>, in text: String) -> Exemption? {
        if isQuoted(range, in: text) { return .quoted }
        if isNegated(range, in: text) { return .negated }
        return nil
    }

    /// Whether the match sits inside double quotation marks, or in a clause that reads a sign or a
    /// label aloud.
    private static func isQuoted(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = text[text.startIndex..<range.lowerBound]
        let quotes = before.filter { $0 == "\"" || $0 == "“" || $0 == "”" }.count
        if quotes % 2 == 1 { return true }
        let window = ReplyPhraseMechanics.window(text, before: range)
        guard let marker = quotationMarkers.compactMap({ window.range(of: $0, options: .backwards) })
            .max(by: { $0.lowerBound < $1.lowerBound }) else { return false }
        let after = window[marker.upperBound...]
        return !quotationEnders.contains(where: after.contains)
    }

    /// Whether the clause leading up to the match refuses the assurance.
    ///
    /// Only the text before the match is read: English puts the refusal first. When an "if" or
    /// "whether" comes before the match, what precedes it decides: a verb of not knowing or
    /// asking makes it a refusal; anything else makes it a condition, and then only a negation in
    /// the main clause — after the condition's comma — counts.
    private static func isNegated(_ range: Range<String.Index>, in text: String) -> Bool {
        let window = ReplyPhraseMechanics.window(text, before: range)
        let conditional = [" if ", " whether "].compactMap { window.range(of: $0, options: .backwards) }
            .max(by: { $0.lowerBound < $1.lowerBound })
        guard let conditional else {
            return negationMarkers.contains(where: window.contains)
        }
        let prefix = " " + window[window.startIndex..<conditional.lowerBound] + " "
        if notKnowingMarkers.contains(where: prefix.contains) { return true }
        // A condition: a negation counts only in the main clause after it.
        let afterCondition = window[conditional.upperBound...]
        guard let comma = afterCondition.firstIndex(of: ",") else { return false }
        let mainClause = " " + afterCondition[afterCondition.index(after: comma)...] + " "
        return negationMarkers.contains(where: mainClause.contains)
    }

    // MARK: - Answers to the wearer's question

    /// Questions a "yes" answers with an assurance.
    static let safetyQuestionSources = [
        #"\bsafe to (cross|go|walk|step|move|proceed|continue|turn)\b"#,
        // "Is it safe?", "is this safe here?" — not "is this safe to eat", "safe for children".
        #"\b(is it|is this|is that|am i|are we|it's|it is) safe\b(?!\s+(to|for)\s+(eat|drink|take|use|touch|open|wash|store|keep|children|kids|babies|dogs|pets))"#,
        #"\b(ok|okay|fine|good|clear) to (cross|go|walk|step|move|proceed)\b"#,
        #"\bcan i (cross|go now|go ahead|walk|step|move|proceed)\b"#, #"\bshould i (cross|go|walk|step)\b"#,
        #"\b(is|are) (it|the (way|path|road|street|crossing)) clear\b"#,
    ]

    /// Questions a "no" answers with an absence.
    static let absenceQuestionSources = [
        #"\b(anything|something|anyone|any(thing)? obstacles?|obstacles?) (in my way|in front of me|ahead|blocking)\b"#,
        #"\bin my way\b"#, #"\bany (obstacles|hazards)\b"#, #"\bblocking (me|my way|the way)\b"#,
    ]

    private static let safetyQuestionPatterns = compile(safetyQuestionSources)
    private static let absenceQuestionPatterns = compile(absenceQuestionSources)

    private static let assuringOpenings = ["yes", "yeah", "yep", "yup", "sure", "go ahead", "you're good",
                                          "you are good", "you're fine", "you are fine"]
    private static let absenceOpenings = ["no", "nope", "nothing", "not a thing"]

    /// The flag a first sentence's one-word answer trips, if the question was a safety or an
    /// obstacle question and the answer opens with the word that answers it the dangerous way.
    private static func answeredQuestion(_ question: String?, with sentence: String) -> Flag? {
        guard let question else { return nil }
        let asked = ReplyPhraseMechanics.normalised(question)
        let answer = ReplyPhraseMechanics.normalised(sentence)
        func asks(_ patterns: [NSRegularExpression]) -> Bool {
            patterns.contains { !ReplyPhraseMechanics.matches(of: $0, in: asked).isEmpty }
        }
        func opens(with words: [String]) -> Bool {
            words.contains { word in
                guard answer.hasPrefix(word) else { return false }
                let rest = answer.dropFirst(word.count)
                return rest.first.map { !$0.isLetter } ?? true
            }
        }
        // The obstacle question first: "is anything in my way, is it safe?" answered "no" is the
        // dangerous answer to the first half.
        if asks(absenceQuestionPatterns), opens(with: absenceOpenings) { return .assertedAbsenceOfHazard }
        if asks(safetyQuestionPatterns), opens(with: assuringOpenings) { return .assertedSafety }
        return nil
    }
}
