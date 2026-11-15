import Foundation

/// Why a private conversation did not start (Plan LU §2). Content-free, so it can be the payload of
/// the `PrivacyLog` line a refused start leaves.
enum PrivateStartRefusal: String, Equatable, Sendable, CaseIterable {
    /// A Field Assist job is open, or the conversation open now belongs to a job or a debrief: its
    /// record has to be complete.
    case jobOpen
    /// The organisation's profile has switched private conversations off (decision 6).
    case organisationSwitchedOff
    /// The wearer switched private conversations off in Settings.
    case switchedOffInSettings
    /// A Live session is running. One must be started private, not switched part-way, because the
    /// provider already holds its earlier turns.
    case liveRunning

    /// What the wearer is told, spoken and shown.
    var reason: String {
        switch self {
        case .jobOpen:
            return String(localized: "Not during a job: its record has to be complete. End the job first.",
                          comment: "Spoken and shown when the wearer asks for a private conversation while a Field Assist job is open.")
        case .organisationSwitchedOff:
            return String(localized: "Your organisation has switched private conversations off.",
                          comment: "Spoken and shown when the wearer asks for a private conversation and their organisation's profile has switched them off.")
        case .switchedOffInSettings:
            return String(localized: "Private conversations are switched off in Settings.",
                          comment: "Spoken and shown when the wearer asks for a private conversation after switching them off in Settings.")
        case .liveRunning:
            return String(localized: "A live session can't go private part-way. Stop it first.",
                          comment: "Spoken and shown when the wearer asks for a private conversation while a live voice session is running.")
        }
    }
}

/// What starting a private conversation is decided on (Plan LU §2).
struct PrivateStartConditions: Equatable, Sendable {
    /// A Field Assist job is open (running or paused, not yet finished).
    var jobOpen = false
    /// The conversation open now is a job's or a debrief's.
    var activeThreadBelongsToJob = false
    /// The organisation's profile pins `SettingKey.privateConversationsAllowed` off.
    var organisationPinnedOff = false
    /// `Config.privateConversationsAllowed`, the wearer's own switch (clamped by the profile).
    var allowedInSettings = true
    /// A Live session is running.
    var liveRunning = false

    /// The refusal, or nil when a private conversation may start. Pure. A job comes first: it
    /// refuses whatever the settings say.
    var refusal: PrivateStartRefusal? {
        if jobOpen || activeThreadBelongsToJob { return .jobOpen }
        if organisationPinnedOff { return .organisationSwitchedOff }
        if !allowedInSettings { return .switchedOffInSettings }
        if liveRunning { return .liveRunning }
        return nil
    }
}

/// The lines a private conversation says (Plan LU §7).
enum PrivateConversationLines {

    /// Said at the start when a question followed the phrase, before the answer.
    static var startedWithQuestion: String {
        String(localized: "Private. I won't keep any of this.",
               comment: "Spoken when a private conversation starts with a question; the answer follows.")
    }

    /// Said when the phrase was said alone; then Avenkin listens.
    static var startedAlone: String {
        String(localized: "Private. Go ahead.",
               comment: "Spoken when a private conversation starts with nothing after the phrase; the assistant then listens.")
    }

    /// Said when a private conversation ends and the wearer is there to hear it.
    static var ended: String {
        String(localized: "Private conversation ended.",
               comment: "Spoken when a private conversation ends while the wearer is there to hear it.")
    }

    /// Added to a reply that tried to keep something the wearer asked to remember.
    static var wontRemember: String {
        String(localized: "This conversation is private, so I won't remember that. Want a reminder instead?",
               comment: "Appended to a reply when the wearer asked the assistant to remember something during a private conversation.")
    }

    /// Whether an end caused by `event` is said out loud. An end the wearer isn't there to hear
    /// (a disconnect, the app quitting, the quiet-gap timer) says nothing; a reset says its own line.
    static func announcesEnd(_ event: PrivateEndEvent) -> Bool {
        switch event {
        case .glassesDisconnected, .idleTimerFired, .appQuit, .appBackgrounded, .conversationReset:
            return false
        case .endPhrase, .endButton, .endOnWatch, .turnStarting, .startFresh, .otherConversationOpened,
             .jobStarted, .organisationSwitchedOff, .liveStopped:
            return true
        }
    }
}
