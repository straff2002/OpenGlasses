import Foundation

/// When a caption asks the wearer for an answer (Plan MO §4).
///
/// Pure: one caption and what the session knows in, one outcome out, with a reason for every
/// caption that gets no hint so the session can log why. The checks, in order:
/// - **finals only**: an interim caption is revised, and a hint on half a sentence is worse than
///   none;
/// - the `[Visual:` notes a recording inserts are not speech;
/// - in keyword mode, the keyword matcher decides and nothing else applies (anyone may say a
///   keyword, the wearer included);
/// - the wearer's own voice, when diarization knows which it is;
/// - under `HintLimits.minimumQuestionWords` words;
/// - a tag question ("…, isn't it?") asks for agreement, not an answer;
/// - small talk ("how was your trip");
/// - **asks for an answer**: a question by `UtteranceQuestionCue`, or an invitation to answer
///   that the cue reads as a polite command ("could you explain…", "walk me through…"). In a
///   language the cue has no words for, a question mark alone, never the cue's fallback `true`;
/// - a question already hinted this session (content words overlapping by
///   `HintLimits.duplicateOverlap` or more);
/// - at least `HintLimits.hintSpacing` since the last hint, unless a different speaker asks.
///
/// "One in flight" (a new question replacing a waiting one) is `HintQueue`'s, after this.
enum HintTrigger {

    enum Outcome: Equatable {
        /// Hint this question (the caption's text, trimmed).
        case hint(question: String)
        /// Keyword mode: the first of the wearer's keywords the caption says.
        case keyword(word: String)
        /// No hint, and why.
        case none(reason: SkipReason)
    }

    enum SkipReason: String, Equatable, CaseIterable {
        case notFinal
        case visualNote
        case noKeyword
        case wearer
        case tooShort
        case tagQuestion
        case smallTalk
        case notAQuestion
        /// Lecture mode, and not a question: key points are the session's cadence (P1), not the
        /// trigger's.
        case lectureMode
        case alreadyHinted
        case tooSoon
    }

    /// What the session knows when a caption arrives.
    struct Context: Equatable {
        var mode: HintMode
        /// The wearer's diarized speaker id, once they tapped "That's me". Nil hints every voice.
        var wearerSpeaker: Int?
        /// Questions hinted so far this session.
        var hintedQuestions: [String]
        var lastHintAt: Date?
        var lastHintSpeaker: Int?
        /// The clock.
        var now: Date

        init(mode: HintMode = .conversation, wearerSpeaker: Int? = nil, hintedQuestions: [String] = [],
             lastHintAt: Date? = nil, lastHintSpeaker: Int? = nil, now: Date) {
            self.mode = mode
            self.wearerSpeaker = wearerSpeaker
            self.hintedQuestions = hintedQuestions
            self.lastHintAt = lastHintAt
            self.lastHintSpeaker = lastHintSpeaker
            self.now = now
        }
    }

    /// Conversation and lecture modes, which need no keywords.
    static func evaluate(_ caption: HintCaption, context: Context) -> Outcome {
        var none = KeywordMatcher(keywords: [])
        return evaluate(caption, context: context, keywords: &none)
    }

    /// Every mode. `keywords` holds the keyword mode's hold state, and is only touched in that mode.
    static func evaluate(_ caption: HintCaption, context: Context, keywords: inout KeywordMatcher) -> Outcome {
        guard caption.isFinal else { return .none(reason: .notFinal) }
        let text = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[Visual:") { return .none(reason: .visualNote) }

        if context.mode == .keyword {
            guard let word = keywords.match(text, at: context.now).first else {
                return .none(reason: .noKeyword)
            }
            return .keyword(word: word)
        }

        if let wearer = context.wearerSpeaker, caption.speaker == wearer {
            return .none(reason: .wearer)
        }
        if HintText.wordCount(text) < HintLimits.minimumQuestionWords { return .none(reason: .tooShort) }
        if isTagQuestion(text, languageCode: caption.languageCode) { return .none(reason: .tagQuestion) }
        if isSmallTalk(text, languageCode: caption.languageCode) { return .none(reason: .smallTalk) }
        guard asksForAnswer(text, languageCode: caption.languageCode) else {
            return .none(reason: context.mode == .lecture ? .lectureMode : .notAQuestion)
        }
        if isAlreadyHinted(text, hinted: context.hintedQuestions) { return .none(reason: .alreadyHinted) }
        if let last = context.lastHintAt,
           context.now.timeIntervalSince(last) < HintLimits.hintSpacing - HintLimits.timeTolerance {
            let differentSpeaker = caption.speaker != nil && context.lastHintSpeaker != nil
                && caption.speaker != context.lastHintSpeaker
            if !differentSpeaker { return .none(reason: .tooSoon) }
        }
        return .hint(question: text)
    }

    // MARK: - Asks for an answer

    /// An invitation to answer that `UtteranceQuestionCue` reads as a polite command, by language:
    /// polite requests and interview-style openers. Compared as folded words at the start of a
    /// sentence or a comma clause, after leading fillers.
    static let invitations: [String: [String]] = [
        "en": [
            "can you tell me", "could you tell me", "would you tell me",
            "can you explain", "could you explain", "would you explain",
            "can you describe", "could you describe", "would you describe",
            "can you walk me through", "could you walk me through", "would you walk me through",
            "can you talk me through", "could you talk me through", "would you talk me through",
            "can you take me through", "could you take me through",
            "can you give me", "could you give me", "would you give me",
            "can you share", "could you share", "would you share",
            "would you mind explaining", "would you mind telling", "would you mind describing",
            "i'd like to hear about", "i would like to hear about", "i'd love to hear about",
            "i'd like to know", "i would like to know", "i'd love to know",
            "tell me about", "tell me how", "tell me why", "tell me what", "tell me when",
            "walk me through", "talk me through", "take me through",
            "describe", "explain", "give me an example", "share an example", "share a time",
        ],
    ]

    /// Words a speaker opens with before the request itself ("so, tell me about…").
    static let leadingFillers: [String: Set<String>] = [
        "en": ["so", "and", "now", "well", "okay", "ok", "right", "alright", "great", "please",
               "then", "also", "next", "first", "finally", "um", "uh", "oh"],
    ]

    /// Question marks for a language the cue has no words for. The ASCII semicolon is the Greek
    /// question mark (U+037E is canonically the same character), so it counts only in Greek.
    static let questionMarks: Set<Character> = ["?", "\u{FF1F}", "\u{00BF}", "\u{061F}", "\u{055E}", "\u{1367}"]

    static func asksForAnswer(_ text: String, languageCode: String) -> Bool {
        let language = UtteranceQuestionCue.base(languageCode)
        guard UtteranceQuestionCue.supports(languageCode) else {
            if text.contains(where: { questionMarks.contains($0) }) { return true }
            return language == "el" && text.contains(";")
        }
        if UtteranceQuestionCue.isQuestion(text, languageCode: languageCode) { return true }
        return isInvitation(text, language: language)
    }

    private static func isInvitation(_ text: String, language: String) -> Bool {
        guard let phrases = invitations[language] else { return false }
        let folded = phrases.map(HintText.words)
        let fillers = leadingFillers[language] ?? []
        for sentence in HintText.sentences(text) {
            for clause in sentence.split(separator: ",") {
                let words = HintText.words(String(clause)).drop(while: { fillers.contains($0) })
                if folded.contains(where: { !$0.isEmpty && words.starts(with: $0) }) { return true }
            }
        }
        return false
    }

    // MARK: - Skips

    /// The question words a tag question's stem may not open with: "why isn't it?" asks.
    private static let questionOpeners: Set<String> = ["why", "how", "what", "when", "where", "who", "which"]

    private static let negativeTag = try! NSRegularExpression(pattern:
        #"(?:,\s*|\s+)(?:isn't|aren't|wasn't|weren't|don't|doesn't|didn't|won't|wouldn't|can't|couldn't|shouldn't|haven't|hasn't|hadn't|ain't|mustn't)\s+(?:it|he|she|they|we|you|i|there|that|this)\s*[?.!]*$"#)
    private static let positiveTag = try! NSRegularExpression(pattern:
        #",\s*(?:is|are|was|were|do|does|did|will|would|can|could|should|have|has|had)\s+(?:it|he|she|they|we|you|i|there|that|this)\s*[?.!]*$"#)
    private static let shortTag = try! NSRegularExpression(pattern:
        #",\s*(?:right|eh|yeah|yes|no|ok|okay|correct|huh|true|innit|you know|isn't that right|is that right|don't you think|wouldn't you say|am i right)\s*[?.!]*$"#)

    /// "It's a long way, isn't it?", "You were there, right?" Asks for agreement, not an answer.
    /// English only.
    static func isTagQuestion(_ text: String, languageCode: String) -> Bool {
        guard UtteranceQuestionCue.base(languageCode) == "en" else { return false }
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(lowered.startIndex..., in: lowered)
        for tag in [negativeTag, positiveTag, shortTag] {
            guard let match = tag.firstMatch(in: lowered, range: range),
                  let stemRange = Range(NSRange(location: 0, length: match.range.location), in: lowered) else {
                continue
            }
            let stem = HintText.words(String(lowered[stemRange]))
            guard stem.count >= 2, let first = stem.first, !questionOpeners.contains(first) else { continue }
            return true
        }
        return false
    }

    /// Small talk, by language: the phrase with at most `HintLimits.smallTalkTrailingWords` words
    /// around it ("Hi Sam, how are you?", "how was your trip to Denver?").
    static let smallTalk: [String: [String]] = [
        "en": [
            "how are you", "how are you doing", "how are things", "how's it going", "how is it going",
            "how's everything", "how is everything", "how have you been", "how do you do",
            "how was your trip", "how was your weekend", "how was your day", "how was your flight",
            "how was your holiday", "how was your journey", "how was the drive", "how was the traffic",
            "how's your day going", "how is your day going", "how's your week going",
            "did you have a good weekend", "did you have a good trip", "did you find us okay",
            "nice to meet you", "good to see you", "great to see you", "what's up",
            "are you having a good day", "can i get you a coffee", "can i get you anything",
        ],
    ]

    static func isSmallTalk(_ text: String, languageCode: String) -> Bool {
        guard let phrases = smallTalk[UtteranceQuestionCue.base(languageCode)] else { return false }
        let words = HintText.words(text)
        let slack = HintLimits.smallTalkTrailingWords
        for phrase in phrases.map(HintText.words) where !phrase.isEmpty && phrase.count <= words.count {
            for start in 0...min(slack, words.count - phrase.count)
            where words[start..<start + phrase.count].elementsEqual(phrase) {
                if words.count - (start + phrase.count) <= slack { return true }
            }
        }
        return false
    }

    /// Whether `question` is one already hinted: content words overlapping by
    /// `HintLimits.duplicateOverlap` or more.
    static func isAlreadyHinted(_ question: String, hinted: [String]) -> Bool {
        let words = HintText.contentWords(question)
        return hinted.contains {
            HintText.overlap(words, HintText.contentWords($0)) >= HintLimits.duplicateOverlap - 1e-9
        }
    }
}
