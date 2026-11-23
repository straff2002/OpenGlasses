import Foundation

/// Whether a meeting's notes are written by the model now, owed until it can run, or taken from
/// the phone's keyword extraction (Plan MX P4–P6). Pure.
///
/// The notes call goes where the meeting assistant's calls go: the active model through the
/// Medical Compliance routing rule (`LLMService.completeStateless`). So the provider here is the
/// one that rule resolves to — nil when there is no model or the rule refuses every model, which
/// is the fallback. A cloud model needs the network; offline is the fallback too. An on-device
/// MLX model cannot run while the app is in the background (Metal work is refused there), so its
/// notes are owed until the app is in front again. Apple's on-device model is a system service
/// and is asked directly; if it refuses, that is a failure like any other, and the fallback.
enum MeetingNotesRoutePolicy {

    struct Inputs: Equatable, Sendable {
        /// The provider the routing rule resolves to now; nil for no model, or none allowed.
        var provider: LLMProvider?
        /// That model's context window, where the app knows it.
        var contextTokens: Int?
        var isOnline: Bool
        var appActive: Bool
    }

    enum Decision: Equatable, Sendable {
        case writeNow
        case owe(MeetingNotesOweReason)
        case fallback(MeetingNotesFallbackReason)
    }

    static func decide(_ inputs: Inputs) -> Decision {
        guard let provider = inputs.provider else { return .fallback(.noModel) }
        switch provider {
        case .local:
            return inputs.appActive ? .writeNow : .owe(.appInBackground)
        case .appleOnDevice:
            return .writeNow
        default:
            return inputs.isOnline ? .writeNow : .fallback(.offline)
        }
    }
}

/// Why the notes are owed.
enum MeetingNotesOweReason: String, Codable, Sendable {
    /// The on-device model cannot run with the app in the background.
    case appInBackground
    /// The app stopped while the notes were being written.
    case interrupted
    /// Asked for inside a turn: written once that turn (and any that starts meanwhile) is over.
    case afterTurn

    /// A reason this build does not know (a record written by another build) reads as
    /// `interrupted`, so the record stays owed rather than the whole file being unreadable.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingNotesOweReason(rawValue: raw) ?? .interrupted
    }
}

/// Why the phone's keyword facts were used. A token for the log; never shown as it is.
enum MeetingNotesFallbackReason: String, Sendable {
    case notConfigured
    case noModel
    case offline
    case cannotRunNow
    case modelFailed
    case emptyReply
}

/// Where owed notes may be held, and what becomes of one (Plan MX P6). Pure.
///
/// Owed notes hold a copy of the meeting's transcript until the model can write them, so they are
/// held only where a kept caption session may be written: **Keep caption sessions** on, never in
/// Medical Compliance mode, and only for a summary that is saved as a note (the note is what they
/// complete). A record goes seven days after its meeting began, the same as a kept session; one
/// that has failed `attemptLimit` times goes too, and its note keeps the phone's notes.
enum MeetingNotesOwedPolicy {

    static let retentionDays = 7
    static let attemptLimit = 3
    /// At most this many meetings are owed at once; the oldest goes first.
    static let capacity = 3

    static func mayHold(saving: Bool, keepCaptionSessions: Bool, medicalCompliance: Bool) -> Bool {
        saving && keepCaptionSessions && !medicalCompliance
    }

    enum Disposition: Equatable, Sendable {
        case keep
        case discard(Discard)
    }

    enum Discard: String, Equatable, Sendable {
        case settingOff
        case complianceMode
        case expired
        case gaveUp
    }

    static func disposition(startedAt: Date, attempts: Int, now: Date,
                            keepCaptionSessions: Bool, medicalCompliance: Bool) -> Disposition {
        if medicalCompliance { return .discard(.complianceMode) }
        if !keepCaptionSessions { return .discard(.settingOff) }
        if startedAt <= now.addingTimeInterval(-Double(retentionDays) * 86_400) { return .discard(.expired) }
        if attempts >= attemptLimit { return .discard(.gaveUp) }
        return .keep
    }
}
