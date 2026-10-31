import SwiftUI

/// Where the Voice tab's "Things to try" card sits (Plan KH P1). The rule is `ScenarioIntroCard`.
///
/// A view of its own for two reasons. `ConversationStore` is a nested `ObservableObject`, so the tab
/// would not redraw when a conversation starts or is cleared, and only this view needs that. And
/// the check for whether there is anything to offer reads the Keychain, so it is worked out here on
/// the few occasions it can change rather than on every render of a tab that redraws constantly.
///
/// The `ZStack` is always there and takes no space while empty, so the modifiers have something to
/// hang from. The card carries its own leading gap, like `SessionNoticeOverlay`.
struct ScenarioIntroSlot: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var conversations: ConversationStore
    @ObservedObject private var store = ScenarioProgressStore.shared
    /// Observed so the card is looked at again when onboarding finishes above this tab.
    @AppStorage("hasCompletedOnboarding") private var onboardingDone = false
    @Environment(\.scenePhase) private var scenePhase

    /// No turn is running and nothing else needs the zone.
    let surfaceFree: Bool
    let open: () -> Void

    @State private var hasOffer = false
    /// Not `hasCompletedOnboarding`: an update from a build before onboarding never set it.
    @State private var pastOnboarding = false
    @State private var isOnScreen = false

    private var conversationIsEmpty: Bool {
        ConversationContinuity.pageContent(
            store: conversations, isRealtimeSession: false,
            liveUserText: appState.currentTranscription,
            liveAssistantText: appState.lastResponse) == .empty
    }

    private var shows: Bool {
        ScenarioIntroCard.shows(
            progress: store.progress, countedThisLaunch: store.introCardCountedThisLaunch,
            pastOnboarding: pastOnboarding,
            directMode: HomeSurfaceVisibility.showsActionTiles(mode: appState.currentMode),
            surfaceFree: surfaceFree, hasOffer: hasOffer, conversationIsEmpty: conversationIsEmpty)
    }

    var body: some View {
        let shows = self.shows
        ZStack {
            if shows {
                ScenarioCardRow(icon: "sparkles",
                                title: String(localized: "Things to try"),
                                detail: String(localized: "Pick what you want it for, and try it."),
                                hint: String(localized: "Opens a short list of ideas."),
                                dismissLabel: Text("Dismiss things to try"),
                                open: open,
                                dismiss: { store.dismissIntroCard() })
                    .frame(maxWidth: .infinity)
                    .glassEffect(in: .rect(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.top, DockGridMetrics.moduleGap)
                    .transition(.opacity)
            }
        }
        .onAppear {
            isOnScreen = true
            refresh()
        }
        .onDisappear { isOnScreen = false }
        .onChange(of: store.progress) { _, _ in refresh() }
        .onChange(of: appState.currentMode) { _, _ in refresh() }
        .onChange(of: onboardingDone) { _, _ in refresh() }
        // Seen by the person: the card is up, on the tab in front, in an app in the foreground.
        .onChange(of: shows && isOnScreen && scenePhase == .active, initial: true) { _, seen in
            if seen { store.noteIntroCardShown() }
        }
    }

    private func refresh() {
        guard !ScenarioIntroCard.isOver(store.progress, countedThisLaunch: store.introCardCountedThisLaunch)
        else {
            hasOffer = false
            return
        }
        pastOnboarding = Config.isPastOnboarding
        hasOffer = ScenarioIntroCard.hasOffer(
            from: ScenarioReadiness.visible(ScenarioCatalog.all, in: appState.scenarioContext),
            progress: store.progress, showsPicker: ScenarioEnvironment.offersIntentChoice)
    }
}

/// What the card opens: the Ready page's question, then up to three scenarios for the answer.
struct ScenarioIntroSheet: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var store = ScenarioProgressStore.shared
    let leave: (ScenarioSheetExit) -> Void

    /// Read when the sheet appears and kept: reading the app into a context goes to the Keychain.
    @State private var entries: [ScenarioEntry] = []
    @State private var showsPicker = true

    private var intent: ScenarioIntent? {
        ScenarioIntroCard.intent(showsPicker: showsPicker, chosen: store.progress.chosenIntent)
    }

    var body: some View {
        NavigationStack {
            OGScrollPage {
                if showsPicker {
                    ScenarioIntentChoice(selection: intent) { store.choose($0) }
                }
                if let intent {
                    scenarios(for: intent)
                }
                OGSection {
                    NavigationLink {
                        ThingsToTryView(leaveSheet: leave)
                    } label: {
                        ThingsToTryRow()
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Things to Try")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { leave(.close) }
                }
            }
        }
        .onAppear {
            entries = ScenarioReadiness.visible(ScenarioCatalog.all, in: appState.scenarioContext)
            showsPicker = ScenarioEnvironment.offersIntentChoice
        }
        // The last card went from under the person, so there is nothing left for this to offer.
        .onChange(of: ScenarioShelfPolicy.hasEnded(store.progress)) { _, ended in
            if ended { leave(.close) }
        }
    }

    @ViewBuilder
    private func scenarios(for intent: ScenarioIntent) -> some View {
        let cards = ScenarioIntroCard.scenarios(for: intent, from: entries, progress: store.progress)
        VStack(alignment: .leading, spacing: 6) {
            if !showsPicker {
                Text(verbatim: intent.title)
                    .textCase(.uppercase)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .accessibilityAddTraits(.isHeader)
            }
            if cards.isEmpty {
                Text("Nothing here is ready to try right now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                OGCard {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { OGDivider() }
                        ScenarioCardRow(entry: entry, isDisabled: false,
                                        open: { open(entry) }, dismiss: { store.dismiss(entry.id) })
                    }
                }
            }
        }
    }

    private func open(_ entry: ScenarioEntry) {
        let canRun = appState.acceptsTypedTurn
            && HomeSurfaceVisibility.showsActionTiles(mode: appState.currentMode)
        switch ScenarioCardTap.resolve(entry, acceptsTurn: canRun) {
        case .openSettings(let destination):
            leave(.settings(destination))
        case .run:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            leave(.run(entry))
        case .nothing:
            return
        }
    }
}

/// "What do you want it for first?": the Ready page and the Voice tab's sheet ask it the same way.
struct ScenarioIntentChoice: View {
    let selection: ScenarioIntent?
    let choose: (ScenarioIntent) -> Void

    var body: some View {
        OGSection(header: "What do you want it for first?") {
            ForEach(Array(ScenarioIntent.offeredOnReadyPage.enumerated()), id: \.element) { index, intent in
                if index > 0 { OGDivider() }
                OGSelectionRow(title: intent.title, subtitle: intent.subtitle,
                               isSelected: selection == intent) {
                    choose(intent)
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
