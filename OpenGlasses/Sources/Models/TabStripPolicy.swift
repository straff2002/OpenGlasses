import Foundation

/// The one action a tab other than Avenkin puts in the bottom strip, beside the mic (Plan KY).
///
/// The strip is Apple's tab view bottom accessory: above the tab bar while it is full size, and
/// beside the shrunk tab bar when a tab's content scrolls. On the Avenkin tab it carries the mic,
/// the buttons button and the way in to typing (Plan KX). Every other tab gets the mic too, so the
/// wearer can talk from anywhere, and at most one action of its own: the thing that tab is most
/// often opened to do.
enum TabStripLead: Equatable, CaseIterable {
    /// History: start a new conversation (the same as the list's New chat button).
    case newConversation
    /// Jobs, with nothing open: the start page.
    case newJob
    /// Jobs, with a job open: that job's page.
    case openJob
    /// Field Assist, with a job open on a manual's vault: ask a question of one of the manuals.
    case askManual
    /// Modes: the active mode, by name, opening its details.
    case activeMode

    /// The SF Symbol drawn for the action, alone when the strip is shrunk beside the tab bar.
    var systemImage: String {
        switch self {
        case .newConversation: return "square.and.pencil"
        case .newJob: return "plus"
        case .openJob: return "briefcase.fill"
        case .askManual: return "book.pages"
        case .activeMode: return "person.crop.circle"
        }
    }

    /// The action's words: drawn beside the symbol while the strip is full width, and always its
    /// spoken name. The active mode is named by the mode itself.
    func title(modeName: String?) -> String {
        switch self {
        case .newConversation: return String(localized: "New conversation")
        case .newJob: return String(localized: "New job")
        case .openJob: return String(localized: "Open job")
        case .askManual: return String(localized: "Ask a manual")
        case .activeMode: return modeName ?? String(localized: "Modes")
        }
    }
}

/// What the tabs know that decides their strip. Each tab reports its own part as it changes; the
/// root view adds the parts it already holds (which Modes slot is up, the active mode).
struct TabStripFacts: Equatable {
    /// History: the conversation store is locked behind Face ID.
    var historyLocked = false
    /// History: a conversation is open over the list. It has its own composer at the bottom, so
    /// the strip stands aside.
    var historyThreadOpen = false
    /// A Field Assist job is open (running or paused).
    var jobOpen = false
    /// Jobs: the list is showing, nothing pushed over it.
    var jobsAtRoot = true
    /// The Modes slot is Field Assist rather than the persona picker.
    var modesIsFieldAssist = false
    /// Field Assist: how many manuals on its shelf can be asked right now.
    var askableManuals = 0
    /// Modes: the active mode's name, when one is active.
    var activeModeName: String?
}

/// Which strip each tab shows (Plan KY). Pure, so the rules are tested without a tab view.
enum TabStripPolicy {
    /// The tab's own action, or nil for the mic alone. Avenkin's strip is its own (Plan KX) and
    /// never asks here.
    static func lead(for tab: MainTab, facts: TabStripFacts) -> TabStripLead? {
        switch tab {
        case .voice, .settings:
            return nil
        case .chat:
            return facts.historyLocked ? nil : .newConversation
        case .job:
            // Inside a job's page the job is already in front: the mic is enough.
            guard facts.jobsAtRoot else { return nil }
            return facts.jobOpen ? .openJob : .newJob
        case .modes:
            // A manual can be asked only on an open job's vault; until then Field Assist's own
            // first row is the job, so that is its strip action too.
            if facts.modesIsFieldAssist {
                if facts.askableManuals > 0 { return .askManual }
                return facts.jobOpen ? .openJob : .newJob
            }
            return facts.activeModeName == nil ? nil : .activeMode
        }
    }

    /// Whether the strip is up at all. Never during onboarding; on Avenkin, not while the typed
    /// bar holds the bottom of the screen; on History, not over an open conversation.
    static func showsStrip(on tab: MainTab, facts: TabStripFacts, onboarding: Bool,
                           typingOnVoice: Bool) -> Bool {
        guard !onboarding else { return false }
        switch tab {
        case .voice: return !typingOnVoice
        case .chat: return !facts.historyThreadOpen
        case .modes, .job, .settings: return true
        }
    }
}
