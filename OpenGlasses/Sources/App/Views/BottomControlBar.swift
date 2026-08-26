import SwiftUI
import PhotosUI

/// The control dock — ONE floating glass panel above the tab bar holding every control in a
/// single visual language (previously four stacked bands in four styles: full-width model bar,
/// glass quick-action tiles, hero capsule, plain utility buttons).
///
/// Layout inside the panel:
///   Row 1 (primary):  wide mic/action capsule — the only large element, the main touch target.
///   Row 2 (utility):  one horizontally-scrolling row of identical tiles — local-model chip
///                     first (contextual), then the user's quick actions, then system utilities.
///
/// The PANEL is the glass; tiles are flat on it. One blur layer instead of a stack of
/// per-tile blurs — deliberately cheaper to composite over the animating ambience.
struct BottomControlBar: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject private var assistive = AssistiveModeService.shared
    @Environment(\.appAccent) private var accent

    @Binding var showSettings: Bool
    @Binding var showModelPicker: Bool
    @Binding var showPreview: Bool
    var showChatInput: Binding<Bool>? = nil

    private var isRealtime: Bool { appState.currentMode.isRealtime }
    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode == .openaiRealtime }

    private var realtimeSessionActive: Bool {
        isGemini ? session.isActive : (isOpenAI ? openAISession.isActive : false)
    }

    private var previewVisible: Bool { appState.isConnected }

    /// Observes the same UserDefaults key `Config.silentMode` writes, so the push-to-talk
    /// BarButton re-renders on toggle AND stays live-synced with the Settings switch.
    @AppStorage("silentMode") private var pushToTalk = false
    /// Arranged item order (Settings → Quick Actions → Bar Layout); empty = shipped order.
    @AppStorage("dockItemOrder") private var dockOrder = ""

    private var photoDisabledForLocalModel: Bool {
        guard let model = Config.activeModel, model.llmProvider == .local else { return false }
        return !model.visionEnabled
    }

    var body: some View {
        VStack(spacing: 12) {
            // Primary: wide action capsule
            heroCapsule
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            appState.micMuted.toggle()
                        }
                )
                // Mute lives *only* on this long press. A sighted user finds it by accident; a
                // VoiceOver user finds it never, because a gesture leaves no mark in the
                // accessibility tree. The hint is the only place it is discoverable — and the
                // custom action is the only way to reach it, since VoiceOver swallows the
                // long press for its own element-inspection gesture.
                .accessibilityHint(appState.micMuted
                                   ? "Double-tap and hold to unmute the microphone."
                                   : "Double-tap and hold to mute the microphone.")
                .accessibilityAction(named: appState.micMuted ? "Unmute microphone"
                                                              : "Mute microphone") {
                    appState.micMuted.toggle()
                }

            // Utility row: everything else, one tile idiom, scrolls when it outgrows the width.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Items render in the user's arranged order (Settings → Quick
                    // Actions → Bar Layout); contextual ones still gate themselves.
                    ForEach(DockLayout.decode(dockOrder)) { item in
                        dockView(for: item)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(14)
        .glassEffect(in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Dock items

    /// One arrangeable slot of the scrolling row. Contextual gating lives with
    /// the item, so moving a slot never changes WHEN it appears — only where.
    @ViewBuilder
    private func dockView(for item: DockItem) -> some View {
        switch item {
        case .model:
            // Contextual: on-device model chip rides just before the picker —
            // the two model controls read as one group wherever they're placed.
            if let local = appState.llmService.localLLMService,
               let active = Config.activeModel, active.llmProvider == .local {
                LocalModelTile(service: local, modelConfig: active)
            }
            BarButton(
                icon: "brain",
                label: appState.llmService.activeModelName,
                truncateLabel: true
            ) {
                showModelPicker = true
            }

        case .quickActions:
            // The user's quick actions (was its own band of glass tiles).
            if appState.isConnected && appState.currentMode == .direct {
                QuickActionTiles()
            }

        case .camera:
            cameraButton

        case .preview:
            if previewVisible {
                BarButton(
                    icon: "eye",
                    label: "Preview",
                    isActive: appState.videoRecorder.isRecording
                ) {
                    showPreview = true
                }
            }

        case .type:
            if let chatBinding = showChatInput {
                BarButton(icon: "keyboard", label: "Type") {
                    chatBinding.wrappedValue = true
                }
            }

        case .micMode:
            // Push-to-talk toggle — same switch as Settings (one owner: AppState.setPushToTalk).
            // Labelled with the mode a tap switches TO, not the current one: showing the
            // current mode read as a state badge, and people hunting for push-to-talk
            // couldn't tell this button was where to change it.
            BarButton(
                icon: pushToTalk ? "waveform" : "hand.tap.fill",
                label: pushToTalk ? "Wake Word" : "Push-Talk",
                isActive: false
            ) {
                appState.setPushToTalk(!pushToTalk)
            }
            .accessibilityLabel(pushToTalk ? "Switch to wake word listening" : "Switch to push to talk")

        case .assistive:
            if Config.accessibilityModeEnabled {
                BarButton(
                    icon: assistive.isActive ? "eye.fill" : "eye",
                    label: assistive.isActive ? "Assistive On" : "Assistive",
                    isActive: assistive.isActive
                ) {
                    appState.toggleAssistiveMode()
                }
            }

        case .disconnect:
            if appState.isConnected {
                // "Sleep" undersold what this does — it disconnects the glasses
                // session outright (stops speech, wake word, camera, live sessions).
                BarButton(icon: "moon.fill", label: "Disconnect") {
                    appState.disconnectGlasses()
                }
            }
        }
    }

    // MARK: - Hero Capsule

    @ViewBuilder
    private var heroCapsule: some View {
        if isGemini {
            ActionCapsule(
                icon: session.isActive ? "stop.fill" : "play.fill",
                label: session.isActive ? "Stop Session" : "Start Gemini Live",
                isActive: session.isActive,
                color: session.isActive ? .red : accent
            ) {
                Task {
                    if session.isActive { session.stopSession() }
                    else { await session.startSession() }
                }
            }
        } else if isOpenAI {
            ActionCapsule(
                icon: openAISession.isActive ? "stop.fill" : "play.fill",
                label: openAISession.isActive ? "Stop Session" : "Start OpenAI Realtime",
                isActive: openAISession.isActive,
                color: openAISession.isActive ? .red : accent
            ) {
                Task {
                    if openAISession.isActive { openAISession.stopSession() }
                    else { await openAISession.startSession() }
                }
            }
        } else if appState.isProcessing || appState.speechService.isSpeaking {
            ActionCapsule(
                icon: "stop.fill",
                label: appState.speechService.isSpeaking ? "Tap to stop" : "Cancel",
                spokenLabel: appState.speechService.isSpeaking ? "Stop speaking" : "Cancel",
                isActive: true,
                color: OGTheme.warn
            ) {
                appState.cancelCurrentResponse()
            }
        } else if appState.isListening {
            // Active voice session — explicit End button. Shown regardless of glasses
            // connection so Push-to-Talk / phone-only sessions can always be stopped.
            ActionCapsule(
                icon: "stop.circle.fill",
                label: "Tap to stop",
                spokenLabel: "End voice session",
                isActive: true,
                color: OGTheme.warn,
                showMuteBadge: appState.micMuted
            ) {
                appState.endListeningSession()
            }
        } else if !appState.isConnected && !Config.silentMode {
            // Disconnected and not in Push-to-Talk — one tap to reconnect + start listening
            ActionCapsule(
                icon: "OpenGlassesLogo",
                label: "Connect & Talk",
                color: accent
            ) {
                Task {
                    await appState.connectAndListen()
                }
            }
        } else {
            // Idle — tap to talk. Works phone-only (Push-to-Talk) or through the glasses.
            ActionCapsule(
                icon: "mic.fill",
                label: "Tap to talk",
                spokenLabel: "Start talking",
                color: accent,
                showMuteBadge: appState.micMuted
            ) {
                Task {
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected(manual: true)
                }
            }
        }
    }

    // MARK: - Secondary Buttons

    @ViewBuilder
    private var cameraButton: some View {
        if !appState.isConnected {
            BarButton(icon: "OpenGlassesLogo", label: "Connect") {
                Task { await appState.glassesService.connect() }
            }
        } else if isRealtime {
            BarButton(
                icon: "video.fill",
                label: appState.cameraService.isStreaming ? "Streaming"
                     : (appState.cameraService.isStartingStream ? "Starting…" : "Camera"),
                isActive: appState.cameraService.isStreaming || appState.cameraService.isStartingStream,
                // Disabled while starting: the cold start takes seconds, and a second tap during it
                // did nothing visible, which read as the first tap having failed.
                isDisabled: !realtimeSessionActive || appState.cameraService.isStartingStream
            ) {
                if realtimeSessionActive && !appState.cameraService.isStreaming
                    && !appState.cameraService.isStartingStream {
                    Task {
                        do { try await appState.cameraService.startStreaming() }
                        catch {
                            NSLog("[Camera] startStreaming failed: %@", error.localizedDescription)
                            appState.errorMessage = "Camera: \(error.localizedDescription)"
                            NoticeCenter.shared.post("Camera: \(error.localizedDescription)",
                                                     severity: .error, source: .camera)
                        }
                    }
                }
            }
            // Dimmed-and-unexplained is the sighted version of this problem too, but a VoiceOver
            // user gets only "dimmed" — the reason has to be said. The cold start is seconds long,
            // so "starting" is its own answer rather than a silent dead button.
            .accessibilityHint(
                appState.cameraService.isStartingStream ? "Starting the camera. This takes a moment."
                : !realtimeSessionActive ? "Start the live session first."
                : appState.cameraService.isStreaming ? "The camera is already streaming."
                : "Double-tap to stream the glasses camera to the model.")
        } else {
            BarButton(
                icon: "camera.fill",
                label: "Photo",
                isActive: appState.cameraService.isCaptureInProgress,
                isDisabled: appState.cameraService.isCaptureInProgress || photoDisabledForLocalModel
            ) {
                if !photoDisabledForLocalModel {
                    Task { await appState.captureAndAnalyzePhoto() }
                }
            }
            .accessibilityHint(
                photoDisabledForLocalModel ? "The on-device model cannot see images. Choose a vision model."
                : appState.cameraService.isCaptureInProgress ? "Taking a photo."
                : "Double-tap to take a photo and describe it.")
        }
    }

}

// MARK: - Action Capsule (primary touch target)

/// Wide capsule button — the main interaction element.
/// Sized for easy thumb hits from either hand edge.
private struct ActionCapsule: View {
    let icon: String
    let label: String
    /// What VoiceOver says instead of `label`. The visible copy is written as an instruction to a
    /// finger — "Tap to talk", "Tap to stop" — which is the wrong instruction for a VoiceOver user
    /// (the gesture is a double-tap) and reads as a sentence rather than a control name. Nil keeps
    /// the visible copy, for the capsules whose label is already a name.
    var spokenLabel: String? = nil
    var isActive: Bool = false
    var color: Color = .primary
    var showMuteBadge: Bool = false
    let action: () -> Void

    /// The capsule's glyph, and the mute badge that rides it.
    @ScaledMetric(relativeTo: .title3) private var glyph: CGFloat = 18
    @ScaledMetric(relativeTo: .caption2) private var badgeOffsetX: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var badgeOffsetY: CGFloat = 8

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    // The glyph is the hue corrected to read on a wash of
                    // itself — the same treatment the status tile takes, so a
                    // stop-red or a pale accent preset stays legible whether the
                    // capsule is washed (active) or bare glass (idle).
                    Group {
                        if icon == "OpenGlassesLogo" {
                            LogoIcon(size: glyph)
                        } else {
                            Image(systemName: icon)
                                .font(.title3.weight(.semibold))
                        }
                    }
                    .foregroundStyle(OGTheme.tintedAccentLabel(color))

                    if showMuteBadge {
                        Image(systemName: "mic.slash.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(OGTheme.mediaErrorLabel)
                            .padding(3)
                            // Opaque, not the old 0.7 wash: a translucent badge
                            // composites the capsule's glyph through itself and
                            // the failure hue stops clearing 3:1 against it.
                            .background(OGTheme.media, in: Circle())
                            .offset(x: badgeOffsetX, y: -badgeOffsetY)
                    }
                }

                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(.label))
            }
            // The shipped capsule is a fixed 50pt, which clips its own label once
            // the text grows. Rather than scale 50 — which reaches about 155pt at
            // AX5, three times what the content needs — the padding is fixed and
            // the *content* sets the height: 22pt of glyph plus 28pt of padding
            // is the same 50pt at the default size, and grows only as far as the
            // label actually does. The 44pt floor still applies underneath.
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .frame(minHeight: OGMetrics.minTouchTarget)
            .background(isActive ? color.opacity(OGTheme.Opacity.accentFill) : Color.clear)
            .glassEffect(in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // `children: .ignore` is what makes the element *be* the capsule. Left to itself, SwiftUI
        // took the union of the label's children — a 17pt glyph and a line of 15pt text — so the
        // element VoiceOver focused, and the target an audit measures, was 18pt tall inside a
        // 50pt control the whole screen is built around.
        .accessibilityElement(children: .ignore)
        // The mute badge is a 9pt glyph tucked behind the icon — the only thing distinguishing a
        // muted session from a live one, so it has to be spoken, not just drawn. As a *value*
        // rather than glued to the label, so it is re-read when it changes under a held focus.
        .accessibilityLabel(spokenLabel ?? label)
        .accessibilityValue(showMuteBadge ? "Microphone muted" : "")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Bar Button (the dock's single tile idiom)

/// The dock tile — every control in the utility row uses this one idiom. Flat on the dock's
/// glass (no per-tile blur); active state = a soft tint wash behind the tile.
private struct BarButton: View {
    let icon: String
    var label: String = ""
    var isActive: Bool = false
    var isDisabled: Bool = false
    var isBusy: Bool = false
    var badge: String? = nil
    var tint: Color? = nil
    var truncateLabel: Bool = false
    var action: () -> Void = {}

    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var glyph: CGFloat = 18
    @ScaledMetric(relativeTo: .callout) private var tileWidth: CGFloat = 32
    @ScaledMetric(relativeTo: .callout) private var tileHeight: CGFloat = 28
    /// Floors, not scaled metrics: the tile's glyph box and its caption grow on
    /// their own, and these only stop a tile being smaller than a fingertip.
    private let minTileWidth: CGFloat = 58
    private let minTileHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .caption2) private var badgeOffsetX: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var badgeOffsetY: CGFloat = 8

    private var foreground: Color {
        // Disabled reads as the audited quiet grey rather than as everything at
        // 0.4 — see the note on the missing `.opacity` below.
        if isDisabled { return OGTheme.secondaryLabel }
        if let tint, isActive { return OGTheme.tintedAccentLabel(tint) }
        return .primary
    }

    /// Glyph over label, or beside it at accessibility sizes. See the note at the call site.
    @ViewBuilder
    private func tileLayout<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if typeSize.isAccessibilitySize {
            HStack(spacing: 8, content: content)
        } else {
            VStack(spacing: 3, content: content)
        }
    }

    var body: some View {
        Button(action: action) {
            // Glyph over label normally; glyph *beside* label at accessibility sizes.
            //
            // Stacked, a tile is as tall as its glyph box plus its caption, and at AX5 that is
            // around 130pt — for a row of them, above a capsule, in a dock that also has to leave
            // the screen room for the conversation. Laid out side by side the same tile is about
            // the height of one line, and the row already scrolls horizontally, so the space it
            // needs is the axis it has. Nothing is dropped or renamed; the parts change places.
            tileLayout {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if icon == "OpenGlassesLogo" {
                        LogoIcon(size: glyph)
                            .foregroundStyle(foreground)
                    } else {
                        Image(systemName: icon)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(foreground)
                    }

                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(OGTheme.onAccentLabel(accent))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(accent, in: Capsule())
                            .offset(x: badgeOffsetX, y: -badgeOffsetY)
                    }
                }
                .frame(width: tileWidth, height: tileHeight)

                if !label.isEmpty {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(foreground)   // .secondary was illegible over the ambience tint
                        .lineLimit(1)
                        .truncationMode(truncateLabel ? .middle : .tail)
                }
            }
            .padding(.horizontal, typeSize.isAccessibilitySize ? 8 : 0)
            .frame(minWidth: minTileWidth, minHeight: minTileHeight)
            .padding(.horizontal, 2)
            .background(
                (tint ?? Color.primary).opacity(isActive ? OGTheme.Opacity.accentPillFill : 0),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .contentShape(Rectangle())
        }
        .disabled(isDisabled || isBusy)
        // Deliberately no blanket `.opacity(0.4)` on a disabled tile. It applied
        // to the label as well as the glyph, so a disabled caption rendered at
        // roughly a quarter of its ink — under AA by a wide margin, on a control
        // whose whole job in that state is to explain why it can't be used. The
        // dimming now lives in `foreground`, which is a measured value.
        .accessibilityLabel(label.isEmpty ? icon.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ") : label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Local model tile (was the full-width LocalModelBar band)

/// On-device model control as a dock tile: Load (accent) → Loading (spinner) → Loaded
/// (green, tap to unload). Shown only when the active model is local.
private struct LocalModelTile: View {
    @ObservedObject var service: LocalLLMService
    let modelConfig: ModelConfig
    @Environment(\.appAccent) private var accent

    var body: some View {
        let isLoaded = service.isModelLoaded && service.loadedModelId == modelConfig.model
        BarButton(
            icon: isLoaded ? "checkmark.circle.fill" : "cpu",
            label: service.isLoadingModel ? "Loading…" : (isLoaded ? "Unload" : "Load \(modelConfig.name)"),
            isActive: !service.isLoadingModel,   // tinted whenever idle: accent invites Load, green marks Loaded
            isBusy: service.isLoadingModel,
            tint: isLoaded ? OGTheme.ok : accent,
            truncateLabel: true
        ) {
            if isLoaded {
                service.unloadModel()
            } else {
                Task { try? await service.loadModel(modelConfig.model) }
            }
        }
        .accessibilityLabel(isLoaded ? "\(modelConfig.name) loaded. Tap to unload."
                                     : "Load on-device model \(modelConfig.name)")
    }
}

// MARK: - Quick action tiles (was QuickActionsGrid, its own band of glass tiles)

/// The user's configured quick actions as dock tiles — same idiom as every other control.
private struct QuickActionTiles: View {
    @EnvironmentObject var appState: AppState
    @State private var executingActionId: String?

    private var actions: [QuickAction] {
        let all = Config.quickActions
        return Config.showAllQuickActions ? all : Array(all.prefix(4))
    }

    var body: some View {
        ForEach(actions) { action in
            if action.type == .toggleRecording {
                // Live tile: reflects recording state + duration, unlike the fire-and-forget tiles.
                RecordingQuickActionTile(
                    action: action,
                    controller: appState.sessionRecorder,
                    audioRecorder: appState.audioRecorder
                )
            } else {
                BarButton(
                    icon: action.icon,
                    label: action.label,
                    isBusy: executingActionId == action.id
                ) {
                    guard executingActionId == nil else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    executingActionId = action.id
                    Task {
                        await appState.executeQuickAction(action)
                        executingActionId = nil
                    }
                }
                .accessibilityHint(executingActionId == action.id ? "Running" : "Double-tap to execute")
            }
        }
    }
}

/// The record-meeting quick action as a live dock tile: red stop icon + elapsed duration while
/// a preserved recording is running. Observes the controller directly because a nested
/// ObservableObject's changes don't republish through `appState`.
private struct RecordingQuickActionTile: View {
    @EnvironmentObject var appState: AppState
    let action: QuickAction
    @ObservedObject var controller: SessionRecorderController
    @ObservedObject var audioRecorder: AudioRecordingService

    var body: some View {
        BarButton(
            icon: controller.isRecording ? "stop.circle.fill" : action.icon,
            label: controller.isRecording ? audioRecorder.formattedDuration : action.label,
            isActive: controller.isRecording,
            tint: .red
        ) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await appState.executeQuickAction(action) }
        }
        .accessibilityLabel("Record meeting")
        .accessibilityValue(controller.isRecording
                            ? "Recording, \(audioRecorder.formattedDuration)" : "Stopped")
        .accessibilityHint("Double-tap to start or stop recording.")
    }
}
