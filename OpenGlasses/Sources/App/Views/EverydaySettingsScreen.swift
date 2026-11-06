import SwiftUI

/// Everyday (Plan KH P2): settings by what you want done, not by how the app was built.
///
/// One parent toggle per group, with the rows in an accordion, or a plain list where a group has no
/// real switch. The rows moved here from AI & Personality, Connections and Devices & Privacy and
/// each lives in this one place. Parents write through `SettingsGroupStore`, and everything they
/// are allowed to do is decided in `SettingsGroupState`.
///
/// `only` draws one group. It is how Devices & Privacy reaches Health & Fitness where Everyday is
/// not on the hub: the same screen, so each switch is still on one screen.
struct EverydaySettingsScreen: View {
    @ObservedObject var appState: AppState
    private let only: SettingsGroupID?
    @ObservedObject private var adminGate = AdminGate.shared

    // These exist to redraw the screen when a setter writes the key, here or elsewhere. The values
    // are read through `SettingsGroupStore`, so there is no second copy of any of them.
    @AppStorage("hipaaMode") private var hipaaMode = false
    @AppStorage("userMemoryEnabled") private var userMemoryEnabled = true
    @AppStorage("conversationPersistenceEnabled") private var conversationPersistenceEnabled = true
    @AppStorage("conversationTimelineEnabled") private var conversationTimelineEnabled = true
    @AppStorage("memoryNudgesEnabled") private var memoryNudgesEnabled = false
    @AppStorage("brainEnrichmentEnabled") private var brainEnrichmentEnabled = false
    @AppStorage(MyDayHomePlacement.enabledKey) private var myDayEnabled = false
    @AppStorage(MyDayHomePlacement.onHomeKey) private var myDayOnHome = MyDayHomePlacement.onHomeDefault
    @AppStorage("smartHomeControlEnabled") private var smartHomeControlEnabled = true
    @AppStorage("aiMessagingEnabled") private var aiMessagingEnabled = true
    @AppStorage("healthSummariesEnabled") private var healthSummariesEnabled = true
    @AppStorage("firstAidAssistEnabled") private var firstAidAssistEnabled = true
    @AppStorage("shareHealthDataWithAI") private var shareHealthDataWithAI = false
    @AppStorage("translationCaptionsEnabled") private var translationCaptionsEnabled = false

    @State private var expanded: Set<SettingsGroupID>

    init(appState: AppState, only: SettingsGroupID? = nil) {
        self.appState = appState
        self.only = only
        _expanded = State(initialValue: only.map { [$0] } ?? [])
    }

    private var groups: [SettingsGroupID] { only.map { [$0] } ?? SettingsGroupID.allCases }

    private var title: String { only.map { SettingsGroupCatalog.group($0).title } ?? String(localized: "Everyday") }

    private var context: ManagedSettingsContext { adminGate.settingsContext }

    var body: some View {
        Form {
            // Plan KH P2: not on the one-group page Devices & Privacy opens.
            if only == nil {
                Section {
                    NavigationLink {
                        ThingsToTryView().environmentObject(appState)
                    } label: {
                        SettingsLinkLabel(title: String(localized: "Things to Try"),
                                          subtitle: String(localized: "Ideas for what to do with it"),
                                          icon: "sparkles")
                    }
                    // Plan KM P2: jobs sent to you for your advice, and your expert card. Needs no
                    // Field Assist, so it lives here rather than under it.
                    NavigationLink {
                        AssistingView()
                    } label: {
                        SettingsLinkLabel(title: String(localized: "Assisting"),
                                          subtitle: String(localized: "Jobs sent to you for advice, and your expert card"),
                                          icon: "person.2.wave.2")
                    }
                    if SettingsHub.showsMyManuals(on: .everyday) {
                        NavigationLink {
                            MyManualsView().environmentObject(appState)
                        } label: {
                            SettingsLinkLabel(.myManuals)
                        }
                    }
                }
            }

            ForEach(groups, id: \.self) { id in
                let state = SettingsGroupStore.state(of: id, in: context)
                if state.isDrawn {
                    groupSection(state)
                }
            }
        }
        .navigationTitle(title)
        .ogFormStyle()
        // As it did when these rows lived under AI & Personality: what the assistant keeps about you
        // is read when the listener starts.
        .onDisappear { appState.restartWakeWordIfDirect() }
    }

    // MARK: - A group

    @ViewBuilder
    private func groupSection(_ state: SettingsGroupState) -> some View {
        if state.hasParent, let summary = state.summary {
            Section {
                parentToggle(state, summary: summary)
                let rows = detailRows(state)
                if !rows.isEmpty {
                    DisclosureGroup(isExpanded: expandedBinding(state.group.id)) {
                        ForEach(rows) { memberRow($0, in: state) }
                    } label: {
                        Text("Details")
                            .accessibilityLabel("\(state.group.title) details")
                    }
                }
            } footer: {
                footer(for: state.group.id)
            }
        } else {
            Section {
                ForEach(detailRows(state)) { memberRow($0, in: state) }
            } header: {
                Text(verbatim: state.group.title)
            } footer: {
                footer(for: state.group.id)
            }
        }
    }

    private func parentToggle(_ state: SettingsGroupState, summary: String) -> some View {
        Toggle(isOn: Binding(
            get: { state.isOn },
            set: { SettingsGroupStore.setParent($0, of: state.group.id, in: context) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: state.group.title)
                Text(verbatim: summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text(verbatim: state.group.title))
        .accessibilityValue(Text(verbatim: summary))
    }

    /// A group that is one switch has it as its parent, so the accordion does not draw it twice.
    private func detailRows(_ state: SettingsGroupState) -> [SettingsGroupMember] {
        guard state.hasParent, state.group.parentIsTheOnlySwitch else { return state.drawnMembers }
        return state.drawnMembers.filter { !$0.isSwitch }
    }

    private func expandedBinding(_ id: SettingsGroupID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func isEditable(_ member: SettingsGroupMember) -> Bool {
        SettingsGroupCatalog.presentation(of: member, in: context).isEditable
    }

    private func binding(_ id: SettingsGroupMemberID, in group: SettingsGroupID) -> Binding<Bool> {
        Binding(get: { SettingsGroupStore.isOn(id) },
                set: { SettingsGroupStore.setMember(id, to: $0, in: group) })
    }

    // MARK: - The rows

    @ViewBuilder
    private func memberRow(_ member: SettingsGroupMember, in state: SettingsGroupState) -> some View {
        memberContent(member, in: state.group.id)
            .disabled(!isEditable(member))
    }

    @ViewBuilder
    private func memberContent(_ member: SettingsGroupMember, in group: SettingsGroupID) -> some View {
        switch member.id {
        case .userMemory:
            InfoToggle(
                title: "User Memory",
                isOn: binding(.userMemory, in: group),
                info: "Remembers facts you share across conversations — your name, preferences, routines, dietary needs, etc. This context is included in future conversations so the AI can personalise responses. Memory is stored locally on your device."
            )
        case .whatAvenkinRemembers:
            NavigationLink {
                MemoryView(model: appState.memoryFacts.makeScreenModel())
            } label: {
                Label("What Avenkin Remembers", systemImage: "brain.head.profile")
            }
        case .conversationHistory:
            InfoToggle(
                title: "Conversation History",
                isOn: binding(.conversationHistory, in: group),
                info: "Saves conversation transcripts so you can review them later in the History tab. Also provides context for follow-up questions within a session. When off, conversations are ephemeral and discarded after each session."
            )
        case .earlierInConversation:
            // Medical Compliance mode refuses it whatever the switch says, so the switch shows off
            // and cannot be moved there, and the line under it says why.
            VStack(alignment: .leading, spacing: 4) {
                InfoToggle(
                    title: "Remember Earlier in Long Conversations",
                    isOn: hipaaMode ? .constant(false) : binding(.earlierInConversation, in: group),
                    info: "In a long conversation, the oldest messages stop being sent with each question to keep it fast and affordable. With this on, they are written up as short dated notes so the assistant still knows what was said. Your saved conversation is never changed."
                )
                .disabled(hipaaMode)
                Group {
                    if hipaaMode {
                        Text("Off in Medical Compliance mode.")
                    } else {
                        Text("Uses the same AI as the conversation, and counts in Usage.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        case .memorySuggestions:
            InfoToggle(
                title: "Memory Suggestions",
                isOn: binding(.memorySuggestions, in: group),
                info: "After you state a durable fact (\"my daughter's name is Mia\") or repeat a multi-step request, the assistant offers a spoken nudge to remember it or save it as a skill — you confirm by voice. With Agentic Features on, these are saved automatically instead of nudged. Off by default."
            )
        case .goals:
            NavigationLink {
                GoalsView()
            } label: {
                Label("Goals", systemImage: "target")
            }
        case .activity:
            NavigationLink {
                ActivityView(model: ActivityScreenModel.live(conversations: appState.conversationStore))
                    .environmentObject(appState)
            } label: {
                Label("Activity", systemImage: "clock.arrow.circlepath")
            }
        case .memoryEnrichment:
            InfoToggle(
                title: "Memory Enrichment",
                isOn: binding(.memoryEnrichment, in: group),
                info: "Sends the text of your turns to your configured AI provider so it can spot relationships the on-device patterns miss (who works where, who lives where, who knows whom). What it finds is filed as unconfirmed until you say it again in another conversation. Needs Agentic Features on and a cloud model \u{2014} it never runs in HIPAA mode, and never on an on-device model. Off by default."
            )
        case .myDay:
            Toggle("My Day", isOn: binding(.myDay, in: group))
        case .myDayContents:
            if myDayEnabled {
                Toggle("Show on Home Screen", isOn: $myDayOnHome)
                NavigationLink {
                    MyDayContentsSettingsView()
                } label: {
                    Label("What's in My Day", systemImage: "list.bullet.below.rectangle")
                }
            }
        case .myDayDelivery:
            if myDayEnabled {
                NavigationLink {
                    MyDayDeliverySettingsView()
                } label: {
                    Label("Scheduled Delivery", systemImage: "alarm")
                }
            }
        case .scheduledTasks:
            // Still gated by Agentic Features, which stays on the Assistant page, on its own.
            if Config.agentModeEnabled {
                NavigationLink {
                    ScheduledTasksView()
                        .environmentObject(appState)
                } label: {
                    Label("Scheduled Tasks", systemImage: "clock.arrow.2.circlepath")
                }
            } else {
                LabeledContent {
                    Text("Needs Agentic Features")
                } label: {
                    Label("Scheduled Tasks", systemImage: "clock.arrow.2.circlepath")
                }
                .accessibilityHint("Turn on Agentic Features under Assistant to use this.")
            }
        case .navigation:
            NavigationLink {
                NavigationSettingsView(glassesDisplay: appState.glassesDisplay)
            } label: {
                Label("Walking Navigation", systemImage: "figure.walk")
            }
        case .parking:
            NavigationLink {
                ParkingSettingsView(appState: appState)
            } label: {
                HStack {
                    Label("Parking", systemImage: "car")
                    Spacer()
                    if appState.parkingStore.active != nil {
                        Text("Spot saved").foregroundStyle(.secondary)
                    }
                }
            }
        case .smartHome:
            InfoToggle(
                title: "AI Smart Home Control",
                isOn: binding(.smartHome, in: group),
                info: "When off, the assistant cannot use HomeKit or Home Assistant, including reading device status or controlling lights, locks and scenes. Your saved connection settings stay on this phone."
            )
        case .messaging:
            InfoToggle(
                title: "AI Messaging",
                isOn: binding(.messaging, in: group),
                info: "When off, the assistant cannot compose or send messages through its messaging tools. Your contacts and other calling tools are unchanged."
            )
        case .music:
            NavigationLink {
                MusicSettingsView()
            } label: {
                Label("Music", systemImage: "music.note")
            }
        case .homeAssistant:
            NavigationLink {
                HomeAssistantSettingsView()
            } label: {
                Label("Home Assistant", systemImage: "house.and.flag")
            }
        case .translation:
            NavigationLink {
                TranslationSettingsView()
            } label: {
                HStack {
                    Label("Translation", systemImage: "globe")
                    Spacer()
                    Text(Config.isTranslationCloudConfigured ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
            }
        case .health:
            NavigationLink {
                HealthSettingsView()
            } label: {
                Label("Health", systemImage: "heart.text.square")
            }
        case .healthSummaries:
            InfoToggle(
                title: "Health Summaries",
                isOn: binding(.healthSummaries, in: group),
                info: "Answers questions like “how did I sleep?” or “what's my heart rate?” with one short sentence of numbers. It reports; it never interprets or gives medical advice."
            )
        case .firstAid:
            // Plan HP P2 item 12: the switch the privacy notice names.
            InfoToggle(
                title: String(localized: "First-Aid Coaching and Triage"),
                isOn: binding(.firstAid, in: group),
                info: String(localized: "First-aid coaching talks you through a protocol, such as CPR, and camera triage gives an AI assessment of an injury the camera can see. Both are advisory: they are not a medical device, and they don't replace a trained first aider or calling emergency services. Turning this off stops both.")
            )
        case .shareHealth:
            InfoToggle(
                title: "Share Health Data with AI",
                isOn: binding(.shareHealth, in: group),
                info: "Off by default. While it's off and you use a cloud AI model, Avenkin speaks a health summary to you itself, using an on-device voice, and the AI provider only learns that you asked — never the numbers. Turn it on to let your AI provider (Anthropic, OpenAI, Google, etc.) see the summary so it can answer follow-ups like “is that usual for me?”, and so the fitness coach can discuss your workout history. With an on-device model the numbers never leave your phone either way. Medical Compliance mode always keeps them from the AI."
            )
        }
    }

    // MARK: - Footers

    /// The words that sat under these rows, kept with them.
    @ViewBuilder
    private func footer(for id: SettingsGroupID) -> some View {
        switch id {
        case .memory:
            Text("Memory and History let the AI remember who you are across sessions. Goals are what you're working on, kept with you step by step. Activity is what the assistant has done for you.")
        case .myDayRoutines:
            Text("Adds a phone and spoken briefing of what matters next. My Day keeps an ephemeral read model and does not save a separate copy of your day. Taking the card off the Home screen keeps the briefings.")
        case .gettingAround:
            #if AVENKIN_PHONE_ONLY
            Text("Turn-by-turn pedestrian directions — \u{201C}navigate to\u{2026}\u{201D}. \u{201C}Where did I park?\u{201D} — the level, space and a way back, saved by voice, from a sign photo, or when a drive ends.")
            #else
            Text("Turn-by-turn pedestrian directions on the HUD — \u{201C}navigate to\u{2026}\u{201D}. \u{201C}Where did I park?\u{201D} — the level, space and a way back, saved by voice, from a sign photo, or when a drive ends.")
            #endif
        case .homeMusicMessages:
            Text("Apple Music or a Home Assistant speaker — \u{201C}play Rumours on the kitchen speaker.\u{201D}")
        case .translate:
            Text("Translated captions — surrounding speech rendered in your language. Off by default.")
        case .healthFitness:
            Text("When Share Health Data with AI is on, replies that include health numbers are spoken with your chosen voice, which may be a cloud voice. Turning Health & Fitness off turns sharing off too, and it stays off until you turn it on here.")
        }
    }
}
