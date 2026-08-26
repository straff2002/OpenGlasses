import SwiftUI

/// Root tab view — Voice / Modes / Chat / Settings.
///
/// Replaces the previous single-screen modal design with a proper
/// tab bar matching the OpenVision-style navigation.
struct MainView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    @State private var showOnboarding = Config.needsOnboarding
    // Default is "system" — the app follows the phone's appearance unless the user has
    // said otherwise. Kept in sync with `SettingsView` and `LookFeelSettingsScreen`.
    @AppStorage("appAppearance") private var appearance: String = "system"
    @AppStorage("accentColorName") private var accentColorName: String = AppAccent.defaultPresetID

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

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab("Voice", systemImage: "waveform", value: 0) {
                    VoiceTab()
                }

                Tab("Modes", systemImage: "person.2.fill", value: 1) {
                    NavigationStack {
                        PersonaPickerTab(appState: appState)
                    }
                }

                Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: 2) {
                    ChatListView()
                }

                Tab("Settings", systemImage: "gearshape.fill", value: 3) {
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
    }
}
