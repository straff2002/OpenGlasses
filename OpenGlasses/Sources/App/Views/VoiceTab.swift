import SwiftUI
import Combine

/// Voice tab — the primary interaction screen:
///
///   1. Status (top, pinned): the StatusIndicator card and the conversation's header — which
///      conversation this is, a new one, an earlier one
///   2. Feed (the rest): My Day, captions and notices, then the conversation itself, as long as it
///      is, with a manual page an answer cited opened in place under it. One scroll view, so the
///      tab bar shrinks to the mark as it scrolls
///   3. Controls (floating at the bottom): the mic and the buttons button side by side in the
///      thumb's corner; the buttons button raises the grid of controls and tiles over the feed
struct VoiceTab: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var workspace: AdaptiveWorkspaceState
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @ScaledMetric(relativeTo: .body) private var minimumPrimaryWidth: CGFloat = 340
    @ScaledMetric(relativeTo: .body) private var minimumContextWidth: CGFloat = 280
    @ObservedObject private var fieldSessions = FieldSessionService.shared
    /// Which of the conversation and the buttons is up, the typed bar, and a reply waiting behind
    /// the buttons — shared with the tab view's bottom accessory, where the controls ride.
    @EnvironmentObject private var dock: VoiceDockModel
    @State private var showPreview = false
    /// The preview asked for streaming setup, which cannot be opened from under its cover.
    @State private var previewLeavingToSetup = false
    @State private var showModelPicker = false
    @State private var showPersonaPicker = false
    /// The grid is up in the conversation's place.
    private var showsGrid: Bool { dock.pager.page == .actions }
    @State private var captionsActive = false
    @AppStorage(MyDayHomePlacement.enabledKey) private var myDayEnabled = false
    /// The card's placement, separate from My Day being on — see `MyDayHomePlacement`. The same key
    /// Settings and the home screen's editor write, so the three can never disagree.
    @AppStorage(MyDayHomePlacement.onHomeKey) private var myDayOnHome
        = MyDayHomePlacement.onHomeDefault
    @ScaledMetric(relativeTo: .caption) private var recordingDot: CGFloat = 8
    /// Field Assist mode's facts (Plan HB) — the home screen shows the job-day card while it is on.
    @AppStorage("fieldAssistEnabled") private var fieldAssistEnabled = false
    @ObservedObject private var store = StoreKitService.shared
    @ObservedObject private var adminGate = AdminGate.shared
    @ObservedObject private var manualLibrary = PersonalManualLibrary.shared
    /// Plan KW: an expert's one Assisting card — a clock running, jobs sent, or an invite.
    @ObservedObject private var assisting = AssistingPresenceFeed.shared
    /// Observed for the pending first turn the Ready page leaves (Plan KH P1).
    @ObservedObject private var scenarios = ScenarioProgressStore.shared
    /// Observed so the opening below is looked at again when the overlay above this tab finishes.
    @AppStorage("hasCompletedOnboarding") private var onboardingDone = false
    /// The full-screen day behind the job-day card, and where one of its rows asked to go once it
    /// is out of the way — a composer or another tab cannot be presented from under a cover.
    @State private var showingJobDay = false
    @State private var jobDayLeavingTo: JobDayDestination?
    /// The "Things to try" sheet, and where it asked to go once it is out of the way (Plan KH).
    @State private var showingScenarioIntro = false
    @State private var scenarioIntroExit: ScenarioSheetExit?

    /// Above the status card, at the top of the tab.
    private static let conversationZoneTopPadding: CGFloat = 12

    private var session: GeminiLiveSessionManager { appState.geminiLiveSession }
    private var openAISession: OpenAIRealtimeSessionManager { appState.openAIRealtimeSession }

    private var isRealtime: Bool { appState.currentMode.isRealtime }

    var body: some View {
        // One observation point derives the voice state; the ambience (background radiance) and
        // the waveline express it together — a single motion system, not scattered effects.
        VoiceStateProvider(session: session, openAISession: openAISession,
                           speech: appState.speechService,
                           activity: appState.speechService.playbackActivity) { voiceState, activity in
        ZStack {
            VoiceAmbience(state: voiceState, activity: activity).ignoresSafeArea()

            // The tab's usable height, read once: the risen grid takes at most a share of it, and
            // an inline manual page is sized from it.
            GeometryReader { tab in
            let placement = AdaptiveWorkspacePlacement.resolve(
                size: tab.size, minimumPrimaryWidth: minimumPrimaryWidth,
                minimumContextWidth: minimumContextWidth,
                accessibilityText: typeSize.isAccessibilitySize,
                rightToLeft: layoutDirection == .rightToLeft, divisions: divisionFrames(in: tab))
            let layout = placement.layout
            // The primary column keeps the same structural identity at every size. Rebuilding
            // it in separate portrait/landscape branches would discard drafts and dock position.
            WorkspaceRegionLayout(size: tab.size, placement: placement) {
            // The feed is the tab's own scroll view, edge to edge, with the status on a bar above
            // it and the dock on a bar below. Being the root scroll view is what lets the tab bar
            // track it and shrink to the mark, as it does on Settings.
            ZStack {
                // Kept alive under the grid, so the buttons button brings the conversation back
                // where it was left.
                homeFeed(voiceState, layout: layout, tabHeight: placement.primary.height)
                    .opacity(showsGrid ? 0 : 1)
                    .allowsHitTesting(!showsGrid)
                    .accessibilityHidden(showsGrid)
                    // A sideways swipe brings up the buttons, as on the old panel; the scroll
                    // keeps the vertical axis.
                    .simultaneousGesture(swipeToButtons)
                // The grid in the conversation's place, not stacked under it: one or the other.
                if showsGrid {
                    GeometryReader { area in
                        VoiceTabControls(
                            session: session,
                            openAISession: openAISession,
                            showPreview: $showPreview,
                            showModelPicker: $showModelPicker,
                            showChatInput: $dock.showChatInput,
                            pager: $dock.pager,
                            showsActions: HomeSurfaceVisibility.showsActionTiles(
                                mode: appState.currentMode),
                            voiceState: voiceState,
                            availableHeight: placement.primary.height,
                            gridAreaHeight: area.size.height,
                            unseenReply: dock.unseenReply
                        )
                    }
                    .transition(.opacity)
                }
            }
                .safeAreaBar(edge: .top) {
                    VStack(spacing: 0) {
                        if appState.videoRecorder.isRecording {
                            recordingBadge
                                .padding(.top, 8)
                        }
                        pinnedStatus(compact: layout.showsContext && layout.isShort)
                    }
                    .padding(.bottom, 8)
                }
                // The mic and the buttons button float over the bottom of the feed — no band, no
                // edge blur: the conversation scrolls on beneath them, and the inset only makes
                // sure its last line can be scrolled clear of them.
                // The typed bar, when it is open; and the controls themselves only where the tab
                // view's bottom accessory cannot carry them (iOS 26.0). Floating either way — no
                // band, the conversation scrolls on beneath.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // A transcript under review (Plan JM P1) opens the typed bar by itself.
                    if (dock.showChatInput || appState.pendingTranscript != nil) && !isRealtime {
                        ChatInputBar(showChatInput: $dock.showChatInput)
                    } else if !VoiceDockModel.usesSystemAccessory {
                        VoiceTabControls(
                            session: session,
                            openAISession: openAISession,
                            showPreview: $showPreview,
                            showModelPicker: $showModelPicker,
                            showChatInput: $dock.showChatInput,
                            pager: $dock.pager,
                            showsActions: HomeSurfaceVisibility.showsActionTiles(
                                mode: appState.currentMode),
                            voiceState: voiceState,
                            availableHeight: placement.primary.height,
                            unseenReply: dock.unseenReply
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if layout.showsContext {
                AdaptiveWorkspaceContext(showsJobs: showsJobContext,
                                         showsMyDay: showsDayContext,
                                         hasUnfinishedJob: hasUnfinishedJob)
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .frame(width: layout.contextWidth)
            }
            }
            .onChange(of: layout.showsContext, initial: true) { _, expanded in
                workspace.isExpanded = expanded
            }
            }
        }
        .onChange(of: dock.pager.page) { _, page in
            if page == .conversation { dock.unseenReply = false }
        }
        // Plan KH P1: the dock opens on the grid, so with cards waiting it starts on them instead.
        .onChange(of: opensOnShelf(voiceState), initial: true) { _, opens in
            guard opens else { return }
            scenarios.settleShelfOpening()
            dock.pager = DockPagerPolicy.openedForShelf(dock.pager)
        }
        .onChange(of: voiceState) { previous, state in
            // The panel's own flips (`DockPagerPolicy`): to the conversation as a turn starts and
            // as its reply arrives, never against the wearer's own move.
            let advanced = DockPagerPolicy.advance(dock.pager, from: previous, to: state)
            if advanced != dock.pager {
                withAnimation(.easeInOut(duration: 0.25)) { dock.pager = advanced }
            }
            // A reply arriving — speech starting, or a silent turn finishing — while the buttons
            // are up and the wearer chose to stay there.
            if showsGrid, state == .speaking || (previous == .thinking && state == .idle) {
                withAnimation(.snappy) { dock.unseenReply = true }
            }
            if DockPagerPolicy.isTurnActive(state) { scenarios.settleShelfOpening() }
            runPendingFirstScenario()
        }
        }
        // Animated at the source: captions arriving or leaving changes the zone's height, and the
        // panel tracks that measurement rather than animating separately. Settling it here is what
        // makes the caption block and the panel one exchange instead of two.
        .onReceive(appState.ambientCaptions.$isActive) { active in
            withAnimation(DockGridMetrics.heightSettle) { captionsActive = active }
        }
        // The first turn the Ready page chose. `initial` covers the tab being built after the choice;
        // the record is cleared before the turn runs, so a re-appear or a relaunch finds nothing.
        .onChange(of: scenarios.progress.pendingFirstTurn, initial: true) { _, _ in
            runPendingFirstScenario()
        }
        // A first turn that found the app busy is still waiting.
        .onChange(of: appState.isProcessing) { _, _ in
            runPendingFirstScenario()
        }
        // The wearer's own move ends the chance to open on the cards, for this launch.
        .onChange(of: dock.pager.userMovedThisTurn) { _, moved in
            if moved { scenarios.settleShelfOpening() }
        }
        .fullScreenCover(isPresented: $showPreview, onDismiss: leavePreview) {
            LivePreviewView(broadcastService: appState.broadcastService) {
                previewLeavingToSetup = true
                showPreview = false
            }
            .environmentObject(appState)
        }
        // Consumed on appearing, not on change: the request arrives from Settings while this tab
        // is off screen, and a cover presented from there may not come up.
        .onAppear {
            guard appState.livePreviewRequested else { return }
            appState.livePreviewRequested = false
            showPreview = true
        }
        .fullScreenCover(isPresented: $showingJobDay, onDismiss: leaveJobDay) {
            JobDayView(appState: appState, feed: appState.jobDayFeed) { destination in
                jobDayLeavingTo = destination
                showingJobDay = false
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showingScenarioIntro, onDismiss: leaveScenarioIntro) {
            ScenarioIntroSheet { exit in
                scenarioIntroExit = exit
                showingScenarioIntro = false
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(appState: appState)
        }
        .sheet(isPresented: $showPersonaPicker) {
            PersonaPickerSheet(appState: appState)
        }
        // Plan GB P4: while the live preview is up, its own sheet presents the share item.
        .sheet(item: Binding(get: { showPreview ? nil : appState.pendingShareItem },
                             set: { appState.pendingShareItem = $0 })) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
    }

    private func leavePreview() {
        guard previewLeavingToSetup else { return }
        previewLeavingToSetup = false
        appState.openSettings(.capture)
    }

    /// Plan KH: where the "Things to try" sheet asked to go. Run from here rather than from the
    /// sheet: a photo scenario presents the camera, which cannot come up from under a sheet. So the
    /// turn is accepted, and marked tried, now that it can really start.
    private func leaveScenarioIntro() {
        guard let exit = scenarioIntroExit else { return }
        scenarioIntroExit = nil
        switch exit {
        case .close:
            return
        case .settings(let destination):
            appState.openSettings(destination)
        case .livePreview:
            showPreview = true
        case .run(let entry):
            guard scenarios.begin(entry, acceptsTurn: appState.acceptsTypedTurn) == .run else { return }
            Task { await HomeGridDispatcher.run(.builtIn(entry.scenario.action), on: appState) }
        }
    }

    // MARK: - First turn

    /// Whether the panel should start on the cards now (`ScenarioShelfPolicy.opensOnConversation`).
    private func opensOnShelf(_ voiceState: VoiceVisualState) -> Bool {
        ScenarioShelfPolicy.opensOnConversation(
            pager: dock.pager, voiceState: voiceState,
            directMode: HomeSurfaceVisibility.showsActionTiles(mode: appState.currentMode),
            onboardingDone: onboardingDone, alreadySettled: scenarios.shelfOpeningSettled,
            conversationIsEmpty: ConversationContinuity.pageContent(
                store: appState.conversationStore, isRealtimeSession: false,
                liveUserText: appState.currentTranscription, liveAssistantText: appState.lastResponse) == .empty,
            hasCards: !appState.scenarioShelfCards(progress: scenarios.progress).isEmpty)
    }

    /// Plan KH P1: takes the Ready page's first turn, once, through the grid's own seam.
    private func runPendingFirstScenario() {
        let pending = scenarios.progress.pendingFirstTurn
        guard pending != nil else { return }
        let consumption = ScenarioFirstRun.consumption(
            of: pending, pastOnboarding: Config.hasCompletedOnboarding,
            directMode: HomeSurfaceVisibility.showsActionTiles(mode: appState.currentMode),
            busy: !appState.acceptsTypedTurn,
            context: appState.scenarioContext, scenarios: ScenarioCatalog.all)
        switch consumption {
        case .wait:
            return
        case .discard:
            _ = scenarios.takePendingFirstTurn()
        case .run(let scenario):
            guard scenarios.takePendingFirstTurn() != nil else { return }
            scenarios.markTried(scenario.id)
            Task { await HomeGridDispatcher.run(.builtIn(scenario.action), on: appState) }
        }
    }

    // MARK: - Conversation zone

    private func divisionFrames(in proxy: GeometryProxy) -> [CGRect] {
        // The 27.2 toolchain has this API. Older toolchains retain ordinary window adaptation.
        #if compiler(>=6.4.2)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed).map { region in
                let margins = region.margins
                let left = layoutDirection == .rightToLeft ? margins.trailing : margins.leading
                return CGRect(x: region.frame.minX - left, y: region.frame.minY - margins.top,
                              width: region.frame.width + margins.leading + margins.trailing,
                              height: region.frame.height + margins.top + margins.bottom)
            }
        }
        #endif
        return []
    }

    /// The status card, with the sign-in row under it while the assistant model has none (Plan KL
    /// P0), and the conversation's header. Pinned above the feed: the state of the session and
    /// "which conversation, a new one, an earlier one" have to be reachable from the bottom of a
    /// long reply, not only from the top of it.
    @ViewBuilder
    private func pinnedStatus(compact: Bool) -> some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                StatusIndicator(session: session, openAISession: openAISession,
                                openClawBridge: appState.openClawBridge, compact: compact)
                if !isRealtime {
                    CredentialSignInRow(llmService: appState.llmService) {
                        appState.openSettings(.intelligence)
                    }
                }
            }
            ConversationPageHeader(store: appState.conversationStore)
                .padding(.horizontal, 16)
        }
        .padding(.top, Self.conversationZoneTopPadding)
    }

    /// Everything below the pinned status, in one scroll: the day card and the other modules, then
    /// the conversation, then a cited manual page opened in place.
    ///
    /// In the expanded workspace the manual opens in the context pane beside it instead, so it is
    /// drawn here only when there is no pane.
    @ViewBuilder
    private func homeFeed(_ voiceState: VoiceVisualState, layout: AdaptiveWorkspaceLayout,
                          tabHeight: CGFloat) -> some View {
        let inlineManual = layout.showsContext ? nil : appState.manualFigureRequest
        ConversationFeed(store: appState.conversationStore, session: session,
                         openAISession: openAISession, trailID: inlineManual?.id) {
            feedModules(voiceState, showsContext: layout.showsContext)
        } trail: {
            if let request = inlineManual {
                InlineManualPage(request: request, height: Self.inlineManualHeight(tabHeight: tabHeight)) {
                    appState.manualFigureRequest = nil
                }
                .padding(.horizontal, 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(DockGridMetrics.heightSettle, value: inlineManual?.id)
    }

    /// A deliberate sideways swipe across the conversation — against the reading direction, as the
    /// buttons sat to the right of it on the old panel — brings the buttons up.
    private var swipeToButtons: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let forward = layoutDirection == .rightToLeft ? value.translation.width
                                                              : -value.translation.width
                guard forward > 80, forward > abs(value.translation.height) * 2 else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    dock.pager = DockPagerPolicy.userMoved(dock.pager, to: .actions)
                }
            }
    }

    /// A cited page tall enough to read a drawing on, short enough that the answer above it stays
    /// in view.
    static func inlineManualHeight(tabHeight: CGFloat) -> CGFloat {
        guard tabHeight > 0, tabHeight.isFinite else { return 480 }
        return min(560, max(320, tabHeight * 0.62))
    }

    /// The modules above the conversation, in order, at the one rhythm.
    @ViewBuilder
    private func feedModules(_ voiceState: VoiceVisualState, showsContext: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: DockGridMetrics.moduleGap) {
                // One day card (Plan HB): the job-day card whenever Field Assist mode is on — My
                // Day's switch then only governs the personal items folded into it — and My Day's
                // own card otherwise. Never both.
                let card = dayCard(voiceState)
                if !showsContext, case .jobDay(let showsPersonal) = card {
                    JobDayHomeCard(appState: appState, feed: appState.jobDayFeed,
                                   showsPersonal: showsPersonal,
                                   compact: voiceState == .listening,
                                   onOpenDay: { showingJobDay = true })
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if !showsContext, card == .myDay {
                    MyDayHomeView(
                        service: appState.myDayService,
                        compact: voiceState == .listening,
                        onRemoveFromHome: {
                            withAnimation(DockGridMetrics.heightSettle) { myDayOnHome = false }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                // Plan KW: under the day card, and yielding the zone the way My Day does. Tested
                // here rather than inside the card, because an empty child still costs a gap.
                if !showsContext, assisting.presence.homeCard != nil,
                   HomeSurfaceVisibility.showsMyDay(state: voiceState, captionsActive: captionsActive) {
                    AssistingHomeCard { appState.openSettings(.assisting) }
                }

                if PersonalManualLibrary.canManage, !FieldAssistEntitlement.shared.has(.fieldWork), manualLibrary.manuals.isEmpty {
                    Button("Add your first manual") { appState.openSettings(.myManuals) }
                        .buttonStyle(.bordered)
                }

                if captionsActive {
                    AmbientCaptionOverlay(captionService: appState.ambientCaptions)
                }

                // Plan JM P1: speech has failed twice running — the typed bar, one tap away.
                if appState.showTypeInstead && !isRealtime && !dock.showChatInput
                    && appState.pendingTranscript == nil {
                    TypeInsteadChip { dock.showChatInput = true }
                        .transition(.opacity)
                }
            }

            // Plan KH: things to try for anyone who has a conversation on the page. Outside the
            // spaced stack, because a `VStack` allocates its spacing around every child it holds —
            // including one whose body resolves to nothing.
            ScenarioIntroSlot(conversations: appState.conversationStore,
                              surfaceFree: HomeSurfaceVisibility.showsMyDay(state: voiceState,
                                                                            captionsActive: captionsActive)
                                  && appState.pendingTranscript == nil) {
                showingScenarioIntro = true
            }

            // The error card, which carries its own leading gap so that absent it costs nothing.
            SessionNoticeOverlay(session: session, openAISession: openAISession)
        }
        .padding(.top, 4)
    }

    /// What a row of the day view asked for, once the view has gone: the Jobs tab, or a report's
    /// composer (which the root presents).
    private func leaveJobDay() {
        guard let destination = jobDayLeavingTo else { return }
        jobDayLeavingTo = nil
        // A job's page opens over the Jobs list (Plan HC), so Back from it is the list; a report
        // opens its composer here.
        if let request = JobListRequest(destination) {
            appState.openJobs(request)
        } else if case .send(let id) = destination,
                  let entry = appState.jobSends.queue.queue.entry(id: id) {
            appState.jobSends.present(entry)
        } else if case .partsOrder(let sessionId) = destination {
            // The parts order's composer, like a staged report's. When it cannot open — no
            // channel allowed, nobody to send it to — the job's page is where the reason and the
            // requests are, so that is where the row lands.
            if let reason = appState.emailPartsOrder(sessionId: sessionId) {
                NoticeCenter.shared.post(reason, severity: .warning, source: .app)
                appState.openJobs(.session(id: sessionId))
            }
        }
    }

    /// Which day card the zone draws — the whole rule is `HomeDayCard`'s.
    private func dayCard(_ voiceState: VoiceVisualState) -> HomeDayCard {
        HomeDayCard.resolve(
            fieldAssistOn: showsJobContext,
            myDayEnabled: myDayEnabled,
            myDayOnHome: myDayOnHome,
            personalLocked: adminGate.lock(.connections).isLocked,
            surfaceFree: HomeSurfaceVisibility.showsMyDay(state: voiceState, captionsActive: captionsActive))
    }

    private var showsDayContext: Bool {
        myDayEnabled && myDayOnHome && !adminGate.lock(.connections).isLocked
    }

    private var showsJobContext: Bool {
        // Keeping an unfinished job reachable is a navigation rule, not a reason to put
        // the whole home workspace back into Field Assist after its switch was turned off.
        FieldAssistMode.isOn(.init(
            switchOn: fieldAssistEnabled,
            entitled: Config.fieldAssistUnlocked,
            entitlementChecked: store.hasCheckedEntitlements,
            restricted: adminGate.isRestricted))
    }

    private var hasUnfinishedJob: Bool {
        fieldSessions.activeSession.map {
            $0.endedAt == nil && $0.outcome != .cancelled
        } ?? false
    }

    // MARK: - Recording Badge

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(OGTheme.onBadge)
                .frame(width: recordingDot, height: recordingDot)
                .accessibilityHidden(true)
            Text("REC \(appState.videoRecorder.formattedDuration)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(OGTheme.onBadge)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // The recording red is a convention worth keeping, but a 0.3 wash of it
        // put label copy on an unpredictable ground. `Token.badge` is the same
        // convention as a measured pair — the deepened red P3 introduced for
        // exactly this shape of capsule, with its own text colour.
        .background(Capsule().fill(OGTheme.badge))
        // `.accessibilityLabel` on an HStack does not absorb its children: the raw "REC 00:12"
        // text stayed in the tree as a second stop, and VoiceOver spells "REC".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording video")
        .accessibilityValue(appState.videoRecorder.formattedDuration)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Home surface yielding

/// When the Voice tab's home content is on screen: My Day in the conversation zone, and the content
/// tiles in the dock's grid. Pure, because these are the rules that decide whether the surface is
/// honest at every state, and they should not need a device to check.
///
/// Captions are current speech and cannot be recovered if their rows are compressed. My Day
/// remains one tap away after the caption session ends, so it gives the zone to captions just as
/// it already does to an assistant response.
enum HomeSurfaceVisibility {
    static func showsMyDay(state: VoiceVisualState, captionsActive: Bool) -> Bool {
        guard !captionsActive else { return false }
        return state != .thinking && state != .speaking
    }

    /// The whole rule: placed on the home screen (`MyDayHomePlacement`), and not yielding the zone
    /// to a turn or to captions. With My Day off there is no card at all — not a set-up card.
    static func showsMyDay(enabled: Bool, onHome: Bool,
                           state: VoiceVisualState, captionsActive: Bool) -> Bool {
        MyDayHomePlacement.isShown(enabled: enabled, onHome: onHome)
            && showsMyDay(state: state, captionsActive: captionsActive)
    }

    /// Whether the content tiles belong in the dock's grid at all.
    ///
    /// A mode gate and nothing more. The tiles used to *vanish* while the assistant worked, on the
    /// same reasoning My Day still uses — but the panel pages now, so the conversation takes the
    /// front rather than the tiles being taken away, and the rules for that live in
    /// `DockPagerPolicy`. What is left here is the one condition that was never about yielding:
    /// realtime modes run their own turn spine, and these tiles submit ordinary Direct-mode turns.
    static func showsActionTiles(mode: AppMode) -> Bool {
        mode == .direct
    }
}

// MARK: - Voice Tab Controls (mic, buttons button and the grid)

/// Bottom controls for the Voice tab — reuses the original BottomControlBar patterns.
private struct VoiceTabControls: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

    @Binding var showPreview: Bool
    @Binding var showModelPicker: Bool
    @Binding var showChatInput: Bool
    @Binding var pager: DockPagerState
    let showsActions: Bool
    let voiceState: VoiceVisualState
    let availableHeight: CGFloat
    var gridAreaHeight: CGFloat? = nil
    var unseenReply: Bool = false

    var body: some View {
        BottomControlBar(
            session: session,
            openAISession: openAISession,
            showSettings: .constant(false),
            showModelPicker: $showModelPicker,
            showPreview: $showPreview,
            showChatInput: $showChatInput,
            showsActions: showsActions,
            voiceState: voiceState,
            availableHeight: availableHeight,
            gridAreaHeight: gridAreaHeight,
            unseenReply: unseenReply,
            pager: $pager
        )
    }
}

// MARK: - Chat Input Bar

/// Voice-tab inline chat input — the mic's typed-message alternative.
/// A thin wrapper over the shared `ChatComposer`: the mic button switches back to voice,
/// and sends route through the standard voice pipeline (spoken reply preserved).
struct ChatInputBar: View {
    @EnvironmentObject var appState: AppState
    @Binding var showChatInput: Bool

    var body: some View {
        if let review = appState.pendingTranscript {
            // "Check what I said before sending" (Plan JM P1): the transcript, seeded and counting
            // down. Not focused — the keyboard would cover the moment to read it; touching the text
            // holds the countdown, and the leading button cancels the turn.
            ChatComposer(
                voiceAction: { Task { await appState.cancelPendingTranscript() } },
                voiceActionSymbol: "xmark",
                voiceActionLabel: "Cancel, don't send",
                initialText: review.text,
                onEdit: { appState.holdPendingTranscript() },
                review: review
            ) { text, image in
                Task { await appState.sendReviewedTranscript(text, imageData: image) }
            }
            .id(review.id)
        } else {
            ChatComposer(autoFocus: true, voiceAction: { showChatInput = false }) { text, image in
                Task { await appState.sendTextMessage(text, imageData: image) }
            }
        }
    }
}

/// "Type instead" — offered above the dock after speech has failed twice running (Plan JM P1).
/// Opens the same typed bar as the dock's Type button.
private struct TypeInsteadChip: View {
    let action: () -> Void
    @Environment(\.appAccent) private var accent
    @ScaledMetric(relativeTo: .body) private var tapTarget: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Label("Type instead", systemImage: "keyboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(accent.opacity(OGTheme.Opacity.accentPillFill), in: Capsule())
                .frame(minHeight: tapTarget)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Type instead")
        .accessibilityHint("Opens the text bar to type your message")
    }
}


/// Observes exactly the signals the voice visuals fuse — the ambience and waveline re-render on
/// their changes without widening what VoiceTab itself watches — and hands the derived state to
/// its content.
private struct VoiceStateProvider<Content: View>: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject var speech: TextToSpeechService
    /// The playback-activity signal the visuals scale themselves by (Plan FE P5). Observed here
    /// for the same reason the rest is: this is the one place in the tab that re-renders on the
    /// voice signals, so the 20 Hz level never widens what VoiceTab itself watches.
    @ObservedObject var activity: PlaybackActivityMonitor
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: (VoiceVisualState, Double?) -> Content

    var body: some View {
        content(VoiceVisualState.from(
            isSpeaking: speech.isSpeaking || session.isModelSpeaking || openAISession.isModelSpeaking,
            isProcessing: appState.isProcessing,
            isListening: appState.isListening,
            realtimeActive: session.isActive || openAISession.isActive),
                activity.activity)
        // The monitor's gates. This view's lifetime *is* the animation's visibility — it wraps the
        // ambience — so the metering it feeds starts and stops with the screen rather than with
        // playback, and a tab the wearer has navigated away from meters nothing at all.
        .onAppear {
            activity.setReduceMotion(reduceMotion)
            activity.setSceneActive(scenePhase == .active)
            activity.setVisible(true)
        }
        .onDisappear { activity.setVisible(false) }
        .onChange(of: scenePhase) { _, phase in activity.setSceneActive(phase == .active) }
        .onChange(of: reduceMotion) { _, reduced in activity.setReduceMotion(reduced) }
    }
}
