import Foundation

/// Plan HA C2 — what an organisation's Field Assist edition locks on the technician's phone.
///
/// It extends the edition (Plan CT 3b), not a second envelope: `ProfileApplier` resolves it into
/// `AdminPolicy.lockdown`, beside the edition and the administrator's credentials, so it rides the
/// verified profile in `PolicyEnvelope` and lifts with it. The rules, in CT's terms:
///
/// - **Deny by default.** Under the edition every settings category is locked unless it is pinned
///   open, open by default, or the profile opens it. A category added to the app later is locked
///   until someone decides otherwise — the same inverted form the edition's visibility uses.
/// - **Read-side.** Nothing is written. A lock is computed when a view asks, from the envelope in
///   force; removing the profile or opening an administrator session lifts it with nothing to put
///   back. Closed tools clamp `Config.disabledTools` on read and leave the person's own list alone.
/// - **Locked is visible.** A locked category is still a row, read-only, with "Managed by ⟨org⟩"
///   — never hidden, never silently changed.
/// - **Hidden is not forbidden, and locked is not a ceiling.** An administrator session
///   (`AdminGate`) unlocks every category; ceilings (`SettingKey`) still clamp whoever holds the
///   phone. Closed tools are the exception: they are the profile's statement about what this
///   phone does, like a ceiling, and an administrator session does not reopen them.
struct ManagedLockdown: Equatable, Sendable {
    /// Categories no profile may lock: the assistive surface (free forever, never withheld), the
    /// basics a technician reads the app with (theme, text and accent colour, language), and the
    /// self-test and problem report a technician needs to prove a managed phone has stopped working.
    static let pinnedOpen: Set<SettingsCategoryID> = [.accessibility, .lookAndFeel, .diagnostics]

    /// Open unless the profile locks it. Field Assist is the product the organisation bought; its
    /// own settings follow the organisation's per-key policy (`SettingKey` ceilings and starting
    /// values), and the master switch is locked separately (`ManagedArea.fieldAssistSwitch`).
    static let openByDefault: Set<SettingsCategoryID> = [.fieldAssist]

    /// The categories locked on the technician's phone.
    let lockedCategories: Set<SettingsCategoryID>
    /// Tool names the organisation closed. Empty by default — see the plan for why tools are not
    /// deny-by-default yet.
    let closedTools: Set<String>

    /// The lock set with nothing in the profile: everything but `pinnedOpen` and `openByDefault`.
    static let standard = ManagedLockdown(opening: [], locking: [], closedTools: [])

    init(opening: Set<SettingsCategoryID>, locking: Set<SettingsCategoryID>, closedTools: Set<String>) {
        var locked = Set(SettingsCategoryID.allCases)
            .subtracting(Self.pinnedOpen)
            .subtracting(Self.openByDefault)
        locked.formUnion(locking.subtracting(Self.pinnedOpen))
        locked.subtract(opening)
        lockedCategories = locked
        self.closedTools = closedTools
    }

    /// What the review sheet says about the lockdown beyond the edition's own line: the categories
    /// that differ from the standard set, and the tools closed. Empty for the standard set.
    var reviewLines: [String] {
        var lines: [String] = []
        let standard = Self.standard.lockedCategories
        let opened = standard.subtracting(lockedCategories)
        let locked = lockedCategories.subtracting(standard)
        func titles(_ ids: Set<SettingsCategoryID>) -> String {
            SettingsCategoryID.allCases.filter(ids.contains).map { SettingsCatalog.category($0).title }
                .joined(separator: ", ")
        }
        if !opened.isEmpty { lines.append("Left open: \(titles(opened))") }
        if !locked.isEmpty { lines.append("Also locked: \(titles(locked))") }
        if !closedTools.isEmpty { lines.append("Tools switched off: \(closedTools.sorted().joined(separator: ", "))") }
        return lines
    }

    // MARK: - Resolving the profile's request

    /// The longest tool name the profile may name; anything longer is not a tool.
    static let toolNameLimit = 64

    /// Resolve `ConfigProfile.lockdown`. Every entry it cannot use is a named drop.
    static func resolve(_ spec: ConfigProfile.LockdownSpec) -> (ManagedLockdown, [ProfileApplier.Drop]) {
        var drops: [ProfileApplier.Drop] = []
        func categories(_ raw: [String]?, field: String) -> Set<SettingsCategoryID> {
            var ids: Set<SettingsCategoryID> = []
            for name in raw ?? [] {
                if let id = SettingsCategoryID(rawValue: name) {
                    ids.insert(id)
                } else {
                    drops.append(.init(key: "lockdown.\(field)",
                                       reason: .invalidValue("\u{201C}\(name)\u{201D} is not a settings category this version of the app knows")))
                }
            }
            return ids
        }
        let opening = categories(spec.open, field: "open")
        let locking = categories(spec.lock, field: "lock")
        for id in locking.intersection(pinnedOpen).sorted(by: { $0.rawValue < $1.rawValue }) {
            drops.append(.init(key: "lockdown.lock",
                               reason: .invalidValue("\u{201C}\(id.rawValue)\u{201D} is never locked by an organisation")))
        }
        for id in opening.intersection(locking).sorted(by: { $0.rawValue < $1.rawValue }) {
            drops.append(.init(key: "lockdown.lock",
                               reason: .invalidValue("\u{201C}\(id.rawValue)\u{201D} is both opened and locked; it stays open")))
        }
        var tools: Set<String> = []
        for name in spec.closedTools ?? [] {
            if isPlausibleToolName(name) {
                tools.insert(name)
            } else {
                drops.append(.init(key: "lockdown.closedTools",
                                   reason: .invalidValue("\u{201C}\(name)\u{201D} is not a tool name")))
            }
        }
        return (ManagedLockdown(opening: opening, locking: locking, closedTools: tools), drops)
    }

    /// Lower-case letters, digits and underscores, the shape every native tool name has.
    static func isPlausibleToolName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= toolNameLimit
            && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}

/// Individual settings whose lock differs from their category's (Plan HA C2).
enum ManagedArea: String, CaseIterable, Sendable {
    /// Devices & Privacy › Glasses — pairing, connecting, which mic waits for the wake word, glasses
    /// updates. Open inside a locked Devices & Privacy: a technician has to get the glasses working.
    case glasses
    /// Devices & Privacy › How Your Requests Are Processed — a disclosure, not a setting. Open.
    case requestRouting
    /// Field Assist › Enable Field Assist — locked inside an open Field Assist: the edition implies
    /// Field Assist, and a technician switching it off would strand the phone's whole purpose.
    case fieldAssistSwitch
    /// The hub's owner controls — Simple Mode and Lock Settings. Locked under the edition; the
    /// technician's view is already simpler than Simple Mode (Plan CT 3b).
    case ownerControls

    /// The category the area sits in, or nil for the hub's own rows.
    var category: SettingsCategoryID? {
        switch self {
        case .glasses, .requestRouting: return .devices
        case .fieldAssistSwitch: return .fieldAssist
        case .ownerControls: return nil
        }
    }
}

/// How a category renders under the policy in force.
enum CategoryLock: Equatable, Sendable {
    /// Everything can be changed.
    case open
    /// The whole screen is read-only.
    case readOnly
    /// Locked, with these areas still open — the screen locks its other rows one by one.
    case partlyOpen(Set<ManagedArea>)

    var isLocked: Bool { self != .open }
}

/// Plan HA C2 — the lock decisions, as pure functions over the lockdown in force and whether the
/// technician's view is in force (`AdminGate.isRestricted`: an edition, no administrator session,
/// not an administrator phone).
enum SettingsLockPolicy {

    static func lock(_ category: SettingsCategoryID, lockdown: ManagedLockdown?, restricted: Bool) -> CategoryLock {
        guard restricted, let lockdown, lockdown.lockedCategories.contains(category) else { return .open }
        let open = Set(ManagedArea.allCases.filter {
            $0.category == category && !isLocked($0, lockdown: lockdown, restricted: restricted)
        })
        return open.isEmpty ? .readOnly : .partlyOpen(open)
    }

    static func isLocked(_ area: ManagedArea, lockdown: ManagedLockdown?, restricted: Bool) -> Bool {
        guard restricted, lockdown != nil else { return false }
        switch area {
        case .glasses, .requestRouting:
            return false
        case .fieldAssistSwitch, .ownerControls:
            return true
        }
    }

    /// Whether the organisation closed `tool`. Not lifted by an administrator session.
    static func isToolClosed(_ tool: String, lockdown: ManagedLockdown?) -> Bool {
        lockdown?.closedTools.contains(tool) ?? false
    }

    /// The person's disabled-tool list as every reader sees it: theirs, plus what is closed.
    static func effectiveDisabledTools(stored: Set<String>, lockdown: ManagedLockdown?) -> Set<String> {
        stored.union(lockdown?.closedTools ?? [])
    }

    /// What to store when a settings screen writes back a list it read through the clamp: the
    /// closed tools keep whatever the person had stored for them, so lifting the lockdown restores
    /// their own choice rather than the organisation's.
    static func storableDisabledTools(written: Set<String>, previouslyStored: Set<String>,
                                      lockdown: ManagedLockdown?) -> Set<String> {
        let closed = lockdown?.closedTools ?? []
        return written.subtracting(closed).union(previouslyStored.intersection(closed))
    }
}
