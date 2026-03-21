import SwiftUI

/// Primary interaction view.
/// Full-screen dark canvas with layered components:
///   1. ConnectionBanner (top)
///   2. StatusIndicator (center, ambient)
///   3. TranscriptOverlay (floating cards above controls)
///   4. BottomControlBar (bottom edge)
struct MainView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false
    @State private var showModelPicker = false
    @State private var showPreview = false
    @State private var showOnboarding = Config.needsOnboarding

    var body: some View {
        let session = appState.geminiLiveSession
        let openAISession = appState.openAIRealtimeSession

        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Recording indicator at top
                if appState.videoRecorder.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("REC \(appState.videoRecorder.formattedDuration)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.red.opacity(0.3)))
                    .padding(.top, 8)
                }

                ConnectionBanner(
                    session: session,
                    openAISession: openAISession,
                    openClawBridge: appState.openClawBridge
                )
                .padding(.top, 4)

                Spacer()

                StatusIndicator(session: session, openAISession: openAISession)

                Spacer()

                // Ambient captions (shown on phone screen when active)
                if appState.ambientCaptions.isActive {
                    AmbientCaptionOverlay(captionService: appState.ambientCaptions)
                        .padding(.bottom, 8)
                }

                TranscriptOverlay(session: session, openAISession: openAISession)
                    .padding(.bottom, 8)

                BottomControlBar(
                    session: session,
                    openAISession: openAISession,
                    showSettings: $showSettings,
                    showModelPicker: $showModelPicker,
                    showPreview: $showPreview
                )
            }

            if showOnboarding {
                OnboardingOverlay(showSettings: $showSettings, isVisible: $showOnboarding)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showOnboarding)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(appState: appState)
        }
        .onChange(of: showSettings) { _, isShowing in
            if !isShowing {
                showOnboarding = Config.needsOnboarding
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(appState: appState)
        }
        .fullScreenCover(isPresented: $showPreview) {
            LivePreviewView()
                .environmentObject(appState)
        }
        .sheet(item: $appState.pendingShareItem) { item in
            ShareSheet(items: item.items)
        }
    }
}
