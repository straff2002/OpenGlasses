import Combine
import SwiftUI

/// Root tab view — Voice / Modes / Chat / Settings, with a Job tab for Field Assist.
///
/// Replaces the previous single-screen modal design with a proper
/// tab bar matching the OpenVision-style navigation.
struct MainView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var store = StoreKitService.shared
    @StateObject private var sessions = FieldSessionService.shared
    @State private var selectedTab: MainTab = .voice
    @State private var showOnboarding = Config.needsOnboarding
    /// The wearer's own Field Assist switch. Read reactively so turning it off in Settings takes
    /// the tab away in the same breath.
    @AppStorage("fieldAssistEnabled") private var fieldAssistEnabled: Bool = false
    // Default is "system" — the app follows the phone's appearance unless the user has
    // said otherwise. Kept in sync with `SettingsView` and `LookFeelSettingsScreen`.
    @AppStorage("appAppearance") private var appearance: String = "system"
    @AppStorage("accentColorName") private var accentColorName: String = AppAccent.defaultPresetID
    /// Plan CT 3b: the organisation's edition, and the administrator session that lifts it.
    @ObservedObject private var adminGate = AdminGate.shared
    @ObservedObject private var orgProfile = OrgProfileManager.shared

    /// Whether the technician's view is in force: an edition, and no administrator session.
    private var restricted: Bool { adminGate.isRestricted }
    private let adminIdleTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var accent: Color {
        AppAccent.color(for: AppAccent.effectiveName(stored: accentColorName))
    }

    /// Whether the bar carries a Job tab right now. The whole rule is in `JobTabPresence`; this
    /// only gathers the four facts it decides from.
    ///
    /// `hasCheckedEntitlements` is the one that matters at cold launch: until the store check has
    /// run, a false `fieldAssistUnlocked` means *unknown*, and a tab drawn on that guess would
    /// appear in front of somebody who never bought anything. So nothing is drawn until the
    /// answer is real — and it can only ever appear, never flash away.
    private var jobTabPresence: JobTabPresence.Decision {
        JobTabPresence.decide(.init(
            // The edition implies Field Assist for the technician without writing the switch.
            featureEnabled: fieldAssistEnabled || restricted,
            entitled: Config.fieldAssistUnlocked,
            entitlementChecked: store.hasCheckedEntitlements,
            hasOpenJob: sessions.activeSession.map { $0.endedAt == nil && $0.outcome != .cancelled } ?? false))
    }

    /// What the Modes slot is right now (Plan HB): the persona picker, or — with Field Assist mode
    /// on — the Field Assist tab. Read live from the same facts as the Job rule, so a switch turned
    /// off, an entitlement that lapsed or an edition removed reverts it on the next render.
    private var modesPresentation: ModesTabPresentation {
        ModesTabPresentation.resolve(.init(
            switchOn: fieldAssistEnabled,
            entitled: Config.fieldAssistUnlocked,
            entitlementChecked: store.hasCheckedEntitlements,
            restricted: restricted))
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                // Declared in `MainTab.displayOrder`; keep the two in step.
                Tab(MainTab.voice.title, image: MainTab.voice.assetImage ?? "AvenkinSymbol",
                    value: MainTab.voice) {
                    VoiceTab()
                }

                // Modes, or Field Assist when Field Assist mode is on (Plan HB) — the same slot, so
                // the selection and the privacy log's token stay "modes". The edition shows it as
                // Field Assist with the other modes hidden (`ModesTabPresentation`).
                if modesPresentation.showsTab {
                    Tab(modesPresentation.title, systemImage: modesPresentation.systemImage,
                        value: MainTab.modes) {
                        NavigationStack {
                            switch modesPresentation {
                            case .fieldAssist(let otherModes):
                                FieldAssistModeTab(appState: appState, showsOtherModes: otherModes == .accordion)
                            case .modes(let shortcut):
                                PersonaPickerTab(appState: appState, fieldAssistShortcut: shortcut)
                            case .hidden:
                                EmptyView()
                            }
                        }
                        // A different tab, not the same one restyled: nothing pushed inside Field
                        // Assist survives it being turned off, and the reverse.
                        .id(modesPresentation.isFieldAssist)
                    }
                }

                // Field Assist only, and only once the entitlement is a real answer — see
                // `jobTabPresence`. The work sits beside the modes that shape it, ahead of history.
                if jobTabPresence.showsTab {
                    Tab(MainTab.job.title, systemImage: MainTab.job.systemImage, value: MainTab.job) {
                        JobTab()
                    }
                }

                if !restricted {
                    Tab(MainTab.chat.title, systemImage: MainTab.chat.systemImage, value: MainTab.chat) {
                        ChatListView()
                    }
                }

                Tab(MainTab.settings.title, systemImage: MainTab.settings.systemImage, value: MainTab.settings) {
                    NavigationStack {
                        SettingsView(appState: appState)
                    }
                }
            }
            .tabViewStyle(.tabBarOnly)
            .tabBarMinimizeBehavior(.onScrollDown)
            .tint(accent)
            // Onboarding is drawn *over* the tabs, not instead of them, so without this the whole
            // session surface stays in the accessibility tree behind it: a VoiceOver user on the
            // welcome page swipes straight out of the flow and into a status card and a capsule
            // for an app they have not set up yet. Sighted users never see it, which is why it
            // survived three phases of this plan and only a running-UI audit found it.
            .accessibilityHidden(showOnboarding)

            if showOnboarding {
                OnboardingView(isVisible: $showOnboarding)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // An AI turn just failed: offer to send the details to support, from whatever tab the
        // person is on, rather than leaving them to find a report page.
        .overlay(alignment: .top) {
            if let prompt = appState.supportPrompt, !showOnboarding {
                SupportPromptBanner(prompt: prompt,
                                    onSend: { appState.openSupportReport(from: prompt) },
                                    onDismiss: { appState.dismissSupportPrompt() })
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.supportPrompt)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            PrivacyLog.app(.memoryWarning)
        }
        // The raw values are the same tokens the parallel name array used to supply, so the log
        // keeps reading "voice" / "modes" / "chat" / "settings" — and a tab can no longer be
        // selected that the log has no name for.
        .onChange(of: selectedTab, initial: true) { _, tab in
            PrivacyLog.app(.tabSelected, detail: PrivacyToken(tab.rawValue))
        }
        // A tab that goes away must not leave the wearer on a blank one. Only `.job` can, and it
        // falls back to Voice rather than to whatever happens to be next along the bar.
        .onChange(of: jobTabPresence) { _, presence in
            selectedTab = JobTabPresence.selection(selectedTab, after: presence)
        }
        // The same for the edition: a session ending never leaves the technician on a hidden tab.
        .onChange(of: restricted) { _, isRestricted in
            selectedTab = EditionPresentation.tab(selectedTab, restricted: isRestricted)
        }
        // …and for the Modes slot, which only goes away under an edition with no licence in force.
        .onChange(of: modesPresentation) { _, presentation in
            selectedTab = ModesTabPresentation.selection(selectedTab, after: presentation)
        }
        // An administrator session idles out after ten minutes; this is what notices.
        .onReceive(adminIdleTick) { _ in
            adminGate.refresh()
        }
        // Another surface asked for a tab — the Job tab's "Open conversation", so far. Cleared
        // here, so nothing is left holding a request that has already been honoured.
        .onChange(of: appState.requestedTab) { _, requested in
            guard let requested else { return }
            selectedTab = ModesTabPresentation.selection(
                EditionPresentation.tab(requested, restricted: restricted), after: modesPresentation)
            appState.requestedTab = nil
        }
        .environment(\.appAccent, accent)
        .animation(.easeInOut(duration: 0.3), value: showOnboarding)
        .preferredColorScheme(colorScheme)
        .sheet(item: $appState.phoneCameraRequest) { request in
            PhoneCameraView(
                prompt: request.prompt,
                onCapture: { appState.handlePhoneCapture($0) },
                onCancel: { appState.phoneCameraRequest = nil }
            )
        }
        // Plan GV: a camera tool waiting on the user's phone photo. From the root, like the manual
        // figure below, because a spoken turn can ask for it on any tab. A swipe-down is a cancel.
        .sheet(item: Binding(get: { appState.toolPhotoRequest },
                             set: { if $0 == nil { appState.dismissToolPhotoRequest() } })) { request in
            PhoneCameraView(
                prompt: "",
                hint: request.hint,
                onCapture: { appState.phonePhotos.fulfil(request.id, data: $0) },
                onCancel: { appState.phonePhotos.cancel(request.id) },
                onPresented: { appState.phonePhotos.notePresented(request.id) }
            )
        }
        .sheet(item: $appState.pendingSiriContent) { link in
            SiriContentDetailView(link: link)
        }
        // The manual page a Field Assist turn pointed at (Plan EK). Presented from here because a
        // figure can be staged by a spoken turn on any tab, and the drawing is the answer.
        .sheet(item: $appState.manualFigureRequest) { request in
            ManualFigureSheet(request: request)
        }
        // The vault's own core file, opened from a citation chip (Plan EK P3) — checkable by the
        // technician and correctable by an author without leaving the answer.
        .sheet(item: $appState.vaultFileRequest) { request in
            VaultFileCitationSheet(vaultId: request.vaultId, filename: request.filename,
                                   section: request.section)
        }
        // The job report, filled in and waiting for the operator's thumb (Plan EM P2). Presented
        // from here because "send the job report" can be said on any tab, and a report nobody can
        // see is a report nobody can send.
        .sheet(item: $appState.deliveryComposerRequest) { request in
            switch request.channel {
            case .messages:
                ReportMessageComposer(model: request.model) { outcome in
                    appState.finishDelivery(request.request, outcome: outcome)
                }
                .ignoresSafeArea()
            default:
                ReportMailComposer(model: request.model) { outcome in
                    appState.finishDelivery(request.request, outcome: outcome)
                }
                .ignoresSafeArea()
            }
        }
        .sheet(item: $appState.deliveryShareItem) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
        // The support report, read in full before it is sent (support ask 2026-09-26).
        .sheet(item: $appState.supportReportRequest) { request in
            SupportReportSheet(request: request)
                .environmentObject(appState)
        }
    }
}
