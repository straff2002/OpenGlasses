import Foundation

/// Plan KH P2: `SettingsGroupState` against the real settings. It holds no rule of its own: it reads
/// the switches, performs the writes the pure type decided, and writes through the setters the rows
/// always used, so a side effect stays where it was (Decision 9).
@MainActor
enum SettingsGroupStore {

    static func isOn(_ member: SettingsGroupMemberID) -> Bool {
        switch member {
        case .userMemory: return Config.userMemoryEnabled
        case .conversationHistory: return Config.conversationPersistenceEnabled
        case .memorySuggestions: return Config.memoryNudgesEnabled
        case .memoryEnrichment: return Config.brainEnrichmentEnabled
        case .myDay: return Config.myDayEnabled
        case .smartHome: return Config.smartHomeControlEnabled
        case .messaging: return Config.aiMessagingEnabled
        case .healthSummaries: return Config.healthSummariesEnabled
        case .firstAid: return Config.firstAidAssistEnabled
        case .shareHealth: return Config.shareHealthDataWithAI
        case .whatAvenkinRemembers, .goals, .activity, .myDayContents, .myDayDelivery, .scheduledTasks,
             .navigation, .parking, .music, .homeAssistant, .translation, .health:
            return false
        }
    }

    private static func write(_ member: SettingsGroupMemberID, _ value: Bool) {
        switch member {
        case .userMemory: Config.setUserMemoryEnabled(value)
        case .conversationHistory: Config.setConversationPersistenceEnabled(value)
        case .memorySuggestions: Config.setMemoryNudgesEnabled(value)
        case .memoryEnrichment: Config.setBrainEnrichmentEnabled(value)
        case .myDay: Config.setMyDayEnabled(value)
        case .smartHome: Config.smartHomeControlEnabled = value
        case .messaging: Config.aiMessagingEnabled = value
        case .healthSummaries: Config.healthSummariesEnabled = value
        case .firstAid: Config.firstAidAssistEnabled = value
        case .shareHealth: Config.setShareHealthDataWithAI(value)
        case .whatAvenkinRemembers, .goals, .activity, .myDayContents, .myDayDelivery, .scheduledTasks,
             .navigation, .parking, .music, .homeAssistant, .translation, .health:
            break
        }
    }

    static func state(of id: SettingsGroupID, in context: ManagedSettingsContext) -> SettingsGroupState {
        let group = SettingsGroupCatalog.group(id)
        var readings: [SettingsGroupMemberID: SettingsGroupState.Reading] = [:]
        for member in group.members {
            readings[member.id] = .init(
                isOn: isOn(member.id),
                presentation: SettingsGroupCatalog.presentation(of: member, in: context),
                medicalModeRefuses: member.hardDisabledInMedicalMode && Config.hipaaMode)
        }
        return SettingsGroupState(group: group, readings: readings, remembered: remembered(id))
    }

    static func setParent(_ on: Bool, of id: SettingsGroupID, in context: ManagedSettingsContext) {
        let change = state(of: id, in: context).parentChange(to: on)
        for write in change.writes { self.write(write.member, write.value) }
        Config.setSettingsGroupRemembered(change.remembered.map { $0.map(\.rawValue) }, group: id.rawValue)
    }


    /// One row's own switch. A member turned off by hand is not brought back by the parent.
    static func setMember(_ member: SettingsGroupMemberID, to value: Bool, in id: SettingsGroupID) {
        write(member, value)
        guard !value, var kept = remembered(id), kept.remove(member) != nil else { return }
        Config.setSettingsGroupRemembered(kept.map(\.rawValue), group: id.rawValue)
    }

    private static func remembered(_ id: SettingsGroupID) -> Set<SettingsGroupMemberID>? {
        Config.settingsGroupRemembered(group: id.rawValue)
            .map { Set($0.compactMap(SettingsGroupMemberID.init(rawValue:))) }
    }
}
