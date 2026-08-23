import Foundation

/// One thing the app needs to tell the wearer, from wherever it happened.
///
/// Built after a device session on 2026-08-23 in which **four separate bugs turned out to be the
/// same bug**: the app worked out exactly what was wrong and dropped the answer before it reached
/// the screen. A Gemini Live socket close carried the server's own reason and only the reconnect
/// scheduler saw it. A registration error was rendered raw into a status capsule sized for two
/// words, cutting the word that showed it was benign. The camera button wrote its failures to a
/// channel live mode never read — and the button exists only in live mode. Camera stream errors
/// were mapped to good copy ("Glasses are too hot", "hinges are closed") and then logged and
/// discarded unless a photo capture happened to be pending.
///
/// Each cost a rebuild cycle to recover information the code already had, and none was visible from
/// a desk. The pattern is not carelessness in four places: every subsystem owned its own error
/// channel and every view chose which channels to read, so a new failure path is invisible **by
/// default**. That is the wrong default, and this type is the fix.
struct AppNotice: Equatable, Identifiable {

    enum Severity: Int, Comparable {
        /// Something the wearer can clear right now — a doff pausing the stream, hinges closed.
        case advisory = 0
        /// Something failed and they should know, but the app carries on.
        case warning = 1
        /// The thing they asked for did not happen.
        case error = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Where it came from, and the replacement key: a source's newer notice replaces its older one,
    /// so a subsystem reporting repeatedly cannot bury everything else.
    enum Source: String {
        case camera
        case liveSession
        case glasses
        case app
    }

    let id: UUID
    let text: String
    let severity: Severity
    let source: Source
    /// Seconds since the reference date, injected rather than read from a clock inside, so expiry
    /// is testable.
    let postedAt: TimeInterval

    init(id: UUID = UUID(), text: String, severity: Severity, source: Source, postedAt: TimeInterval) {
        self.id = id
        self.text = text
        self.severity = severity
        self.source = source
        self.postedAt = postedAt
    }

    static func == (lhs: AppNotice, rhs: AppNotice) -> Bool {
        lhs.text == rhs.text && lhs.severity == rhs.severity
            && lhs.source == rhs.source && lhs.postedAt == rhs.postedAt
    }
}
