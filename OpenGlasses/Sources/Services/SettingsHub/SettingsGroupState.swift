import Foundation

/// Plan KH P2: what a group's parent toggle says and does (pure). Decisions 6 to 8 live here:
///
/// - A parent covers one consent. Off turns its members off. On restores what was on, and never
///   turns on a separate-consent member for the first time.
/// - A parent never writes a locked member, and never writes one Medical Compliance mode refuses.
/// - A locked member is not drawn, and a group with nothing left to draw is not drawn.
///
/// Nothing here touches `Config`. `SettingsGroupStore` reads the values in and performs the writes
/// through the existing setters, so their side effects stay where they are (Decision 9).
struct SettingsGroupState: Equatable, Sendable {

    struct Reading: Equatable, Sendable {
        var isOn: Bool
        var presentation: SettingPresentation
        var medicalModeRefuses = false
    }

    struct Write: Equatable, Sendable {
        let member: SettingsGroupMemberID
        let value: Bool
    }

    struct Change: Equatable, Sendable {
        let writes: [Write]
        /// What to remember after this change. Nil once it has been restored.
        let remembered: Set<SettingsGroupMemberID>?
    }

    let group: SettingsGroup
    let readings: [SettingsGroupMemberID: Reading]
    /// What was on when the parent last went off, or nil when there is nothing to restore.
    let remembered: Set<SettingsGroupMemberID>?

    private func reading(_ member: SettingsGroupMember) -> Reading {
        readings[member.id] ?? Reading(isOn: false, presentation: .hidden)
    }

    /// A parent may write this member.
    private func isWritable(_ member: SettingsGroupMember) -> Bool {
        member.isSwitch && reading(member).presentation.isEditable && !reading(member).medicalModeRefuses
    }

    /// The members to draw, in catalogue order.
    var drawnMembers: [SettingsGroupMember] {
        group.members.filter { reading($0).presentation.isShown }
    }

    var isDrawn: Bool { !drawnMembers.isEmpty }

    /// A parent is drawn only over a follower it can really write. A list otherwise.
    var hasParent: Bool {
        group.members.contains { $0.kind == .follows && isWritable($0) }
    }

    /// Whether the parent reads on: anything it covers is on. A separate consent is its own switch.
    var isOn: Bool {
        group.members.contains { $0.kind == .follows && isCounted($0) && reading($0).isOn }
    }

    private func isCounted(_ member: SettingsGroupMember) -> Bool {
        member.isSwitch && reading(member).presentation.isShown && !reading(member).medicalModeRefuses
    }

    /// "On · 3 of 4", "On" for a group that is one switch, "Off". Nil for a plain list.
    var summary: String? {
        guard hasParent else { return nil }
        guard isOn else { return String(localized: "Off") }
        let counted = group.members.filter(isCounted)
        guard counted.count > 1 else { return String(localized: "On") }
        let on = counted.filter { reading($0).isOn }.count
        return String(localized: "On · \(on) of \(counted.count)")
    }

    /// The writes for the parent going to `on`, and what to remember afterwards.
    func parentChange(to on: Bool) -> Change {
        let writable = group.members.filter(isWritable)
        guard on else {
            let wasOn = writable.filter { reading($0).isOn }
            return Change(writes: wasOn.map { Write(member: $0.id, value: false) },
                          remembered: Set(wasOn.map(\.id)))
        }
        var targets = writable.filter { remembered?.contains($0.id) ?? $0.onFirstTime }
        // A parent that turns nothing on would be a switch that springs back. Nothing to restore
        // for a follower means the followers' first-time set, and failing that the first of them.
        if !targets.contains(where: { $0.kind == .follows }) {
            let followers = writable.filter { $0.kind == .follows }
            let first = followers.filter(\.onFirstTime)
            targets += first.isEmpty ? Array(followers.prefix(1)) : first
        }
        return Change(writes: targets.filter { !reading($0).isOn }.map { Write(member: $0.id, value: true) },
                      remembered: nil)
    }
}
