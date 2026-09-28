import Foundation

/// Plan FE P3 — what a transcript heard *while the assistant is speaking* is allowed to do.
///
/// Before this, the decision lived inline in `WakeWordService.handleRecognitionResult` and ended
/// with one line:
///
/// ```swift
/// if wordCount >= 2 { onBargeIn?(trimmed) }
/// ```
///
/// Two words is not a definition of "the wearer meant to interrupt". It is a guess that happens to
/// hold for English conversational speech and falls apart everywhere else: a colleague's two words
/// across the room trip it, the assistant's own voice coming back through the mic trips it, and a
/// language written without spaces between words cannot trip it at all no matter how much the
/// wearer says. The count survives here only as a **noise floor** — the smallest structural filter
/// that keeps a stray partial from cutting the assistant off — and it is explicitly not the
/// criterion for deliberate speech. Deciding *that* needs signals this policy does not have
/// (loudness, direction, echo cancellation state), which is why the honest fix for someone whom it
/// gets wrong is the switch below rather than a cleverer threshold.
///
/// What this policy is not allowed to do:
///
/// - **Look at the language.** No locale, no script detection, no per-language word counts. The
///   floor is structural and applies identically to every transcript.
/// - **Gate the explicit stop.** "Stop" and the wake phrase cut through in every configuration.
///   An interruption control that can disable the way out of a long answer is a trap.
///
/// # Echo
///
/// This comment used to say echo was somebody else's problem — suppressed upstream, so a
/// transcript arriving here could be treated as speech. That was not true of the wake-word
/// recogniser, which is the one running during playback: the gate lives on the capture router's
/// path, there is no acoustic echo cancellation on the wearer's route, and a field build (407)
/// cut every single reply off one to two seconds in because the recogniser was hearing the
/// assistant read its own answer back. A noise floor cannot tell that apart — the assistant's
/// voice clears any floor you care to set.
///
/// So while the assistant is speaking, a *general* interrupt now needs evidence that the words
/// came from the wearer rather than from the speaker, and the only evidence available at this
/// layer is that they are not what is being said. That check is deliberately weak, which is why
/// it only gates general speech: the explicit stop and the wake phrase are unaffected and still
/// cut through, so the wearer is never stuck inside a long answer.
///
/// # The phone's own loudspeaker
///
/// Build 420 showed the overlap test is not enough on the phone route. With the reply playing out
/// of the iPhone's loudspeaker an inch from the iPhone's microphone, six answers in a row were cut
/// off two to six seconds in — four of them the same photo reply, cut at the same point on the
/// same two-word partial. Two words is too small a sample for a two-thirds overlap to mean
/// anything: one misheard or contracted word ("i've" heard as "i have") and half the transcript is
/// "not what is being said". And on an open speaker the room is in the microphone too — at a
/// customer demo that is several people talking.
///
/// So on the loudspeaker a general interrupt is refused outright, and elsewhere it needs a real
/// sample: at least two words (or a run of unspaced script) that are not in the reply, matched
/// loosely enough that contractions and one-letter mishearings count as the reply.
enum BargeInPolicy {

    /// What the microphone is hearing from the app itself while this transcript arrives.
    enum AssistantSpeech: Equatable {
        /// Nothing is playing — every transcript is somebody in the room.
        case silent
        /// TTS is playing. `text` is the utterance being spoken, when the caller can supply it;
        /// `nil` means the caller knows playback is live but cannot say what it is saying, and
        /// then there is nothing to distinguish the wearer from the echo.
        ///
        /// `openSpeaker` is whether it is playing out of the phone's own loudspeaker, where the
        /// microphone hears it at full volume along with everyone in the room.
        case speaking(text: String?, openSpeaker: Bool = false)
    }

    enum Decision: Equatable {
        /// An explicit stop. Cut the speech; the words themselves are not a query.
        case stop
        /// A wake phrase over playback: cut the speech and start a fresh conversation.
        case newConversation(phrase: String)
        /// General speech over playback: cut the speech and answer what was said instead.
        case interrupt(text: String)
        /// Let the assistant keep talking.
        case ignore
    }

    /// Smallest whitespace-separated token count that reads as an utterance rather than a stray
    /// partial. A noise floor — see the type comment — not a threshold for intent.
    static let minimumTokens = 2

    /// The same floor for scripts that do not put spaces between words, counted in non-whitespace
    /// characters. Without it the token count would be a rule that Chinese, Japanese and Thai
    /// speakers can never satisfy — general barge-in would simply not work for them at all, and it
    /// would fail silently, looking like a broken mic rather than a policy.
    ///
    /// Set well above a typical word so it stays a fallback rather than a general loosening: short
    /// words and conversational filler ("ok", "yeah", "hmm", "sorry") stay below it, so for
    /// space-separated speech the token count remains the operative floor in practice. A single
    /// long word does now clear it where it previously did not; that is the price of not gating
    /// the feature on whitespace, and it errs towards answering the wearer.
    static let minimumCharacters = 8

    /// - Parameters:
    ///   - transcript: the recognizer's current text for this utterance.
    ///   - isStopPhrase: whether the caller's stop-phrase matcher fired (persona-aware; not this
    ///     policy's business to re-derive).
    ///   - matchedWakePhrase: the wake phrase the caller matched, if any.
    ///   - generalBargeInEnabled: the wearer's setting. `false` means *only* the two explicit
    ///     signals above may interrupt.
    ///   - assistantSpeech: what the app is playing as this transcript arrives. Defaults to
    ///     `.silent`, which is the right answer for every caller outside the playback window.
    static func decide(transcript: String,
                       isStopPhrase: Bool,
                       matchedWakePhrase: String?,
                       generalBargeInEnabled: Bool,
                       assistantSpeech: AssistantSpeech = .silent) -> Decision {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignore }

        // Explicit signals first, and unconditionally: neither is affected by the setting, and
        // neither is affected by the echo test below. A wearer saying "stop" over the assistant is
        // exactly the case that must never be mistaken for the assistant.
        if isStopPhrase { return .stop }
        if let matchedWakePhrase { return .newConversation(phrase: matchedWakePhrase) }

        guard generalBargeInEnabled else { return .ignore }
        guard clearsNoiseFloor(trimmed) else { return .ignore }
        if case .speaking(let spoken, let openSpeaker) = assistantSpeech {
            // The loudspeaker is in the microphone's ear, and so is the room: no transcript heard
            // over it is evidence of the wearer. Stop and the wake phrase above still cut through.
            guard !openSpeaker else { return .ignore }
            // No idea what is playing ⇒ no evidence this is the wearer ⇒ don't cut the answer.
            guard let spoken, readsAsWearer(trimmed, spoken: spoken) else { return .ignore }
        }
        return .interrupt(text: trimmed)
    }

    /// Words heard over playback that are not in the reply, before they count as the wearer
    /// rather than a misheard word or two of the reply. See the type comment: a two-word partial
    /// with one stray word is how every reply was cut off on build 420.
    static let minimumNovelTokens = 2

    /// Whether `transcript`, heard while `spoken` plays, is somebody other than the assistant: it
    /// does not read as the reply, **and** there is enough of it that is not the reply to be a
    /// sample rather than a mishearing. The unspaced-script fallback mirrors the noise floor, so
    /// the rule does not quietly stop working for a language without spaces between words.
    static func readsAsWearer(_ transcript: String, spoken: String) -> Bool {
        let heard = PhraseMatcher.tokenize(transcript)
        let said = spokenVocabulary(spoken)
        guard !heard.isEmpty else { return false }
        guard !said.isEmpty else { return true }
        let novel = heard.filter { !isEcho($0, of: said) }
        let overlap = Double(heard.count - novel.count) / Double(heard.count)
        guard overlap < echoOverlapThreshold else { return false }
        if novel.count >= minimumNovelTokens { return true }
        // One unspaced run that is entirely new — a sentence in a script without word spacing.
        return heard.count == 1 && novel.count == 1 && novel[0].count >= minimumCharacters
    }

    /// Share of a transcript's words that must also appear in what is being spoken before it reads
    /// as the assistant's own voice rather than the wearer's.
    ///
    /// Two thirds, because both halves of the mistake are cheap to picture. Too low and a wearer
    /// who repeats a word back ("no — *Tuesday*?") cannot interrupt; too high and a recogniser
    /// that mangles one word in three stops recognising the echo. It is a bag of words on purpose:
    /// the recogniser hears the playback at a delay and out of order often enough that requiring a
    /// contiguous run would catch almost nothing.
    static let echoOverlapThreshold = 2.0 / 3.0

    /// Whether `transcript` reads as `spoken` coming back through the microphone.
    static func echoesSpokenText(_ transcript: String, spoken: String) -> Bool {
        let heard = PhraseMatcher.tokenize(transcript)
        let said = spokenVocabulary(spoken)
        guard !heard.isEmpty, !said.isEmpty else { return false }
        let overlap = heard.filter { isEcho($0, of: said) }.count
        return Double(overlap) / Double(heard.count) >= echoOverlapThreshold
    }

    /// Shortest word that may match the reply with one letter wrong. Below it a single edit turns
    /// most words into other common words ("bus" → "but"), and the wearer's own short words would
    /// start reading as echo.
    static let shortestFuzzyEchoWord = 4

    /// Every form of the reply's words the recogniser might write down: the words themselves, and
    /// for a contraction its stem and its expansion — "it's" is heard as "it's", "its" or "it is",
    /// "don't" as "do not".
    static func spokenVocabulary(_ spoken: String) -> Set<String> {
        var vocabulary = Set<String>()
        for token in PhraseMatcher.tokenize(spoken) {
            vocabulary.insert(token)
            vocabulary.formUnion(contractionForms(token))
        }
        return vocabulary
    }

    /// Whether one heard word is the reply's: exactly, as a contraction form, or — for a word long
    /// enough to survive it — with one letter misheard.
    static func isEcho(_ word: String, of vocabulary: Set<String>) -> Bool {
        if vocabulary.contains(word) { return true }
        if contractionForms(word).contains(where: { vocabulary.contains($0) }) { return true }
        guard word.count >= shortestFuzzyEchoWord else { return false }
        return vocabulary.contains { candidate in
            candidate.count >= shortestFuzzyEchoWord
                && abs(candidate.count - word.count) <= 1
                && WakePhraseMatcher.levenshteinDistance(candidate, word) <= 1
        }
    }

    /// The other spellings of a contracted word: its apostrophe-free form and its parts.
    static func contractionForms(_ token: String) -> [String] {
        guard let apostrophe = token.firstIndex(of: "'") else { return [] }
        let stem = String(token[..<apostrophe])
        let suffix = String(token[token.index(after: apostrophe)...])
        var forms = [token.replacingOccurrences(of: "'", with: ""), stem]
        switch suffix {
        case "t" where stem.hasSuffix("n"):
            // "don't" → "do not", "can't" → "can not", "won't" → "will not".
            let base = String(stem.dropLast())
            forms += [base == "wo" ? "will" : base == "ca" ? "can" : base, "not"]
        case "s": forms += ["is", "has"]
        case "re": forms.append("are")
        case "ve": forms.append("have")
        case "ll": forms.append("will")
        case "d": forms += ["would", "had"]
        case "m": forms.append("am")
        default: break
        }
        return forms.filter { !$0.isEmpty }
    }

    /// Whether `trimmed` is more than a stray fragment. Either signal is enough; neither is a claim
    /// about what language it is in.
    static func clearsNoiseFloor(_ trimmed: String) -> Bool {
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        if tokens.count >= minimumTokens { return true }
        let characters = trimmed.filter { !$0.isWhitespace }.count
        return characters >= minimumCharacters
    }
}
