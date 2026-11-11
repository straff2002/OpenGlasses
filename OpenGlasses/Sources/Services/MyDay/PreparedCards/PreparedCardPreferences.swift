import Foundation

// Plan KT §5.6 — the cards' switches, under My Day. Scalars in `UserDefaults`, read through
// `Config` like the rest of My Day's settings.

extension Config {
    /// "Ready-to-send cards": on while My Day is on, unless the wearer turns it off. Off returns
    /// My Day to rows only.
    static var preparedCardsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "preparedCardsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "preparedCardsEnabled") }
    }

    static func preparedCardKindKey(_ kind: PreparedCardKind) -> String { "preparedCardKind." + kind.rawValue }

    /// One switch per kind. Every kind is on by default except the opt-in ones (short night).
    static func preparedCardKindEnabled(_ kind: PreparedCardKind) -> Bool {
        UserDefaults.standard.object(forKey: preparedCardKindKey(kind)) as? Bool ?? !kind.isOptIn
    }

    static func setPreparedCardKind(_ kind: PreparedCardKind, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: preparedCardKindKey(kind))
    }

    /// "Show card text on the lock screen": off, so a card's notification says only that something
    /// is ready (§5.3).
    static var preparedCardLockScreenText: Bool {
        get { UserDefaults.standard.object(forKey: "preparedCardLockScreenText") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "preparedCardLockScreenText") }
    }

    /// Short night: slept less than this many minutes (default 6 h).
    static var preparedCardShortNightMinutes: Int {
        get { min(10 * 60, max(3 * 60, UserDefaults.standard.object(forKey: "preparedCardShortNightMinutes") as? Int ?? 6 * 60)) }
        set { UserDefaults.standard.set(min(10 * 60, max(3 * 60, newValue)), forKey: "preparedCardShortNightMinutes") }
    }

    /// Short night: a meeting before this minute of the day (default 09:30).
    static var preparedCardEarlyMeetingMinutes: Int {
        get { min(12 * 60, max(6 * 60, UserDefaults.standard.object(forKey: "preparedCardEarlyMeetingMinutes") as? Int ?? 9 * 60 + 30)) }
        set { UserDefaults.standard.set(min(12 * 60, max(6 * 60, newValue)), forKey: "preparedCardEarlyMeetingMinutes") }
    }

    /// The My Day page's "Use Google Calendar?" line was closed (§9.2). The settings row stays.
    static var preparedCardGoogleLineDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: "preparedCardGoogleLineDismissed") }
        set { UserDefaults.standard.set(newValue, forKey: "preparedCardGoogleLineDismissed") }
    }

    /// "Write drafts with" (§5.6): on this iPhone only, unless the wearer chooses their cloud model.
    static var preparedCardDraftWriter: DraftWriterChoice {
        get {
            UserDefaults.standard.string(forKey: "preparedCardDraftWriter").flatMap(DraftWriterChoice.init(rawValue:))
                ?? .onThisPhone
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "preparedCardDraftWriter") }
    }

    /// The cloud model the wearer agreed to for drafts ("Use {provider} to write drafts"), as its
    /// `DraftCloudTarget.consentKey`. Another model, or the same one at another address, asks again.
    static var preparedCardDraftCloudConsent: String? {
        get { UserDefaults.standard.string(forKey: "preparedCardDraftCloudConsent") }
        set { UserDefaults.standard.set(newValue, forKey: "preparedCardDraftCloudConsent") }
    }

    /// "Text customers from cards" (decision 8): on, unless the wearer turns it off or an
    /// organisation profile pins it off.
    static var preparedCardCustomerTexts: Bool {
        get {
            PolicyEnvelope.bool(.preparedCardCustomerTexts,
                                stored: UserDefaults.standard.object(forKey: "preparedCardCustomerTexts") as? Bool ?? true)
        }
        set {
            guard !PolicyEnvelope.isLocked(.preparedCardCustomerTexts) else { return }
            UserDefaults.standard.set(newValue, forKey: "preparedCardCustomerTexts")
        }
    }
}

extension PreparedCardSettings {
    /// The rules' settings as the wearer has them. `healthAvailable` says Health is on for this
    /// app: short night needs it as well as its own switch.
    static func current(isFieldAssistDay: Bool, healthAvailable: Bool) -> PreparedCardSettings {
        var settings = PreparedCardSettings()
        settings.enabledKinds = Set(PreparedCardKind.allCases.filter { kind in
            guard Config.preparedCardKindEnabled(kind) else { return false }
            if kind == .shortNight { return healthAvailable }
            return true
        })
        settings.shortNightThreshold = TimeInterval(Config.preparedCardShortNightMinutes * 60)
        let early = Config.preparedCardEarlyMeetingMinutes
        settings.earlyMeetingBefore = DateComponents(hour: early / 60, minute: early % 60)
        settings.isFieldAssistDay = isFieldAssistDay
        settings.customerTextsAllowed = Config.preparedCardCustomerTexts
        return settings
    }
}

extension PreparedCardKind {
    /// The kind's name in settings.
    var settingsName: String {
        switch self {
        case .leaveBy: String(localized: "Leave by", comment: "Settings: a kind of My Day card.")
        case .runningLate: String(localized: "Running late", comment: "Settings: a kind of My Day card.")
        case .shortNight: String(localized: "Short night", comment: "Settings: a kind of My Day card.")
        case .meetingFollowUp: String(localized: "Meeting follow-up", comment: "Settings: a kind of My Day card.")
        case .fitItIn: String(localized: "Fit it in", comment: "Settings: a kind of My Day card.")
        case .jobOnMyWay: String(localized: "On my way to a job", comment: "Settings: a kind of My Day card.")
        case .jobRunningLate: String(localized: "Running late to a job", comment: "Settings: a kind of My Day card.")
        case .jobReportOwed: String(localized: "Report not sent", comment: "Settings: a kind of My Day card.")
        case .jobPartsOwed: String(localized: "Parts not ordered", comment: "Settings: a kind of My Day card.")
        case .jobSignOffOwed: String(localized: "Sign-off owed", comment: "Settings: a kind of My Day card.")
        }
    }
}
