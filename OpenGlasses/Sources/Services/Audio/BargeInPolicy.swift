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
///
/// # The phone's mic under somebody else's speakers
///
/// Build 581 found the loudspeaker was not the only route with nothing cancelling the echo. With
/// the phone's mic chosen and the reply on a pair of glasses' A2DP speakers — open-ear, near full
/// volume — the recogniser heard "aluminum capacity of 42" over a reply about an ampacity of 47,
/// and "in 2000 3029" over a vault named "2030–29", and answered both as questions. Echo
/// cancellation needs the mic and the speaker on one device, so the caller now reports any such
/// route as `openSpeaker` (`MicRoutePolicy.hasNoEchoPath`) and only stop and the wake phrase cut
/// through it.
///
/// Both transcripts also show where the overlap test is weakest, on the routes that keep it. A
/// number is the one thing a recogniser rewrites freely — "2030–29" is spoken as words and written
/// back as whatever digits it heard — so while the reply has any number in it, a number heard over
/// it is not evidence of anybody. And "ampacity" heard as "capacity" is two letters wrong: a word
/// of at least `shortestTwoEditEchoWord` letters may be two edits from the reply's and still be it.
/// Neither looks at the language: a number is any character Unicode calls numeric, in any script.
///
/// # Words that carry their grammar
///
/// A Korean tester (2026-10-09) had every reply cut itself off on the glasses route, where the
/// overlap test above is the only guard. Korean writes a word and its particle as one token —
/// the reply says "날씨" and the recogniser hears "날씨가" or "날씨는" — so whole-token overlap found
/// almost nothing in common between the reply and its own echo, and the fuzzy allowance did not
/// help either: it was measured in characters, and a Hangul character is a whole syllable. Two
/// structural changes, neither of which looks at the language: a heard word that *extends* a
/// spoken word (or the reverse) by a stem of at least two characters is the reply, and the
/// one-letter allowance is measured in decomposed letters, which for Hangul means one jamo.
///
/// A script without word spacing has the same problem one level up: the recogniser writes the
/// reply's echo as one run, which equals none of the reply's tokens, so it was always "novel" and
/// always interrupted. A single long run is therefore compared by its character pairs
/// (`echoesAsRun`): two thirds of them in the reply and it is the reply.
enum BargeInPolicy {

    /// What the microphone is hearing from the app itself while this transcript arrives.
    enum AssistantSpeech: Equatable {
        /// Nothing is playing — every transcript is somebody in the room.
        case silent
        /// TTS is playing. `text` is the utterance being spoken, when the caller can supply it;
        /// `nil` means the caller knows playback is live but cannot say what it is saying, and
        /// then there is nothing to distinguish the wearer from the echo.
        ///
        /// `openSpeaker` is whether the microphone hears it with nothing cancelling the echo: the
        /// phone's own loudspeaker, where it is at full volume along with everyone in the room, or
        /// the phone's mic with the reply on another device's speakers
        /// (`MicRoutePolicy.hasNoEchoPath`).
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
            // The loudspeaker (or any speaker the mic hears uncancelled) is in the microphone's
            // ear, and so is the room: no transcript heard over it is evidence of the wearer. Stop
            // and the wake phrase above still cut through.
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
        let numbersAreEcho = mentionsNumber(spoken)
        let novel = heard.filter { !(numbersAreEcho && isNumberToken($0)) && !isEcho($0, of: said) }
        let overlap = Double(heard.count - novel.count) / Double(heard.count)
        guard overlap < echoOverlapThreshold else { return false }
        if novel.count >= minimumNovelTokens { return true }
        // One unspaced run — a sentence in a script without word spacing. New if its characters
        // are not the reply's; the reply read back as one run is still the reply.
        guard heard.count == 1, novel.count == 1, novel[0].count >= minimumCharacters else { return false }
        return !echoesAsRun(novel[0], spoken: spoken)
    }

    /// Whether a single unspaced run reads as `spoken` coming back: the share of its adjacent
    /// character pairs that occur anywhere in the reply, against `echoOverlapThreshold`. Pairs,
    /// not characters, so a sentence that merely uses common characters does not read as the
    /// reply; the reply's own text is a long run of the same pairs in the same order.
    static func echoesAsRun(_ run: String, spoken: String) -> Bool {
        let heard = characterPairs(run)
        guard !heard.isEmpty else { return false }
        let said = Set(characterPairs(PhraseMatcher.tokenize(spoken).joined()))
        guard !said.isEmpty else { return false }
        let overlap = heard.filter { said.contains($0) }.count
        return Double(overlap) / Double(heard.count) >= echoOverlapThreshold
    }

    static func characterPairs(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
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
        if heard.count == 1, heard[0].count >= minimumCharacters, echoesAsRun(heard[0], spoken: spoken) {
            return true
        }
        let numbersAreEcho = mentionsNumber(spoken)
        let overlap = heard.filter { (numbersAreEcho && isNumberToken($0)) || isEcho($0, of: said) }.count
        return Double(overlap) / Double(heard.count) >= echoOverlapThreshold
    }

    // MARK: - Numbers

    /// Separators a written number may carry ("3,029", "2030–29", "4/0"). `PhraseMatcher.tokenize`
    /// already splits on them; they are accepted here so the test holds for a token from anywhere.
    static let numberSeparators: Set<Character> = [".", ",", ":", "/", "-", "\u{2013}", "\u{2014}"]

    /// Whether a heard token is a number: digits — in any script — optionally with separators.
    static func isNumberToken(_ token: String) -> Bool {
        guard token.contains(where: \.isNumber) else { return false }
        return token.allSatisfy { $0.isNumber || numberSeparators.contains($0) }
    }

    /// Whether the reply says a number, in digits or in words. Either way the recogniser writes it
    /// back as digits of its own choosing, so a number heard over such a reply proves nothing.
    static func mentionsNumber(_ spoken: String) -> Bool {
        if spoken.contains(where: \.isNumber) { return true }
        return PhraseMatcher.tokenize(spoken).contains { spelledNumberWords.contains($0) }
    }

    /// Languages whose spelled-out numbers `spelledNumberWords` knows. Data, not a check: the reply
    /// is never asked which language it is in, and a word from any of these counts in every reply.
    /// Scripts whose number words are numeric characters (Chinese, Japanese) need no entry.
    static let spelledNumberLanguages = [
        "en", "fr", "de", "es", "it", "pt", "nl", "sv", "da", "nb", "fi", "pl", "cs", "sk", "hr",
        "ro", "hu", "tr", "el", "ru", "id", "ms", "vi", "ko", "hi", "th", "ar", "ca",
    ]

    /// The words those languages spell 0–20, the tens, a hundred, a thousand and a million with —
    /// enough to notice a reply that says "sixty-five" where another would write 65.
    static let spelledNumberWords: Set<String> = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        let samples = Array(0...20) + stride(from: 30, through: 90, by: 10) + [100, 1_000, 1_000_000]
        var words = Set<String>()
        for language in spelledNumberLanguages {
            formatter.locale = Locale(identifier: language)
            for sample in samples {
                guard let spelled = formatter.string(from: NSNumber(value: sample)) else { continue }
                // Two-letter Latin words ("on", "un", "um") are ordinary words in too many
                // languages to mean a number; a short word in another script is kept.
                words.formUnion(PhraseMatcher.tokenize(spelled).filter {
                    $0.count >= 3 || !$0.allSatisfy(\.isASCII)
                })
            }
        }
        return words
    }()

    /// Shortest word that may match the reply with one letter wrong. Below it a single edit turns
    /// most words into other common words ("bus" → "but"), and the wearer's own short words would
    /// start reading as echo.
    static let shortestFuzzyEchoWord = 4

    /// Shortest word that may match the reply with two letters wrong ("ampacity" heard as
    /// "capacity", build 581). At this length two edits still leave most of the word standing; at
    /// five or six they turn ordinary words into each other.
    static let shortestTwoEditEchoWord = 7

    /// Letters a heard word may differ from a reply word of the same reach by: none below
    /// `shortestFuzzyEchoWord`, one up to `shortestTwoEditEchoWord`, two from there — counted on
    /// the shorter of the two, so a long reply word cannot lend a short heard word its allowance.
    static func echoEditAllowance(heardUnits: Int, saidUnits: Int) -> Int {
        let shorter = min(heardUnits, saidUnits)
        if shorter >= shortestTwoEditEchoWord { return 2 }
        if shorter >= shortestFuzzyEchoWord { return 1 }
        return 0
    }

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

    /// Shortest shared stem, in characters, for a heard word to read as a spoken word with
    /// grammar attached or removed ("날씨가" for "날씨", "motors" for "motor"). One character is a
    /// syllable in Hangul and a letter in Latin: far too little to say two words are the same.
    static let shortestEchoStem = 2

    /// Whether one heard word is the reply's: exactly, as a contraction form, as a spoken word
    /// with its grammar attached or removed, or — for a word long enough to survive it — with one
    /// letter misheard (two for a long word, `echoEditAllowance`).
    static func isEcho(_ word: String, of vocabulary: Set<String>) -> Bool {
        if vocabulary.contains(word) { return true }
        if contractionForms(word).contains(where: { vocabulary.contains($0) }) { return true }
        if vocabulary.contains(where: { sharesStem(word, $0) }) { return true }
        let heard = WakePhraseMatcher.fuzzyUnits(word)
        guard heard.count >= shortestFuzzyEchoWord else { return false }
        return vocabulary.contains { candidate in
            let said = WakePhraseMatcher.fuzzyUnits(candidate)
            let allowance = echoEditAllowance(heardUnits: heard.count, saidUnits: said.count)
            return allowance > 0
                && abs(said.count - heard.count) <= allowance
                && WakePhraseMatcher.editDistance(said, heard) <= allowance
        }
    }

    /// Whether one word is the other with something appended: the shorter is a prefix of the
    /// longer and is at least `shortestEchoStem` characters. Structural — it does not know a
    /// particle from a plural — and it works in both directions, so a recogniser that drops the
    /// grammar is covered as well as one that adds it.
    static func sharesStem(_ a: String, _ b: String) -> Bool {
        guard a != b else { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= shortestEchoStem && long.hasPrefix(short)
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
