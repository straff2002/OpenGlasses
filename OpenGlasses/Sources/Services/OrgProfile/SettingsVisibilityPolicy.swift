import Foundation

// Plan HA C4 — what a managed phone shows the person holding it.
//
// Greig, 2026-10-04, after using an enrolled phone: "hide those settings that operators aren't
// allowed." C2 drew every locked setting greyed out with "Set by ⟨org⟩"; a technician scrolled past
// screens of switches they could not use. The one rule now:
//
//   **A setting the organisation has locked is not shown to the technician.** No row; a category
//   whose every row is locked is not a hub row; a page whose only control is locked is not linked.
//
// Two things keep that honest rather than secret:
//
//   - The hub's Organisation section says "Some settings are set by ⟨org⟩ and aren't shown", and
//     the organisation's page lists what is hidden and everything the profile sets. Hidden from
//     editing, never concealed from the person.
//   - `alwaysShown`: a lock on something the person needs to know regardless — a privacy
//     protection that is on, a disclosure — is drawn read-only instead of hidden.
//
// The administrator (an administrator session, or an administrator phone) sees everything: what
// the lockdown locks is open to them, and what still binds them (ceilings, closed tools) is drawn
// read-only with "Set by ⟨org⟩", as C2 drew it. An unmanaged phone is untouched: nothing is locked.
//
// Pure: every input is a value in `ManagedSettingsContext`, so the whole rule is tested headless.

/// Who is looking at Settings.
enum SettingsViewer: Equatable, Sendable {
    /// No profile in force (never enrolled, removed, or revoked). Nothing is locked.
    case unmanaged
    /// The person the organisation configured the phone for. On a profile without an edition this
    /// is whoever holds the phone: there is no administrator view to open.
    case technician
    /// An administrator session, or an administrator phone, under an edition.
    case administrator
}

/// Everything the decision reads, captured once per draw.
struct ManagedSettingsContext: Equatable, Sendable {
    /// A profile is in force (`PolicyEnvelope.isManaged`).
    var managed: Bool
    /// The edition's lockdown, or nil on a phone without an edition.
    var lockdown: ManagedLockdown?
    /// The technician's view of the edition is in force (`AdminGate.isRestricted`).
    var restricted: Bool
    /// The keys the profile pins (`ProfileApplier.Result.isLocked`).
    var lockedKeys: Set<SettingKey>

    static let unmanaged = ManagedSettingsContext(managed: false, lockdown: nil, restricted: false, lockedKeys: [])

    var viewer: SettingsViewer {
        // An edition decides by its own view; without one, a profile in force has no one but the
        // technician to show anything to.
        if lockdown != nil { return restricted ? .technician : .administrator }
        return managed ? .technician : .unmanaged
    }
}

/// Something on a settings screen that a lock can apply to.
enum ManagedSetting: Hashable, Sendable {
    /// A hub row, and the category screen behind it.
    case category(SettingsCategoryID)
    /// A named row whose lock differs from its category's (`ManagedArea`).
    case area(ManagedArea)
    /// Any other row of a category's screen — locked with the category, even where the category is
    /// partly open.
    case row(in: SettingsCategoryID)
    /// A control for a key the profile may pin.
    case key(SettingKey)
    /// A tool's switch.
    case tool(String)
}

/// How one setting is drawn.
enum SettingPresentation: Equatable, Sendable {
    case editable
    /// On screen, unchangeable, with the organisation named as the reason.
    case readOnly
    /// Not drawn, and not reachable — by touch, by VoiceOver, or by a link from elsewhere.
    case hidden

    var isShown: Bool { self != .hidden }
    var isEditable: Bool { self == .editable }
}

enum SettingsVisibilityPolicy {

    /// Locks drawn read-only even for the technician, because the person needs to know about them
    /// whatever the organisation chose:
    /// - **Blur Bystander Faces**, pinned on: the protection a bystander and the wearer are relying
    ///   on. Hiding it would leave nobody on the phone able to tell it is on.
    /// - **How Your Requests Are Processed**: a disclosure, not a setting. Never locked today
    ///   (`ManagedArea.requestRouting` is open); listed so a later lock cannot hide it.
    ///
    /// Everything else the person needs regardless of locks is already out of any lock's reach:
    /// Accessibility, Look & Feel and Diagnostics & Support (`ManagedLockdown.pinnedOpen`), About
    /// and the Organisation section (on the hub, not in a category), and the Glasses screen.
    /// - **Face Recognition**, pinned off (Plan HP P2): a protection for the people in front of the
    ///   glasses. The wearer is told it is off rather than left looking for a switch that is gone,
    ///   and the Enrolled Faces list beside it stays usable — forgetting a face never waits on a
    ///   setting.
    /// - **The "Connecting to Avenkin AI" cue**, pinned on (Plan HP P2): a disclosure, so the
    ///   person must be able to see it is being said.
    static let alwaysShown: Set<ManagedSetting> = [.key(.privacyFilterEnabled), .area(.requestRouting),
                                                   .key(.faceRecognitionEnabled),
                                                   .key(.aiConnectionCueEnabled)]

    /// Whether the organisation's policy stops whoever is looking from changing `setting`.
    static func isLocked(_ setting: ManagedSetting, in context: ManagedSettingsContext) -> Bool {
        switch setting {
        case .category(let id):
            // A partly open category still has rows the technician may use, so it stays a row.
            return SettingsLockPolicy.lock(id, lockdown: context.lockdown, restricted: context.restricted) == .locked
        case .area(let area):
            return SettingsLockPolicy.isLocked(area, lockdown: context.lockdown, restricted: context.restricted)
        case .row(let id):
            return SettingsLockPolicy.lock(id, lockdown: context.lockdown, restricted: context.restricted).isLocked
        case .key(let key):
            return context.lockedKeys.contains(key)
        case .tool(let name):
            return SettingsLockPolicy.isToolClosed(name, lockdown: context.lockdown)
        }
    }

    /// The rule: unlocked is editable; locked is hidden from the technician unless it is in
    /// `alwaysShown`; anything else locked is read-only.
    static func presentation(_ setting: ManagedSetting, in context: ManagedSettingsContext) -> SettingPresentation {
        guard isLocked(setting, in: context) else { return .editable }
        if context.viewer == .technician && !alwaysShown.contains(setting) { return .hidden }
        return .readOnly
    }

    /// The hub's category rows: Simple Mode's filter, then the lockdown's.
    static func hubCategories(simpleMode: Bool, in context: ManagedSettingsContext) -> [SettingsCategory] {
        SettingsCatalog.visible(simpleMode: simpleMode).filter {
            presentation(.category($0.id), in: context).isShown
        }
    }

    /// What the organisation's page lists as not shown on this phone, in hub order. Empty when
    /// nothing is hidden — and always for an administrator or an unmanaged phone.
    ///
    /// Pinned keys and closed tools are listed by the page's own "Locks" and "What this phone shows"
    /// sections, from the profile; this list is the settings screens the technician no longer sees.
    static func hiddenSummary(in context: ManagedSettingsContext) -> [String] {
        guard context.viewer == .technician else { return [] }
        var lines: [String] = []
        for id in SettingsCategoryID.allCases {
            let title = SettingsCatalog.category(id).title
            if presentation(.category(id), in: context) == .hidden {
                lines.append(title)
            } else if presentation(.row(in: id), in: context) == .hidden {
                lines.append("Parts of \(title)")
            }
        }
        for area in ManagedArea.allCases where presentation(.area(area), in: context) == .hidden {
            lines.append(area.hiddenDescription)
        }
        return lines
    }

    /// Whether the hub's Organisation section says that some settings aren't shown: something a
    /// settings screen would have drawn is hidden from the technician.
    static func hidesSettings(in context: ManagedSettingsContext) -> Bool {
        guard context.viewer == .technician else { return false }
        if !hiddenSummary(in: context).isEmpty { return true }
        // Ceilings have switches; profile-owned values (the organisation's name, its report route)
        // never had a row to hide.
        let ceilings = context.lockedKeys.filter {
            if case .ceiling = $0.kind { return true }
            return false
        }
        if ceilings.contains(where: { presentation(.key($0), in: context) == .hidden }) { return true }
        return !(context.lockdown?.closedTools.isEmpty ?? true)
    }
}

private extension ManagedArea {
    /// How the organisation's page names this area when it is hidden.
    var hiddenDescription: String {
        switch self {
        case .glasses: return "Glasses"
        case .requestRouting: return "How Your Requests Are Processed"
        case .fieldAssistSwitch: return "Turning Field Assist off"
        case .ownerControls: return "Simple Mode and Lock Settings"
        }
    }
}
