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
        AppAccent.color(for: accentColorName)
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

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                // Declared in `MainTab.displayOrder`; keep the two in step.
                Tab("Voice", systemImage: "waveform", value: MainTab.voice) {
                    VoiceTab()
                }

                // The Field Assist edition hides the other modes and chat from the technician
                // (Plan CT 3b, `EditionPresentation.hiddenTabs`); an administrator session shows them.
                if !restricted {
                    Tab("Modes", systemImage: "person.2.fill", value: MainTab.modes) {
                        NavigationStack {
                            PersonaPickerTab(appState: appState)
                        }
                    }
                }

                if !restricted {
                    Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: MainTab.chat) {
                        ChatListView()
                    }
                }

                // Field Assist only, and only once the entitlement is a real answer — see
                // `jobTabPresence`. It sits here rather than at the end because Settings is the
                // drawer everything else is kept out of, and the job is content.
                if jobTabPresence.showsTab {
                    Tab(MainTab.job.title, systemImage: MainTab.job.systemImage, value: MainTab.job) {
                        JobTab()
                    }
                }

                Tab("Settings", systemImage: "gearshape.fill", value: MainTab.settings) {
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
        // An administrator session idles out after ten minutes; this is what notices.
        .onReceive(adminIdleTick) { _ in
            adminGate.refresh()
        }
        // Another surface asked for a tab — the Job tab's "Open conversation", so far. Cleared
        // here, so nothing is left holding a request that has already been honoured.
        .onChange(of: appState.requestedTab) { _, requested in
            guard let requested else { return }
            selectedTab = EditionPresentation.tab(requested, restricted: restricted)
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
    }
}
