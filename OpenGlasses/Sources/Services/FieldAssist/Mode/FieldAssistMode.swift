import Foundation

/// Field Assist as a *mode* of the phone (Plan HB), decided without SwiftUI.
///
/// Field Assist mode is on when the wearer's Field Assist switch is on — or an organisation's
/// edition puts the technician's view in force — **and** the entitlement grants it. While it is on,
/// the Modes tab is the Field Assist tab, the Jobs tab is present, the Field Assist quick actions are
/// in the grid and the home screen shows the job-day card. It is not a persona: personas choose the
/// model, prompt and wake phrase; Field Assist chooses what the phone is for.
///
/// Nothing here is stored. Every surface derives from the same four facts on every read, so turning
/// the switch off, an entitlement expiring and an organisation removing the edition all revert on
/// the next render with nothing left to undo.
enum FieldAssistMode {

    struct Inputs: Equatable {
        /// The wearer's own Field Assist switch (`Config.fieldAssistEnabled`).
        var switchOn = false
        /// Whether the entitlement evaluator grants Field Assist now (`Config.fieldAssistUnlocked`).
        var entitled = false
        /// Whether the store's entitlement check has run this launch
        /// (`StoreKitService.hasCheckedEntitlements`). Until it has, `entitled == false` means
        /// *unknown*, not *no*.
        var entitlementChecked = false
        /// Whether the organisation's edition is in force in the technician's view
        /// (`AdminGate.isRestricted`). The edition *is* Field Assist, whatever the switch says.
        var restricted = false
    }

    /// Whether Field Assist mode is on. "Switch or edition" is the reading `JobTabPresence` already
    /// uses, so the tab, the Jobs tab and the home card can never disagree about it.
    static func isOn(_ inputs: Inputs) -> Bool {
        (inputs.switchOn || inputs.restricted) && inputs.entitled
    }
}

// MARK: - The Modes tab

/// What the tab bar's Modes slot is (Plan HB). The slot keeps its identity — `MainTab.modes`, and
/// the privacy log's "modes" token — while its title, symbol and content follow Field Assist mode.
enum ModesTabPresentation: Equatable {
    /// The persona picker, with a Field Assist row on top when there is something useful to say.
    case modes(shortcut: FieldAssistShortcut?)
    /// The Field Assist tab, with the other modes under an accordion or not at all.
    case fieldAssist(otherModes: OtherModes)
    /// No slot: the edition's technician view with no Field Assist licence in force. Personas are
    /// not the technician's to choose, and there is no Field Assist to show instead.
    case hidden

    /// The Modes tab's way to Settings › Field Assist, when Field Assist is off.
    enum FieldAssistShortcut: Equatable {
        /// Entitled and switched off.
        case turnOn
        /// Never entitled. The existing upsell path; Settings › Field Assist holds the paywall.
        case unlock
        /// The switch is on but the entitlement has ended.
        case lapsed

        var title: String { "Field Assist" }

        var subtitle: String {
            switch self {
            case .turnOn: return "Turn on for jobs, scenarios and manuals"
            case .unlock: return "Unlock for grounded field-engineer guidance"
            case .lapsed: return "Your Field Assist access has ended"
            }
        }

        /// A lock beside the row when it leads to a paywall rather than a switch.
        var showsLock: Bool { self != .turnOn }

        var footer: String {
            switch self {
            case .turnOn:
                return "Turned on, this tab becomes Field Assist: your vault's scenarios, your manuals and your jobs, with these modes tucked underneath."
            case .unlock, .lapsed:
                return "Hands-free, domain-grounded guidance for field engineers — load a knowledge vault and run grounded, audited jobs."
            }
        }

        /// The row as one VoiceOver sentence.
        var spoken: String { "\(title). \(subtitle)" }
    }

    enum OtherModes: Equatable {
        /// Personas under a collapsed accordion at the bottom of the tab.
        case accordion
        /// The edition's technician view: the organisation chose the persona and the model.
        case hidden
    }

    /// The whole rule.
    static func resolve(_ inputs: FieldAssistMode.Inputs) -> ModesTabPresentation {
        if inputs.restricted {
            return inputs.entitled ? .fieldAssist(otherModes: .hidden) : .hidden
        }
        if FieldAssistMode.isOn(inputs) { return .fieldAssist(otherModes: .accordion) }
        if inputs.entitled { return .modes(shortcut: .turnOn) }
        // Nothing is drawn on a guess: an unresolved entitlement could be about to say yes.
        guard inputs.entitlementChecked else { return .modes(shortcut: nil) }
        return .modes(shortcut: inputs.switchOn ? .lapsed : .unlock)
    }

    var showsTab: Bool { self != .hidden }

    var isFieldAssist: Bool {
        if case .fieldAssist = self { return true }
        return false
    }

    /// The tab's spoken name, which is also its VoiceOver label and the UI tests' handle.
    var title: String { isFieldAssist ? "Field Assist" : MainTab.modes.title }

    /// The Field Assist mark is the dock tile's and the CarPlay jobs tab's symbol.
    static let fieldAssistSymbol = "wrench.and.screwdriver.fill"

    var systemImage: String { isFieldAssist ? Self.fieldAssistSymbol : MainTab.modes.systemImage }

    /// Where the selection lands once the slot is what `presentation` says. Only a slot that went
    /// away moves anybody, and it moves them home rather than to whatever is next along the bar.
    static func selection(_ selected: MainTab, after presentation: ModesTabPresentation) -> MainTab {
        guard selected == .modes, !presentation.showsTab else { return selected }
        return .voice
    }
}

// MARK: - Scenarios

/// What tapping a scenario (one of the active vault's procedures) does (Plan HB).
///
/// **An open job is never ended by a tap here.** The old Modes panel ended whatever job was open
/// before starting a session for the scenario; a job is closed through its own close sequence, with
/// its evidence review and its sign-off, and nowhere else.
enum FieldAssistScenarioStart: Equatable {
    /// No job is open: start one on this vault through the job flow, then run the procedure.
    case startJob
    /// A job is open on this vault: run the procedure inside it.
    case runInOpenJob(label: String)
    /// Not possible now, and why.
    case blocked(reason: String)

    struct OpenJob: Equatable {
        let vaultId: String
        let vaultName: String
        /// "Job 1005" or "the open job" — how the job is named to the technician.
        let label: String
    }

    static func decide(vaultId: String, vaultName: String, vaultUnlocked: Bool,
                       openJob: OpenJob?) -> FieldAssistScenarioStart {
        if let openJob {
            guard openJob.vaultId == vaultId else {
                return .blocked(reason: "\(openJob.label) is open on \(openJob.vaultName). "
                                + "Close it before running a scenario from \(vaultName).")
            }
            return .runInOpenJob(label: openJob.label)
        }
        guard vaultUnlocked else {
            return .blocked(reason: "\(vaultName) is locked. Unlock it under Settings → Field Assist "
                            + "before starting a job.")
        }
        return .startJob
    }

    /// The confirmation's button, for a scenario titled `scenario`.
    func confirmButton(_ scenario: String) -> String? {
        switch self {
        case .startJob: return "Start a job and run \(scenario)"
        case .runInOpenJob(let label): return "Run in \(label)"
        case .blocked: return nil
        }
    }

    /// The confirmation's message.
    func message(_ scenario: String, vaultName: String) -> String {
        switch self {
        case .startJob:
            return "Starts a Field Assist job on \(vaultName) and runs \u{201C}\(scenario)\u{201D}."
        case .runInOpenJob(let label):
            return "Runs \u{201C}\(scenario)\u{201D} as part of \(label)."
        case .blocked(let reason):
            return reason
        }
    }
}

// MARK: - The home screen's day card

/// Which day card the home screen draws (Plan HB): the job-day card whenever Field Assist mode is
/// on — whatever My Day's switch says — and otherwise My Day where it is placed. Never both.
enum HomeDayCard: Equatable {
    /// The technician's day. `showsPersonal` folds My Day's own items in below the job admin.
    case jobDay(showsPersonal: Bool)
    case myDay
    case none

    /// - Parameters:
    ///   - personalLocked: the edition's technician view has Connections — where My Day's switch
    ///     lives — locked. A phone the organisation manages does not put personal items on the work
    ///     card unless the organisation opened the category that governs them.
    ///   - surfaceFree: the conversation zone is not yielding to a turn or captions
    ///     (`HomeSurfaceVisibility.showsMyDay(state:captionsActive:)`).
    static func resolve(fieldAssistOn: Bool, myDayEnabled: Bool, myDayOnHome: Bool,
                        personalLocked: Bool, surfaceFree: Bool) -> HomeDayCard {
        guard surfaceFree else { return .none }
        let myDayPlaced = MyDayHomePlacement.isShown(enabled: myDayEnabled, onHome: myDayOnHome)
        if fieldAssistOn { return .jobDay(showsPersonal: myDayPlaced && !personalLocked) }
        return myDayPlaced ? .myDay : .none
    }
}
