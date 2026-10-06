import Foundation

/// The "this came from an AI" disclosure, said once per session per surface (W08.3).
///
/// Article 50-style interaction transparency asks that a person be told they are looking at machine
/// output — but a disclosure repeated on every result is a disclosure nobody reads, and on a HUD it
/// is a disclosure that crowds out the result. So it is said the *first* time a session presents an
/// AI-generated assessment and not again, and the ledger that decides is a session-scoped object a
/// test can create fresh.
///
/// **A session is a launch.** Nothing in the app calls `reset()`: the shared ledger is created once
/// per process, so each surface is said at most once per launch (Plan HP P2). A conversation cue on
/// every wake word would be the disclosure nobody hears.
///
/// The wording is deliberately concrete about what it is not: naming the trained human this does not
/// replace is the part that changes behaviour.
final class AIDisclosureLedger {

    /// One surface family. Each gets its own first-time disclosure — a wearer who has only heard the
    /// assessment disclosure has not been told about anything else.
    enum Surface: String, CaseIterable {
        /// Structured-vision assessments: HECA, first-aid triage, instrument reading.
        case assessment
        /// Talking to the assistant: the first answer of the launch in Direct mode, and the start
        /// of a Gemini Live or OpenAI Realtime session (EU AI Act Art. 50(1), Plan HP).
        case conversation
        /// Live translation and translated captions, said to the wearer.
        case translation
        /// Said to the *other* person, in the language they are being translated into, when a live
        /// translation plays from the phone's loudspeaker (Plan HP P2). Not the wearer's to switch
        /// off: the person it is for never chose the app. The caller speaks the target-language
        /// rendering (`TranslationDisclosureLanguage.listenerLine`); `text(for:)` is its English.
        case translationForListener
    }

    /// Whether the once-ever introduction — the longer `.conversation` line — has been given on this
    /// install. Its own persisted done-marker, separate from every setting: the introduction is
    /// not a preference, so there is nothing to toggle, and turning the short cue off never skips
    /// it.
    struct IntroductionMarker {
        let isGiven: () -> Bool
        let markGiven: () -> Void

        static let userDefaultsKey = "aiConversationIntroductionGiven"

        /// The install's own marker.
        static let standard = IntroductionMarker(
            isGiven: { UserDefaults.standard.bool(forKey: userDefaultsKey) },
            markGiven: { UserDefaults.standard.set(true, forKey: userDefaultsKey) })

        /// A marker that lives only as long as the ledger, for tests.
        static func inMemory(given: Bool) -> IntroductionMarker {
            final class Box { var given: Bool; init(_ given: Bool) { self.given = given } }
            let box = Box(given)
            return IntroductionMarker(isGiven: { box.given }, markGiven: { box.given = true })
        }
    }

    /// The app-wide ledger: one per launch.
    static let shared = AIDisclosureLedger(introduction: .standard)

    private var delivered: Set<Surface> = []
    private let lock = NSLock()
    private let introduction: IntroductionMarker

    /// A fresh session. The default marker says the introduction has already been given, so a
    /// ledger made without one behaves as every launch after the first.
    init(introduction: IntroductionMarker = .inMemory(given: true)) {
        self.introduction = introduction
    }

    /// The disclosure text for a surface, exactly once per session. Returns `nil` on every later
    /// call, which is what makes "once per session" a property of the ledger rather than of each
    /// caller remembering to check.
    ///
    /// `cueEnabled` is the wearer's "Say 'Connecting to Avenkin AI'" switch
    /// (`Config.aiConnectionCueEnabled`). It silences the short `.conversation` and `.translation`
    /// lines and nothing else; a silenced surface is not marked, so turning the switch back on
    /// speaks it at the next opportunity.
    func consume(_ surface: Surface, cueEnabled: Bool = true) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered.contains(surface) else { return nil }
        let firstEver = surface == .conversation && !introduction.isGiven()
        guard let line = Self.line(for: surface, firstEver: firstEver, cueEnabled: cueEnabled) else {
            return nil
        }
        delivered.insert(surface)
        if firstEver { introduction.markGiven() }
        return line
    }

    /// Whether a surface has already disclosed in this session, without consuming it.
    func hasDelivered(_ surface: Surface) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return delivered.contains(surface)
    }

    /// Start a new session. The app never does (a session is a launch); tests do.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        delivered.removeAll()
    }

    /// The rule, with nothing remembered: which line a surface says, given whether this is the
    /// install's first conversation ever and whether the wearer's cue switch is on.
    static func line(for surface: Surface, firstEver: Bool, cueEnabled: Bool) -> String? {
        switch surface {
        case .assessment, .translationForListener:
            return text(for: surface)
        case .conversation:
            if firstEver { return conversationIntroduction }
            return cueEnabled ? text(for: .conversation) : nil
        case .translation:
            return cueEnabled ? text(for: .translation) : nil
        }
    }

    /// The first conversation this install ever has: who the wearer is talking to, and the one
    /// caveat that changes how they should treat the answer. Said whatever the cue switch says.
    static var conversationIntroduction: String {
        String(localized: "Connecting to Avenkin AI, your AI assistant. It can be wrong, so check anything important.")
    }

    /// Localised disclosure copy. One string per surface, no interpolation, so every translation is
    /// a whole sentence a translator can read.
    static func text(for surface: Surface) -> String {
        switch surface {
        case .assessment:
            return String(localized: "This is an AI assessment from the camera. It is not a substitute for a trained inspector or first aider.")
        case .conversation:
            return String(localized: "Connecting to Avenkin AI.")
        case .translation:
            return String(localized: "Starting Avenkin AI translation.")
        case .translationForListener:
            return String(localized: "This is a live AI translation by Avenkin AI.")
        }
    }
}
