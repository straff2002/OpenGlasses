import SwiftUI
import Combine

/// Voice tab — the primary interaction screen, kept to three zones:
///
///   1. Status (top): one StatusIndicator card — state, mode, persona, and the
///      glasses/OpenClaw connection pills merged into its footer row
///   2. Conversation (center): My Day, ambient captions, transcript — scrolls, so the dock
///      below it always gets its height
///   3. Controls (bottom): the grid panel of controls and content tiles, then the hero capsule
///      beneath it on its own glass — the biggest, most-used target nearest the thumb
struct VoiceTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showPreview = false
    @State private var showModelPicker = false
    @State private var showPersonaPicker = false
    @State private var showChatInput = false
    @State private var captionsActive = false
    @AppStorage("myDayEnabled") private var myDayEnabled = false
    @ScaledMetric(relativeTo: .caption) private var recordingDot: CGFloat = 8

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

            // The tab's usable height, read once and handed down to the dock, which sizes its
            // resting rows from it. One-way: the panel decides from the screen, the conversation
            // zone takes what is left. The reverse would be circular.
            GeometryReader { tab in
            VStack(spacing: 0) {
                // Recording indicator
                if appState.videoRecorder.isRecording {
                    recordingBadge
                        .padding(.top, 8)
                }

                conversationZone(voiceState)

                // Chat input bar (when active) or the control dock — the grid panel with the
                // capsule beneath it. Pinned below the zone above and laid out first: the primary
                // control is the last thing that should need scrolling to, and the zone takes
                // whatever height is left over.
                Group {
                    if showChatInput && !isRealtime {
                        ChatInputBar(showChatInput: $showChatInput)
                    } else {
                        VoiceTabControls(
                            session: session,
                            openAISession: openAISession,
                            showPreview: $showPreview,
                            showModelPicker: $showModelPicker,
                            showChatInput: $showChatInput,
                            showsActions: HomeSurfaceVisibility.showsActionTiles(
                                mode: appState.currentMode),
                            voiceState: voiceState,
                            availableHeight: tab.size.height
                        )
                    }
                }
                // Stated, not inferred: the dock is laid out at its full height first and the zone
                // above takes what is left. Both children of this stack are flexible in the
                // vertical axis, and leaving the split to the default meant the dock could be
                // squeezed — which is the shape the overflow regression took.
                .layoutPriority(1)
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
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
    }

    // MARK: - Conversation zone

    /// Status card, then My Day, then captions and the transcript — one order and one 16 pt scale
    /// at every text size, with the dock pinned below it.
    ///
    /// The zone is a scroll view inside a `GeometryReader`, and that combination is the fix for a
    /// functional regression, not a nicety. The zone used to be a fixed `VStack` sharing one
    /// column with the dock: when a long reply arrived and the dock was two rows tall, the column's
    /// intrinsic height exceeded the tab and a `VStack` in that position does not clip or scroll —
    /// it overflows. The overflow pushed the bottom of the dock past the tab bar, so the capsule
    /// stayed visible while the tiles under it were outside the hittable area. A scroll view
    /// accepts any height down to zero, so the dock always gets its intrinsic height first and
    /// every tile stays on screen and tappable; the `minHeight` keeps the old top-aligned rhythm,
    /// with the flexible spacer holding the transcript against the dock whenever the content is
    /// short enough for that to mean anything.
    @ViewBuilder
    private func conversationZone(_ voiceState: VoiceVisualState) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    // Status card — one status surface: state, mode, persona, and the connection
                    // pills (formerly their own band above the card).
                    StatusIndicator(session: session, openAISession: openAISession,
                                    openClawBridge: appState.openClawBridge)

                    if HomeSurfaceVisibility.showsMyDay(state: voiceState,
                                                        captionsActive: captionsActive) {
                        MyDayHomeView(
                            service: appState.myDayService,
                            isEnabled: $myDayEnabled,
                            compact: voiceState == .listening
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }

                    Spacer(minLength: 0)

                    if captionsActive {
                        AmbientCaptionOverlay(captionService: appState.ambientCaptions)
                    }

                    // The transcript moved into the dock's conversation page. The error card did
                    // not: the panel pages, and a failure the wearer has to see must not be one
                    // swipe from invisible.
                    SessionNoticeOverlay(session: session, openAISession: openAISession)
                }
                .padding(.top, 12)
                // Content never ends flush against the dock. When the zone does have to scroll,
                // the clip line landed exactly on the panel's edge and read as a card that had
                // been cut in half rather than one with more below it — the gap is what makes
                // "there is more here" legible at a glance.
                .padding(.bottom, 16)
                // Exactly the viewport when the content is shorter, so a short surface keeps the
                // old rhythm — top-aligned modules, transcript held down against the dock — and
                // does not become a scroll view for no reason.
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            // And when it scrolls, it says so. A surface whose only cue was a flush-cut card is
            // the surface this fix exists for.
            .scrollIndicators(.automatic)
        }
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

// MARK: - Voice Tab Controls (hero capsule + secondary buttons)

/// Bottom controls for the Voice tab — reuses the original BottomControlBar patterns.
private struct VoiceTabControls: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

    @Binding var showPreview: Bool
    @Binding var showModelPicker: Bool
    @Binding var showChatInput: Bool
    let showsActions: Bool
    let voiceState: VoiceVisualState
    let availableHeight: CGFloat

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
            availableHeight: availableHeight
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
