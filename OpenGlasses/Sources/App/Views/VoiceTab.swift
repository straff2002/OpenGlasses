import SwiftUI
import Combine

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
    @State private var captionsActive = false
    @AppStorage("myDayEnabled") private var myDayEnabled = false
    @ScaledMetric(relativeTo: .caption) private var recordingDot: CGFloat = 8
    @Environment(\.dynamicTypeSize) private var typeSize

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

                if typeSize.isAccessibilitySize {
                    accessibleConversationZone(voiceState)
                } else {
                    conversationZone(voiceState)
                }

                // Chat input bar (when active) or voice controls. The control dock
                // (BottomControlBar) owns the model chip and quick actions as tiles.
                // Pinned below the zone above in both layouts: the primary control
                // is the last thing that should need scrolling to.
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
        .onReceive(appState.ambientCaptions.$isActive) { captionsActive = $0 }
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

    // MARK: - Conversation zone

    /// The shipped three-zone composition: status card at the top, useful day context in the
    /// middle, then captions and transcript above the dock. My Day contracts while listening and
    /// yields the centre entirely while the assistant thinks or speaks, or while live captions
    /// need the space to keep every line readable.
    @ViewBuilder
    private func conversationZone(_ voiceState: VoiceVisualState) -> some View {
        // Status card — one status surface: state, mode, persona, and the connection
        // pills (formerly their own band above the card).
        StatusIndicator(session: session, openAISession: openAISession,
                        openClawBridge: appState.openClawBridge)
            .padding(.top, 12)

        Spacer()

        if shouldShowMyDay(for: voiceState) {
            MyDayHomeView(
                service: appState.myDayService,
                isEnabled: $myDayEnabled,
                compact: voiceState == .listening
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }

        Spacer()

        // Ambient captions
        if captionsActive {
            AmbientCaptionOverlay(captionService: appState.ambientCaptions)
                .padding(.bottom, 8)
        }

        // Transcript
        TranscriptOverlay(session: session, openAISession: openAISession)
            .padding(.bottom, 8)
    }

    /// The same zone at accessibility text sizes, where it has to scroll.
    ///
    /// The shipped layout is a fixed `VStack` whose middle is held open by two `Spacer`s, and it
    /// fits only because almost nothing in it used to grow: the status line, the mode line and the
    /// dock captions were all fixed point sizes. Putting them on Dynamic Type — the job of this
    /// phase — is what made the surface honest, and immediately made it overflow: at AX5 the
    /// status card alone ran off the top of the screen and the dock off the bottom, with no way to
    /// reach either. `Spacer`s cannot absorb that; they are already at zero.
    ///
    /// So above the accessibility threshold the conversation zone scrolls and the dock stays
    /// pinned, which is the same trade onboarding's hero pages make. Unlike the old decorative
    /// waveline, My Day is content, so it remains reachable here and uses its compact form while
    /// listening. It still yields while the assistant thinks or speaks, and while live captions
    /// are active so the same content priority applies at every text size.
    @ViewBuilder
    private func accessibleConversationZone(_ voiceState: VoiceVisualState) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                StatusIndicator(session: session, openAISession: openAISession,
                                openClawBridge: appState.openClawBridge)

                if shouldShowMyDay(for: voiceState) {
                    MyDayHomeView(
                        service: appState.myDayService,
                        isEnabled: $myDayEnabled,
                        compact: voiceState == .listening
                    )
                }

                if captionsActive {
                    AmbientCaptionOverlay(captionService: appState.ambientCaptions)
                }

                TranscriptOverlay(session: session, openAISession: openAISession)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    /// Captions are current speech and cannot be recovered if their rows are compressed. My Day
    /// remains one tap away after the caption session ends, so it gives the conversation zone to
    /// captions just as it already does to an assistant response.
    private func shouldShowMyDay(for voiceState: VoiceVisualState) -> Bool {
        guard !captionsActive else { return false }
        return voiceState != .thinking && voiceState != .speaking
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
