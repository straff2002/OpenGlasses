import Foundation

/// Is this utterance an answer to "what's the job number?", or is it the technician getting on
/// with the work?
///
/// The app asks a question and then arms the microphone, so the very next thing it hears may be
/// the answer — or "what's this error code?", or a bystander, or the wake word firing on a cough.
/// Treating any of those as a job number would file the visit under nonsense; refusing all of them
/// would mean the question never gets answered. So the decision is a narrow, conservative
/// classifier: something is a reference only if it *looks* like one and looks like nothing else.
///
/// Conservative in both directions on purpose. A miss costs one repeat of the question. A false
/// positive costs a read-back the technician has to say "no" to — and, if they are not listening,
/// a wrong number on a work order. So the shape rules below are strict, and anything that smells
/// like a question, a command, a measurement or a fault code is passed straight through to the
/// model with the intake question still outstanding.
enum JobReferenceClassifier {

    enum Utterance: Equatable {
        /// Reference-shaped, with the carrier phrase removed and the rest verbatim.
        case reference(String)
        /// "I don't have one."
        case decline
        case affirmative
        case negative
        /// Anything else. Goes to the model; the question stays outstanding.
        case unrelated
    }

    static func classify(_ text: String) -> Utterance {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrelated }
        let normalised = normalise(trimmed)
        guard !normalised.isEmpty else { return .unrelated }

        if declinePhrases.contains(normalised) { return .decline }
        if affirmativePhrases.contains(normalised) { return .affirmative }
        if negativePhrases.contains(normalised) { return .negative }

        let stripped = stripCarrierPhrase(from: trimmed)
        if looksLikeReference(stripped) { return .reference(stripped) }
        return .unrelated
    }

    // MARK: - Shape

    /// What a job number is allowed to look like once the carrier phrase is off it.
    ///
    /// Must contain a digit: alphabetic-only answers ("the Henderson job") are real but cannot be
    /// told apart from ordinary speech, and guessing at one is worse than asking again.
    static func looksLikeReference(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= maximumLength else { return false }
        guard !candidate.contains("?") else { return false }
        guard candidate.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        let words = candidate.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty, words.count <= maximumWords else { return false }
        guard !questionOpeners.contains(words[0]) else { return false }
        for word in words {
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            if unitWords.contains(bare) { return false }
            if disqualifyingWords.contains(bare) { return false }
        }
        // Letters, digits, and the punctuation a work-order number actually uses.
        return candidate.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || allowedPunctuation.contains(scalar)
        }
    }

    /// Remove a leading carrier phrase, keeping the rest exactly as it was said.
    ///
    /// Applied repeatedly, because "no, it's job number 1005" stacks three of them. Bounded so a
    /// pathological input cannot loop, and it never touches anything after the number.
    ///
    /// The *match* ignores punctuation and case while the *result* does not: "no, it's 1005" has
    /// to strip as cleanly as "no its 1005", but what comes back is the technician's own spelling
    /// of the number, character for character.
    static func stripCarrierPhrase(from text: String) -> String {
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<maximumCarrierStrips {
            guard let phrase = carrierPhrases.first(where: { matchesPrefix($0, of: current) }),
                  let remainder = dropPrefixWords(phrase, from: current) else { break }
            current = remainder
        }
        // A trailing full stop or exclamation is the recogniser's, not the technician's.
        while let last = current.last, ".!,".contains(last) { current = String(current.dropLast()) }
        return current.trimmingCharacters(in: .whitespaces)
    }

    /// Whether `phrase` is the start of `text` once both are reduced to bare lowercase words.
    private static func matchesPrefix(_ phrase: String, of text: String) -> Bool {
        let words = normalise(text).split(separator: " ")
        let phraseWords = phrase.split(separator: " ")
        guard words.count > phraseWords.count else { return false }
        return Array(words.prefix(phraseWords.count)) == phraseWords
    }

    /// Drop as many *words* from the original as the phrase has, leaving the rest untouched.
    /// Counting words rather than characters is what makes "no, it's" — two words, nine characters
    /// on one side and seven on the other — come off correctly.
    private static func dropPrefixWords(_ phrase: String, from text: String) -> String? {
        var remaining = phrase.split(separator: " ").count
        var index = text.startIndex
        while remaining > 0 {
            // Skip anything that is not part of a word (leading punctuation, spaces).
            while index < text.endIndex, !text[index].isLetter, !text[index].isNumber {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { return nil }
            // …then the word itself, and any punctuation glued inside it ("it's").
            while index < text.endIndex, text[index].isLetter || text[index].isNumber
                    || text[index] == "'" || text[index] == "\u{2019}" {
                index = text.index(after: index)
            }
            remaining -= 1
        }
        return String(text[index...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,:;-–—"))
    }

    // MARK: - Vocabulary

    private static let maximumLength = 24
    private static let maximumWords = 4
    private static let maximumCarrierStrips = 4
    private static let allowedPunctuation = CharacterSet(charactersIn: " -/#._")

    /// Written in the same bare, apostrophe-free form `normalise` produces, because that is what
    /// they are matched against. Most words first, so "job number" wins over "job".
    private static let carrierPhrases: [String] = [
        "no its job number", "no its job", "the job number is", "the work order number is",
        "job number", "job no", "job ref", "job reference", "job id", "job",
        "work order number", "work order no", "work order", "workorder",
        "ticket number", "ticket no", "ticket", "reference", "ref",
        "the number is", "the numbers", "number is", "number",
        "its", "it is", "thats", "that is",
        "no its", "no it is", "no", "yeah", "yep", "yes",
        "erm", "um", "uh"
    ].sorted {
        let (a, b) = ($0.split(separator: " ").count, $1.split(separator: " ").count)
        return a == b ? $0.count > $1.count : a > b
    }

    private static let declinePhrases: Set<String> = [
        "i dont have one", "i do not have one", "i havent got one", "i have not got one",
        "dont have one", "no job number", "theres no job number", "there is no job number",
        "no number", "there isnt one", "there is not one", "theres none", "none",
        "no job", "no job ref", "no reference", "not got one", "havent got one",
        "i dont have a job number", "i do not have a job number", "dont know it",
        "i dont know it", "skip it", "skip", "leave it", "no idea"
    ]

    private static let affirmativePhrases: Set<String> = [
        "yes", "yeah", "yep", "yup", "aye", "correct", "thats right", "that is right",
        "thats it", "that is it", "right", "thats correct", "that is correct", "spot on",
        "affirmative", "ok", "okay", "yes thats right", "yeah thats right", "yes correct",
        "sounds right", "perfect", "exactly"
    ]

    private static let negativePhrases: Set<String> = [
        "no", "nope", "nah", "wrong", "thats wrong", "that is wrong", "not right",
        "thats not right", "that is not right", "incorrect", "negative", "no thats wrong",
        "not quite", "no thats not it", "try again"
    ]

    /// A turn that opens with one of these is a question, whatever digits follow it.
    private static let questionOpeners: Set<String> = [
        "what", "whats", "why", "how", "when", "where", "who", "which", "can", "could",
        "should", "would", "is", "are", "was", "were", "do", "does", "did", "will",
        "tell", "show", "read", "find", "look", "explain", "check", "search", "give"
    ]

    /// Numbers with units are readings, not job numbers.
    ///
    /// Single-letter abbreviations ("240 v", "12 a") are deliberately absent: a real job number
    /// can end in a bare letter ("1005 B"), and rejecting those would be the worse mistake. A
    /// reading that slips through is caught by the read-back.
    private static let unitWords: Set<String> = [
        "volts", "volt", "amps", "amp", "psi", "bar", "kpa", "degrees", "degree",
        "celsius", "fahrenheit", "minutes", "minute", "mins", "seconds", "second",
        "hours", "hour", "percent", "kw", "kilowatts", "watts", "ohms", "ohm",
        "microfarads", "mfd", "uf", "rpm", "hz", "hertz", "litres", "liters", "kg", "lbs",
        "inches", "inch", "mm", "cm", "metres", "meters", "feet", "foot", "pounds"
    ]

    /// Words that make an utterance something other than a job number, whatever its shape.
    private static let disqualifyingWords: Set<String> = [
        "error", "fault", "alarm", "code", "reading", "pressure", "temperature", "voltage",
        "start", "stop", "end", "pause", "resume", "close", "open", "take", "photo",
        "picture", "call", "send", "record", "cancel", "delete", "repeat", "next", "back"
    ]

    /// Lowercase, strip punctuation and collapse whitespace — the form the phrase sets are in.
    ///
    /// An apostrophe is **removed**, not turned into a space: mapping it to a space split "that's"
    /// into "that s" and "don't" into "don t", so every phrase carrying one — which is most of the
    /// natural ways to say yes, no and "I don't have one" — silently stopped matching.
    static func normalise(_ text: String) -> String {
        let stripped = text.lowercased().replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let scalars = stripped.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}
