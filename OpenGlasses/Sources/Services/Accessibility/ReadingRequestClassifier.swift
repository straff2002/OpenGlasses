import Foundation

/// Plan FF P1/PR4 — does this utterance ask for *text* to be read?
///
/// # Why a classifier rather than a router
///
/// The routing audit behind this type found that nothing in the app decides whether a request is a
/// reading request. The live model picks `look_closely` from a tool description that names small
/// print, receipt line items, serial numbers and gauge markings, and never names the five things a
/// blind wearer actually says — "read this", "what does this say", "what's the expiry date", "read
/// the menu", "what does this label say". Direct mode leaves the choice to the LLM as well.
///
/// The fix is deliberately *not* a second command router. A router would have to own every reading
/// phrase in every language and would fire the camera on questions that merely mention text. This
/// is a pure predicate with three consumers, each of which only makes an existing decision better:
///
/// 1. `LookCloselyTool.description` composes ``triggerPhrases`` into the tool description, so the
///    phrase list the model is shown and the phrase list this recognises cannot drift apart.
/// 2. The degraded-capture copy: a reading request gets "move a little closer to the text", a
///    non-reading one gets the general hold-steady line. Wrong advice sends a wearer who cannot
///    check it in the wrong direction.
/// 3. Whether a degraded capture is worth an on-device OCR pass for a partial transcription.
///
/// None of those can fire a camera that policy would not already have fired, which is the property
/// that keeps a false positive cheap.
///
/// # The boundary that matters
///
/// "What do you see", "describe this", "what's in front of me" are **not** reading requests. They
/// are the most common thing a blind wearer says, and treating them as reading requests would turn
/// every scene question into a full-resolution capture — the battery and privacy cost the
/// `LookCloselyPolicy` cooldown exists to bound. The tests pin those as negatives explicitly.
enum ReadingRequestClassifier {

    /// What kind of reading was asked for. Only used to choose between two guidance lines and to
    /// decide whether an OCR fallback is worth running; deliberately coarse.
    enum Kind: String, Equatable, CaseIterable {
        /// "read this", "read it to me", "what does this say".
        case readAloud
        /// A named field on a document or package — an expiry date, a total, a dose, a price.
        case specificField
        /// A menu, sign, label or package as a named surface.
        case namedSurface
    }

    struct Match: Equatable {
        let kind: Kind
        /// The phrase that matched, lower-cased. Useful in a log line and in a test failure.
        let phrase: String
    }

    /// The phrases shown to the model in the `look_closely` description. Kept short and literally
    /// spoken — a model reads examples better than it reads a rule.
    static let triggerPhrases: [String] = [
        "read this", "read it to me", "what does this say", "what does it say",
        "what's the expiry date", "what's the total", "read the menu", "what does this label say",
    ]

    /// Classify an utterance. Returns nil for anything that is not asking for text.
    static func classify(_ utterance: String) -> Match? {
        let text = normalize(utterance)
        guard !text.isEmpty else { return nil }

        // Order is the design: a named field beats a bare "read" verb, because "read me the expiry
        // date" is both and the field answer is the more specific guidance.
        if let phrase = firstMatch(text, in: fieldPhrases) {
            return Match(kind: .specificField, phrase: phrase)
        }
        if let phrase = firstMatch(text, in: surfacePhrases) {
            return Match(kind: .namedSurface, phrase: phrase)
        }
        if let phrase = firstMatch(text, in: readAloudPhrases) {
            return Match(kind: .readAloud, phrase: phrase)
        }
        return nil
    }

    static func isReadingRequest(_ utterance: String) -> Bool { classify(utterance) != nil }

    // MARK: - Vocabulary
    //
    // Multilingual by sample, not by claim. The app ships ten languages and this recognises a small
    // set of the most common reading phrases in several of them; an unrecognised language falls
    // through to the model's own tool selection, which is the behaviour that exists today. It never
    // falls through to a *worse* outcome, which is what makes a partial vocabulary acceptable here
    // and would not make a partial command router acceptable.

    /// A named field on a document or package.
    private static let fieldPhrases: [String] = [
        "expiry date", "expiration date", "expiry", "expires on", "use by date", "best before",
        "what's the total", "whats the total", "what is the total", "how much is it",
        "the price", "what's the price", "whats the price", "what is the price",
        "the dose", "the dosage", "how many milligrams", "the serial number",
        // es / fr / de / nl
        "fecha de caducidad", "date de péremption", "date d'expiration",
        "haltbarkeitsdatum", "houdbaarheidsdatum", "cuál es el total", "cual es el total",
    ]

    /// A named surface whose whole content is wanted.
    private static let surfacePhrases: [String] = [
        "read the menu", "read the sign", "read the label", "read the letter", "read the receipt",
        "read the packet", "read the package", "read the box", "read the screen", "read the page",
        "what does this label say", "what does the label say", "what does this sign say",
        "what does the menu say", "what's on the menu", "whats on the menu",
        "what's on the label", "whats on the label",
        // es / fr / de / nl
        "lee la etiqueta", "lee el menú", "lee el menu", "lis l'étiquette", "lis le menu",
        "lies das etikett", "lies die speisekarte", "lees het etiket", "lees de menukaart",
    ]

    /// A bare instruction to read whatever is in view.
    private static let readAloudPhrases: [String] = [
        "read this", "read that", "read it to me", "read this to me", "read it out",
        "read this out", "read aloud", "read it aloud", "read the text", "read what's written",
        "what does this say", "what does that say", "what does it say", "what is this text",
        "what's written here", "whats written here", "what's written on this",
        "can you read this", "could you read this",
        // es / fr / de / nl
        "lee esto", "léeme esto", "leeme esto", "qué dice esto", "que dice esto",
        "lis ceci", "lis-moi ceci", "qu'est-ce que ça dit", "que dit ceci",
        "lies das vor", "lies mir das vor", "was steht hier", "was steht da",
        "lees dit voor", "lees dit", "wat staat hier",
    ]

    private static func firstMatch(_ text: String, in phrases: [String]) -> String? {
        phrases.first { text.contains($0) }
    }

    /// Lower-case, fold curly punctuation to straight, collapse whitespace. Accents are kept:
    /// "péremption" and "peremption" are different strings and only the first is in the vocabulary,
    /// which is the correct trade — folding accents here would also fold them in the languages
    /// where they distinguish words.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
