import Foundation

/// Plan KP §8: whose the Display is right now, as a reading rather than an error.
///
/// DAT gives an app no notification surface: an app draws only inside its own display session, and
/// while another app has the Display our session is (most likely) `paused`. Today's render path
/// treated that as a failure, started the session again and dropped the frame. The reading says
/// instead what the wearer is in:
///
/// - **`.ours`**: the lens is ours to draw on. A display asleep from inactivity is still ours.
/// - **`.inUse`**: the glasses are connected and worn, and our session is `paused` or a start was
///   refused. Nothing is drawn, nothing queues, and the session is never started again by us.
/// - **`.off`**: no display, the glasses are not connected, or they are off the face.
///
/// **Inputs.** The session state (`DisplaySessionReading`, from `MetaDisplayBackend`), the link
/// (`GlassesConnectionService.isConnected`: `linkState == .connected`, nothing else) and
/// `GlassesConnectionService.isWorn`. An unknown worn reading (`nil`) is not "taken off": only a
/// definite `false` is. **Folded is not an input:** the app does not read DAT's `hingeState`
/// (deliberately, see the DAT conventions), so a folded pair reads as whatever its link and worn
/// state say, which on today's glasses is "not worn".
///
/// **Backends.** Only the Meta Display has a session another app can take. The Even G2 backend
/// and the web mirror always read `.ours` (`GlassesDisplayService` never consults the session
/// for them), and the mirror is never what makes the reading `.inUse`.
enum DisplayAvailability: String, Equatable, CaseIterable {
    case ours
    case inUse
    case off

    static func read(hasDisplay: Bool, connected: Bool, worn: Bool?,
                     session: DisplaySessionReading) -> DisplayAvailability {
        guard hasDisplay, connected, worn != false else { return .off }
        if session.state == .paused || session.startRefused { return .inUse }
        return .ours
    }

    /// How the support report names it.
    var reportName: String {
        switch self {
        case .ours: return "ours"
        case .inUse: return "in use by another app"
        case .off: return "off"
        }
    }
}

/// The app's own copy of DAT's `DeviceSessionState`, so the reading and its tests are SDK-free
/// (the store build links no DAT). `MetaDisplayBackend` maps the SDK's case onto it.
enum DisplaySessionState: String, Equatable, CaseIterable {
    case idle, starting, started, paused, stopping, stopped
}

/// What the Meta display session last said: its state (`nil` when there is no session), and
/// whether our last start was refused while it was trying (§8 rule 1's "a start is refused").
struct DisplaySessionReading: Equatable {
    var state: DisplaySessionState?
    var startRefused = false

    init(state: DisplaySessionState? = nil, startRefused: Bool = false) {
        self.state = state
        self.startRefused = startRefused
    }

    /// A log token: the state's case name (or `none`), with `-refused` when a start was refused.
    var token: String {
        (state?.rawValue ?? "none") + (startRefused ? "-refused" : "")
    }

    /// How the support report names it.
    var reportName: String {
        let base = state.map { "session \($0.rawValue)" } ?? "no session"
        return startRefused ? base + ", start refused" : base
    }
}

/// Plan KP §8 rule 5: one spoken hint per stretch of `.inUse`. The first answer spoken while the
/// display is in use is followed by `line`; then nothing until the reading leaves `.inUse`. Never
/// after anything but an answer (an alert, a confirmation, a notice), never while the display is
/// `.off`, never when speech is being suppressed, and never with the setting off.
struct DisplayBusyHint: Equatable {
    /// The hint has played in the current stretch of `.inUse`.
    private(set) var givenThisStretch = false

    /// What follows the answer.
    static var line: String {
        String(localized: "Your display's busy. Say 'repeat', 'save that' or 'tell me more'.",
               comment: "Spoken once after an answer while another app has the glasses' display.")
    }

    /// The reading changed. Leaving `.inUse` ends the stretch, so the next one hints again.
    mutating func readingChanged(to availability: DisplayAvailability) {
        if availability != .inUse { givenThisStretch = false }
    }

    /// Whether the hint plays now, after an answer (`isAnswer`) was spoken. Taking it uses it up for
    /// the stretch.
    mutating func claim(availability: DisplayAvailability, isAnswer: Bool,
                        speechSuppressed: Bool, enabled: Bool) -> Bool {
        guard enabled, isAnswer, !speechSuppressed, availability == .inUse,
              !givenThisStretch else { return false }
        givenThisStretch = true
        return true
    }
}

/// Plan KP P1b: each change of reading, with its time and the session state behind it, for the
/// support report (P6 reads which session states DAT actually reports when another app takes the
/// Display). Bounded: the newest `capacity` changes. Case names only: nothing about the content
/// that was, or was not, shown.
struct DisplayAvailabilityLog: Equatable {
    struct Entry: Equatable {
        let at: Date
        let availability: DisplayAvailability
        let session: DisplaySessionReading
    }

    static let defaultCapacity = 20

    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int = DisplayAvailabilityLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    mutating func record(_ availability: DisplayAvailability, session: DisplaySessionReading, at: Date) {
        entries.append(Entry(at: at, availability: availability, session: session))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// The support report's lines, oldest first. Times are local wall-clock, as the wearer saw them.
    func reportLines(timeZone: TimeZone = .current) -> [String] {
        guard !entries.isEmpty else { return ["Display readings: none since launch"] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return ["Display readings (last \(entries.count), oldest first):"] + entries.map {
            "  \(formatter.string(from: $0.at)): \($0.availability.reportName) (\($0.session.reportName))"
        }
    }
}
