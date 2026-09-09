import Foundation

/// The "this came from an AI" disclosure, said once per session per surface (W08.3).
///
/// Article 50-style interaction transparency asks that a person be told they are looking at machine
/// output — but a disclosure repeated on every result is a disclosure nobody reads, and on a HUD it
/// is a disclosure that crowds out the result. So it is said the *first* time a session presents an
/// AI-generated assessment and not again, and the ledger that decides is a session-scoped object a
/// test can create fresh.
///
/// The wording is deliberately concrete about what it is not: naming the trained human this does not
/// replace is the part that changes behaviour.
final class AIDisclosureLedger {

    /// One surface family. Each gets its own first-time disclosure — a wearer who has only heard the
    /// assessment disclosure has not been told about anything else.
    enum Surface: String, CaseIterable {
        /// Structured-vision assessments: HECA, first-aid triage, instrument reading.
        case assessment
    }

    /// The app-wide ledger. Session-scoped in practice: it is reset at launch and whenever the
    /// wearer starts a new conversation.
    static let shared = AIDisclosureLedger()

    private var delivered: Set<Surface> = []
    private let lock = NSLock()

    init() {}

    /// The disclosure text for a surface, exactly once per session. Returns `nil` on every later
    /// call, which is what makes "once per session" a property of the ledger rather than of each
    /// caller remembering to check.
    func consume(_ surface: Surface) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard delivered.insert(surface).inserted else { return nil }
        return Self.text(for: surface)
    }

    /// Whether a surface has already disclosed in this session, without consuming it.
    func hasDelivered(_ surface: Surface) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return delivered.contains(surface)
    }

    /// Start a new session — a fresh launch, or a new conversation.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        delivered.removeAll()
    }

    /// Localised disclosure copy. One string per surface, no interpolation, so every translation is
    /// a whole sentence a translator can read.
    static func text(for surface: Surface) -> String {
        switch surface {
        case .assessment:
            return String(localized: "This is an AI assessment from the glasses camera. It is not a substitute for a trained inspector or first aider.")
        }
    }
}
