import SwiftUI

/// Root tab view — Voice / Modes / History / Settings.
///
/// Replaces the previous single-screen modal design with a proper
/// tab bar matching the OpenVision-style navigation.
struct MainView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    @State private var showOnboarding = Config.needsOnboarding
    @AppStorage("appAppearance") private var appearance: String = "dark"
    @AppStorage("accentColorName") private var accentColorName: String = "green"

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

                Tab("History", systemImage: "clock.arrow.circlepath", value: 2) {
                    NavigationStack {
                        ConversationHistoryView()
                    }
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
    }
}
