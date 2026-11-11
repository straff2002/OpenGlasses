import Foundation

/// Plan KT P4 — the Today glance's Medical Compliance rule, applied to the day's cards.
///
/// The Today glance on the lens and Today on the watch (Plan KS, `WatchTodayBuilder`) withhold
/// what an appointment is, and where, under **any** Medical Compliance mode (Local Only or not):
/// they show times and counts only. A card is drawn from the same calendar, so the lens, the watch
/// and speech withhold the same things from it:
///
/// | Kind | Withheld | Kept |
/// |---|---|---|
/// | leave by, running late | the event's title (the subject) | the times, travel, weather, the recipient |
/// | short night | the meeting's title (headline and subject), and the draft's text, which names it | the meeting's time, the proposed time, the organiser |
/// | meeting follow-up | the event's title, the agreed items (what the meeting was about), and the draft's text, which carries both | "3 things agreed", the recipients |
/// | fit it in, every job kind | nothing | everything, as the job day's own lens and watch surfaces show it |
///
/// The phone's My Day page is the wearer's own screen, and the existing My Day page shows titles
/// under Medical Compliance, so the page is unchanged. The draft itself is never altered: staging
/// still puts the whole message on the phone, where the wearer reads it before tapping Send.
enum PreparedCardMedicalWithholding {

    /// Whether `mode` withholds: any Medical Compliance mode, as the Today glance.
    static func applies(_ mode: MedicalEgressGuard.Mode) -> Bool { mode.hipaaMode }

    /// The live reading.
    static var isOn: Bool { applies(MedicalEgressGuard.currentMode()) }

    /// The kinds drawn from a calendar event, whose subject is the event's title.
    static let calendarKinds: Set<PreparedCardKind> = [.leaveBy, .runningLate, .shortNight, .meetingFollowUp]

    /// The kinds whose draft names the meeting, so its text is withheld with the title.
    static let draftNamesMeeting: Set<PreparedCardKind> = [.shortNight, .meetingFollowUp]

    /// Short night's headline without the meeting's title.
    static var moveMeetingHeadline: String {
        String(localized: "Ask to move a meeting",
               comment: "Glasses, watch and speech: a card's headline with the meeting's name withheld under Medical Compliance.")
    }

    /// Stands in for a draft's text on the lens and the watch.
    static var draftHiddenLine: String {
        String(localized: "Hidden here while Medical Compliance is on. Read it on your phone.",
               comment: "Glasses and watch: stands in for a drafted message that names an appointment, under Medical Compliance.")
    }

    /// The card as the lens, the watch and speech may show it while `withholding`. Its id, actions,
    /// draft, urgency and times are unchanged, so a press on it acts on the real card.
    static func shown(_ card: PreparedCard, withholding: Bool) -> PreparedCard {
        guard withholding, calendarKinds.contains(card.kind) else { return card }
        let headline = card.kind == .shortNight ? moveMeetingHeadline : card.headline
        let facts = card.kind == .meetingFollowUp ? [] : card.facts
        return PreparedCard(id: card.id, headline: headline, subject: nil, signals: card.signals, facts: facts,
                            primary: card.primary, secondary: card.secondary, draft: card.draft,
                            urgency: card.urgency, dueAt: card.dueAt, validUntil: card.validUntil,
                            sensitivity: card.sensitivity, absorbs: card.absorbs)
    }

    /// Whether the card's draft text is withheld while `withholding`.
    static func withholdsDraftText(_ card: PreparedCard, withholding: Bool) -> Bool {
        withholding && card.draft != nil && draftNamesMeeting.contains(card.kind)
    }
}
