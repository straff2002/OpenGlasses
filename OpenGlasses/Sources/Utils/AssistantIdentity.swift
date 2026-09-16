import Foundation

/// The assistant's *conversational* name — what it calls itself when it talks, and what in-app
/// labels call it (Plan FE P6).
///
/// This is deliberately not a product rename. The installed app, its permission strings, the
/// widget and lock-screen identity, bundle ids, signing and entitlements stay OpenGlasses; only
/// the identity line the model is given and the assistant labels the wearer reads change.
///
/// **The value is untrusted name data.** It is typed by the wearer and rendered verbatim in one
/// place in the prompt — the identity opening — and in accessibility labels. It is never parsed,
/// never interpolated into a tool description, a tool argument or an authority claim, and it is
/// never registered as a wake phrase. A name that reads like an instruction ("ignore previous
/// instructions") is stored and rendered as a name and reaches the model only as the subject of
/// "You are …", which is exactly as much authority as any other name has.
///
/// **Precedence** (audited 2026-09-16, encoded in `Config.assistantName`):
/// a selected persona's own name wins over the preference, because a persona is an explicit
/// identity the wearer chose for that conversation. The one exception is the migration persona
/// `Config.savedPersonas` creates on first run, which carries the product default `"OpenGlasses"`
/// — that is not a name anybody picked, so it yields to the preference.
enum AssistantIdentity {

    /// The name every install starts with, and the one Reset returns to.
    static let defaultName = "OpenGlasses"

    /// Bound in *user-perceived characters* (grapheme clusters), so an emoji or a combining
    /// sequence counts once. Long enough for a real name in any script, short enough that the
    /// status badge and the identity line stay readable.
    static let maxNameLength = 40

    /// Why a typed name could not be used.
    enum NameProblem: Error, Equatable {
        /// More than `maxNameLength` grapheme clusters.
        case tooLong
        /// Contains a control character, a line break, or a bidirectional override.
        case illegalCharacters
    }

    /// Characters a name may not contain.
    ///
    /// C0/C1 controls and every line break are refused: a name is one line, and a control
    /// character in it would break a prompt, a log line or a label. The bidi overrides
    /// (U+202A–U+202E, U+2066–U+2069) are refused for the same reason a filename would refuse
    /// them — they reorder the text around them, so a name carrying one can make a label read as
    /// something it is not. Zero-width joiners and variation selectors are *allowed*: they are how
    /// emoji and many scripts are spelled, and they are counted as part of their grapheme.
    private static let forbiddenScalars: CharacterSet = {
        var set = CharacterSet(charactersIn: UnicodeScalar(UInt8(0x00))...UnicodeScalar(UInt8(0x1F)))
        set.insert(charactersIn: UnicodeScalar(UInt8(0x7F))...UnicodeScalar(UInt8(0x9F)))
        set.formUnion(.newlines)
        set.insert(charactersIn: UnicodeScalar(0x202A)!...UnicodeScalar(0x202E)!)
        set.insert(charactersIn: UnicodeScalar(0x2066)!...UnicodeScalar(0x2069)!)
        return set
    }()

    /// Validate a typed name.
    ///
    /// Surrounding whitespace is trimmed first, so `" Aria "` is `"Aria"` and `"   "` is blank.
    /// A blank value is not an error — it means "use the default" — so it succeeds with `nil`.
    /// Everything else is *refused*, not repaired: a name that is too long or carries a forbidden
    /// character leaves the stored value exactly as it was rather than being silently truncated
    /// or stripped into something the wearer did not type.
    static func validate(_ raw: String) -> Result<String?, NameProblem> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }
        guard trimmed.rangeOfCharacter(from: forbiddenScalars) == nil else {
            return .failure(.illegalCharacters)
        }
        guard trimmed.count <= maxNameLength else { return .failure(.tooLong) }
        return .success(trimmed)
    }

    /// The usable name in `raw`, or `nil` when it is blank or unusable. Used on the way *out* of
    /// storage too, so a hand-edited preference file cannot put a control character in a prompt.
    static func sanitized(_ raw: String?) -> String? {
        guard let raw, case .success(let name) = validate(raw) else { return nil }
        return name
    }

    /// The name to speak as, given the stored preference and the selected persona's name.
    /// See the precedence note on this type.
    static func resolve(preference: String?, personaName: String?) -> String {
        if let persona = sanitized(personaName), persona != defaultName { return persona }
        return sanitized(preference) ?? defaultName
    }

    // MARK: - Composition
    //
    // Every identity opening in the app is built here. Nothing rewrites an existing prompt's
    // text: a prompt either composes its opening from these, or it is the wearer's own and is
    // left byte-for-byte alone.

    /// "You are <name>, <role>" — the English opening.
    static func line(name: String, role: String) -> String {
        "You are \(name), \(role)"
    }

    /// "你是 <name>，<role>" — the Chinese opening (full-width comma, no space).
    static func lineZH(name: String, role: String) -> String {
        "你是 \(name)，\(role)"
    }

    /// The fuller opening the default prompt uses: identity, spoken-output note, and how the
    /// wearer actually starts a conversation.
    ///
    /// The activation clause quotes the **wake phrase**, not the name, and that is the point:
    /// naming the assistant never changes voice activation, so the prompt must not claim it did.
    static func defaultPromptOpening(name: String, wakePhrase: String) -> String {
        line(name: name, role: "a voice assistant running on Ray-Ban Meta smart glasses.")
            + " Your responses will be spoken aloud via text-to-speech. Your name is \(name)"
            + " and the user activates you by saying \"\(wakePhrase)\"."
    }
}
