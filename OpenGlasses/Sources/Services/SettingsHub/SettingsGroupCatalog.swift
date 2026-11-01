import Foundation

// Plan KH P2: the groups of the Everyday screen, by what you want done rather than how the app was
// built. Pure data and one pure rule (`presentation(of:in:)`), so the groups, their consents and
// their locks are asserted headlessly. `SettingsGroupState` holds what a parent toggle does.
//
// Two facts the shapes carry:
//
//   1. **A group has a parent toggle only if it has a real switch to follow.** Getting Around and
//      Translate have rows that open screens and nothing to switch on as a whole, so they are plain
//      lists. A parent there would be a switch that means nothing.
//   2. **Some things are never a `.follows` member:** face recognition, Agentic Features, and
//      sharing health data with the AI (Decision 7). The first two are not in any group. Sharing
//      and Memory Enrichment appear as `.separateConsent`, because each sends something off the
//      phone that the parent's own consent does not cover.

/// A group of the Everyday screen.
enum SettingsGroupID: String, CaseIterable, Sendable {
    case memory
    case myDayRoutines = "my-day-routines"
    case gettingAround = "getting-around"
    case homeMusicMessages = "home-music-messages"
    case translate
    case healthFitness = "health-fitness"
}

/// One row of a group. A switch's raw value is the `UserDefaults` key it already lives at.
enum SettingsGroupMemberID: String, CaseIterable, Sendable {
    // Switches.
    case userMemory = "userMemoryEnabled"
    case conversationHistory = "conversationPersistenceEnabled"
    case memorySuggestions = "memoryNudgesEnabled"
    case memoryEnrichment = "brainEnrichmentEnabled"
    case myDay = "myDayEnabled"
    case smartHome = "smartHomeControlEnabled"
    case messaging = "aiMessagingEnabled"
    case healthSummaries = "healthSummariesEnabled"
    case firstAid = "firstAidAssistEnabled"
    case shareHealth = "shareHealthDataWithAI"
    // Rows that open a screen.
    case whatAvenkinRemembers
    case goals
    case activity
    case myDayContents
    case myDayDelivery
    case scheduledTasks
    case navigation
    case parking
    case music
    case homeAssistant
    case translation
    case health
}

struct SettingsGroupMember: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Goes off with the parent, and comes back with it.
        case follows
        /// Its own consent. The parent's off turns it off like anything else, but the parent's on
        /// never turns it on for the first time.
        case separateConsent
        /// Opens a screen. The parent never writes it.
        case link
    }

    let id: SettingsGroupMemberID
    let title: String
    let kind: Kind
    /// Comes on with the parent when there is nothing to restore. Off for a member that is off by
    /// default because it does something unasked: Memory Suggestions speaks up by itself.
    var onFirstTime = false
    /// The key a profile may pin, where it has one.
    var settingKey: SettingKey?
    /// The tools an organisation may close to take this member away.
    var feature: AIFeature?
    /// Medical Compliance mode refuses what this switch allows, whatever it says. A parent neither
    /// writes it nor counts it, so nothing here can look like an override.
    var hardDisabledInMedicalMode = false
    /// A category this row reaches into. A row in Everyday is not a way round that category's lock.
    var reachesInto: SettingsCategoryID?

    var isSwitch: Bool { kind != .link }
}

struct SettingsGroup: Identifiable, Equatable, Sendable {
    let id: SettingsGroupID
    let title: String
    let members: [SettingsGroupMember]

    /// One switch that is the whole group: the parent is that switch, and it is not drawn twice.
    var parentIsTheOnlySwitch: Bool { members.filter(\.isSwitch).count == 1 }
}

enum SettingsGroupCatalog {

    /// The groups, in the order the screen draws them. Built on demand so titles follow the language.
    static var all: [SettingsGroup] { SettingsGroupID.allCases.map(describe) }

    static func group(_ id: SettingsGroupID) -> SettingsGroup { describe(id) }

    private static func describe(_ id: SettingsGroupID) -> SettingsGroup {
        switch id {
        case .memory:
            return SettingsGroup(id: id, title: String(localized: "Memory"), members: [
                .init(id: .userMemory, title: String(localized: "User Memory"), kind: .follows, onFirstTime: true),
                .init(id: .whatAvenkinRemembers, title: String(localized: "What Avenkin Remembers"), kind: .link),
                .init(id: .conversationHistory, title: String(localized: "Conversation History"), kind: .follows,
                      onFirstTime: true),
                .init(id: .memorySuggestions, title: String(localized: "Memory Suggestions"), kind: .follows),
                .init(id: .goals, title: String(localized: "Goals"), kind: .link),
                .init(id: .activity, title: String(localized: "Activity"), kind: .link),
                .init(id: .memoryEnrichment, title: String(localized: "Memory Enrichment"), kind: .separateConsent,
                      hardDisabledInMedicalMode: true),
            ])
        case .myDayRoutines:
            return SettingsGroup(id: id, title: String(localized: "My Day & Routines"), members: [
                .init(id: .myDay, title: String(localized: "My Day"), kind: .follows, onFirstTime: true),
                .init(id: .myDayContents, title: String(localized: "What's in My Day"), kind: .link),
                .init(id: .myDayDelivery, title: String(localized: "Scheduled Delivery"), kind: .link),
                .init(id: .scheduledTasks, title: String(localized: "Scheduled Tasks"), kind: .link,
                      settingKey: .agentModeEnabled, reachesInto: .intelligence),
            ])
        case .gettingAround:
            return SettingsGroup(id: id, title: String(localized: "Getting Around"), members: [
                .init(id: .navigation, title: String(localized: "Walking Navigation"), kind: .link),
                .init(id: .parking, title: String(localized: "Parking"), kind: .link),
            ])
        case .homeMusicMessages:
            return SettingsGroup(id: id, title: String(localized: "Home, Music & Messages"), members: [
                .init(id: .smartHome, title: String(localized: "AI Smart Home Control"), kind: .follows,
                      onFirstTime: true, feature: .smartHomeControl),
                .init(id: .messaging, title: String(localized: "AI Messaging"), kind: .follows, onFirstTime: true,
                      feature: .messaging, hardDisabledInMedicalMode: true),
                .init(id: .music, title: String(localized: "Music"), kind: .link),
                .init(id: .homeAssistant, title: String(localized: "Home Assistant"), kind: .link),
            ])
        case .translate:
            return SettingsGroup(id: id, title: String(localized: "Translate"), members: [
                .init(id: .translation, title: String(localized: "Translation"), kind: .link),
            ])
        case .healthFitness:
            return SettingsGroup(id: id, title: String(localized: "Health & Fitness"), members: [
                .init(id: .health, title: String(localized: "Health"), kind: .link),
                .init(id: .healthSummaries, title: String(localized: "Health Summaries"), kind: .follows,
                      onFirstTime: true, feature: .healthSummaries),
                .init(id: .firstAid, title: String(localized: "First-Aid Coaching and Triage"), kind: .follows,
                      onFirstTime: true, feature: .firstAidAssist),
                .init(id: .shareHealth, title: String(localized: "Share Health Data with AI"), kind: .separateConsent,
                      hardDisabledInMedicalMode: true),
            ])
        }
    }

    /// How a member draws on a managed phone: the most restrictive of the Everyday category's lock,
    /// its key, its tools and any category it reaches into. An unmanaged phone gets `.editable`.
    static func presentation(of member: SettingsGroupMember,
                             in context: ManagedSettingsContext) -> SettingPresentation {
        var settings: [SettingPresentation] = [
            SettingsVisibilityPolicy.presentation(.row(in: .everyday), in: context)
        ]
        if let key = member.settingKey {
            settings.append(SettingsVisibilityPolicy.presentation(.key(key), in: context))
        }
        if let category = member.reachesInto {
            settings.append(SettingsVisibilityPolicy.presentation(.row(in: category), in: context))
        }
        if let tools = member.feature?.record.toolNames, !tools.isEmpty {
            let each = tools.map { SettingsVisibilityPolicy.presentation(.tool($0), in: context) }
            if !each.contains(where: \.isShown) { return .hidden }
            if !each.contains(where: \.isEditable) { settings.append(.readOnly) }
        }
        if settings.contains(.hidden) { return .hidden }
        return settings.contains(.readOnly) ? .readOnly : .editable
    }
}
