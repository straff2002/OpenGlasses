import SwiftUI

/// Voice tab — the primary interaction screen, kept to three zones:
///
///   1. Status (top): one StatusIndicator card — state, mode, persona, and the
///      glasses/OpenClaw connection pills merged into its footer row
///   2. Conversation (center): the coral voice waveline, ambient captions, transcript
///   3. Controls (bottom): quick-action row, chat input or hero capsule + actions
struct VoiceTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showPreview = false
    @State private var showModelPicker = false
    @State private var showPersonaPicker = false
    @State private var showChatInput = false

    private var session: GeminiLiveSessionManager { appState.geminiLiveSession }
    private var openAISession: OpenAIRealtimeSessionManager { appState.openAIRealtimeSession }

    private var isRealtime: Bool { appState.currentMode.isRealtime }

    var body: some View {
        // One observation point derives the voice state; the ambience (background radiance) and
        // the waveline express it together — a single motion system, not scattered effects.
        VoiceStateProvider(session: session, openAISession: openAISession,
                           speech: appState.speechService) { voiceState in
        ZStack {
            VoiceAmbience(state: voiceState).ignoresSafeArea()

            VStack(spacing: 0) {
                // Recording indicator
                if appState.videoRecorder.isRecording {
                    recordingBadge
                        .padding(.top, 8)
                }

                // Status card — one status surface: state, mode, persona, and the connection
                // pills (formerly their own band above the card).
                StatusIndicator(session: session, openAISession: openAISession,
                                openClawBridge: appState.openClawBridge)
                    .padding(.top, 12)

                Spacer()

                // Voice-state waveline — the assistant's presence. Decorative and additive:
                // StatusIndicator stays the source of truth for connection/mode state.
                VoiceWaveline(state: voiceState)
                    .padding(.horizontal, 24)

                Spacer()

                // Ambient captions
                if appState.ambientCaptions.isActive {
                    AmbientCaptionOverlay(captionService: appState.ambientCaptions)
                        .padding(.bottom, 8)
                }

                // Transcript
                TranscriptOverlay(session: session, openAISession: openAISession)
                    .padding(.bottom, 8)

                // Chat input bar (when active) or voice controls. The control dock
                // (BottomControlBar) owns the model chip and quick actions as tiles.
                if showChatInput && !isRealtime {
                    ChatInputBar(showChatInput: $showChatInput)
                } else {
                    VoiceTabControls(
                        session: session,
                        openAISession: openAISession,
                        showPreview: $showPreview,
                        showModelPicker: $showModelPicker,
                        showChatInput: $showChatInput
                    )
                }
            }
        }
        }
        .fullScreenCover(isPresented: $showPreview) {
            LivePreviewView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(appState: appState)
        }
        .sheet(isPresented: $showPersonaPicker) {
            PersonaPickerSheet(appState: appState)
        }
        .sheet(item: $appState.pendingShareItem) { item in
            ShareSheet(items: item.items)
        }
    }

    // MARK: - Recording Badge

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("REC \(appState.videoRecorder.formattedDuration)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.red.opacity(0.3)))
        // `.accessibilityLabel` on an HStack does not absorb its children: the raw "REC 00:12"
        // text stayed in the tree as a second stop, and VoiceOver spells "REC".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording video")
        .accessibilityValue(appState.videoRecorder.formattedDuration)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Voice Tab Controls (hero capsule + secondary buttons)

/// Bottom controls for the Voice tab — reuses the original BottomControlBar patterns.
private struct VoiceTabControls: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

    @Binding var showPreview: Bool
    @Binding var showModelPicker: Bool
    @Binding var showChatInput: Bool

    var body: some View {
        BottomControlBar(
            session: session,
            openAISession: openAISession,
            showSettings: .constant(false),
            showModelPicker: $showModelPicker,
            showPreview: $showPreview,
            showChatInput: $showChatInput
        )
    }
}

// MARK: - Chat Input Bar

/// Voice-tab inline chat input — the hero capsule's typed-message alternative.
/// A thin wrapper over the shared `ChatComposer`: the mic button switches back to voice,
/// and sends route through the standard voice pipeline (spoken reply preserved).
struct ChatInputBar: View {
    @EnvironmentObject var appState: AppState
    @Binding var showChatInput: Bool

    var body: some View {
        ChatComposer(autoFocus: true, voiceAction: { showChatInput = false }) { text, image in
            Task { await appState.sendTextMessage(text, imageData: image) }
        }
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
    @ViewBuilder var content: (VoiceVisualState) -> Content

    var body: some View {
        content(VoiceVisualState.from(
            isSpeaking: speech.isSpeaking || session.isModelSpeaking || openAISession.isModelSpeaking,
            isProcessing: appState.isProcessing,
            isListening: appState.isListening,
            realtimeActive: session.isActive || openAISession.isActive))
    }
}
