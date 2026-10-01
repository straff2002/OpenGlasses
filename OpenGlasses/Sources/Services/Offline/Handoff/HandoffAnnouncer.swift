import Foundation

/// What the wearer hears when the conversation moves onto the phone and back (Plan GE P0).
///
/// One line on the way out, one on the way back, nothing on flapping. A second announcement within
/// ``suppressionWindow`` of the last one is held back; a return that was held back is owed, and is
/// said at the next quiet moment once the window has passed (``owedLine(now:)``), so the wearer is
/// never left believing they are still offline.
///
/// It also absorbs the old unconditional offline line: the "your work is saved" sentence is only
/// said when the offline queue actually holds something.
///
/// Pure: the clock comes in as `now`; the caller speaks what comes back.
struct HandoffAnnouncer: Equatable {

    /// A second announcement within this long of the last one is suppressed.
    var suppressionWindow: TimeInterval = 120

    /// When the last line was actually said.
    private(set) var lastSpokenAt: Date?
    /// The wearer has been told the signal is gone and not yet told it is back.
    private(set) var wearerBelievesOffline = false

    init(suppressionWindow: TimeInterval = 120) {
        self.suppressionWindow = suppressionWindow
    }

    // MARK: - Copy

    /// Entering the phone with an on-device brain available.
    static let lostSignalLine = "I've lost signal. I'm running on the phone now, so I can do a bit less."
    /// Entering the phone with no way to think on it (handoff off, or nothing installed).
    static let lostSignalPlainLine = "I've lost signal."
    /// Back on the cloud.
    static let backOnlineLine = "Back online."
    /// Added only when queued work is waiting for the connection.
    static let workSavedSentence = "Your work is saved and will sync when you're back online."

    /// The first time a question is held because nothing on the phone can think it through.
    static let heldFirstLine = "I can't think that through without signal while the phone is locked. I'll answer when we're back online."
    /// A later question in the same episode replaces the held one.
    static let heldReplacedLine = "Got it. I'll answer that one instead when we're back online."
    /// A held question older than its time-to-live is dropped on return with one line.
    static let heldExpiredLine = "I didn't get to the question you asked while we were offline. It's been over half an hour, so ask again if you still need it."

    /// The notification body when a held question expires while still offline. Deliberately
    /// carries no question text: it lands on a lock screen.
    static let heldExpiredNotificationTitle = "Question not answered"
    static let heldExpiredNotificationBody = "A question you asked while offline wasn't answered. Ask again when you're back online."

    /// A live session lost its connection for good and the conversation moved to the phone.
    static let liveHandoffLine = "The live session lost its connection. I'll carry on here on the phone and reconnect when the signal's back."

    /// The HUD status chip while on the phone.
    static let phoneStatusChip = "Offline — running on the phone"
    /// The HUD status chip while offline with the handoff off.
    static let offlineStatusChip = "Offline"

    // MARK: - Decisions

    /// The line for moving onto the phone, or nil when it should not be said (already told, or
    /// within the suppression window of the last line).
    mutating func lineForEnteringPhone(now: Date, canThinkOnPhone: Bool, queuedItems: Int) -> String? {
        guard !wearerBelievesOffline else { return nil }
        guard !isSuppressed(now: now) else { return nil }
        lastSpokenAt = now
        wearerBelievesOffline = true
        let lead = canThinkOnPhone ? Self.lostSignalLine : Self.lostSignalPlainLine
        return queuedItems > 0 ? lead + " " + Self.workSavedSentence : lead
    }

    /// The line for a live session handed to the phone. Said even inside the suppression window —
    /// the session just ended under the wearer, and silence would read as a dead line — but only
    /// once per episode.
    mutating func lineForLiveHandoff(now: Date) -> String? {
        guard !wearerBelievesOffline else { return nil }
        lastSpokenAt = now
        wearerBelievesOffline = true
        return Self.liveHandoffLine
    }

    /// The line for moving back to the cloud, or nil when the wearer was never told they were
    /// offline, or it is too soon after the last line (then it is owed — see ``owedLine(now:)``).
    mutating func lineForReturn(now: Date) -> String? {
        guard wearerBelievesOffline, !isSuppressed(now: now) else { return nil }
        lastSpokenAt = now
        wearerBelievesOffline = false
        return Self.backOnlineLine
    }

    /// A return line held back by the suppression window, released once the window has passed.
    /// `onCloud` is whether the conversation is actually back on the cloud right now.
    mutating func owedLine(now: Date, onCloud: Bool) -> String? {
        guard onCloud else { return nil }
        return lineForReturn(now: now)
    }

    /// Another line that says the connection is back (the offline-queue sync line) was spoken: it
    /// counts as the return announcement.
    mutating func noteSpokenReturn(now: Date) {
        lastSpokenAt = now
        wearerBelievesOffline = false
    }

    /// The offline-queue sync line for a rising path edge, or nil when nothing is queued — the
    /// sync line is only ever about work that is actually waiting.
    static func syncLine(queuedItems: Int) -> String? {
        guard queuedItems > 0 else { return nil }
        return "Back online. Syncing \(queuedItems) item\(queuedItems == 1 ? "" : "s")."
    }

    private func isSuppressed(now: Date) -> Bool {
        guard let lastSpokenAt else { return false }
        return now.timeIntervalSince(lastSpokenAt) < suppressionWindow
    }
}
