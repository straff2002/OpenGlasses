import SwiftUI
import PhotosUI

/// The control dock — two glass surfaces above the tab bar, bottom-most first:
///
///   Capsule (bottom): the wide mic/action capsule on its own glass, nearest the thumb. It is the
///                     control reached most often and by far the largest target, so it sits at the
///                     bottom of the reach rather than on top of a grid of small ones.
///   Panel (above):    one grid of identical tiles wrapping into rows of four — controls and the
///                     user's canned prompts together, sized to a whole number of rows and
///                     scrolling past three of them.
///
/// The panel used to hold controls only, with a second grid of content tiles as its own card on the
/// home surface. Two grids of identical tiles stacked one above the other read as one thing split
/// in half, so there is one grid, one arrangement and one editor. Controls are always present;
/// content tiles yield with the rest of the home surface and their rows close up behind them.
///
/// The PANEL is the glass; tiles are flat on it. One blur layer instead of a stack of
/// per-tile blurs — deliberately cheaper to composite over the animating ambience. The capsule
/// carries its own capsule-shaped glass, which is what it always drew; stacking that inside the
/// panel's rectangle was glass on glass, and separating them is what lets the two swap places.
struct BottomControlBar: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject private var assistive = AssistiveModeService.shared
    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize

    @Binding var showSettings: Bool
    @Binding var showModelPicker: Bool
    @Binding var showPreview: Bool
    var showChatInput: Binding<Bool>? = nil
    /// The home surface's yielding rule, reaching the dock: false while the assistant thinks or
    /// speaks, while live captions run, and while the mic is open.
    var showsActions: Bool = true

    @State private var runningActionId: String?
    @State private var showLayoutEditor = false

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
    /// The legacy control-only order. Nothing writes it any more — the unified editor writes
    /// `homeGridArrangement` — but it is still read, so a bar a user arranged before the two grids
    /// merged keeps its order without a migration step.
    @AppStorage("dockItemOrder") private var dockOrder = ""
    /// The one arrangement: controls and content actions, order and hidden set.
    @AppStorage("homeGridArrangement") private var storedArrangement = ""

    private var photoDisabledForLocalModel: Bool {
        guard let model = Config.activeModel, model.llmProvider == .local else { return false }
        return !model.visionEnabled
    }

    private var slots: [DockSlot] {
        let controlOrder = DockLayout.decode(dockOrder)
        let quickActions = Config.quickActions
        let available = DockGridCatalog.available(controlOrder: controlOrder,
                                                  quickActions: quickActions).map(\.id)
        let arrangement = HomeGridStore.decode(storedArrangement, available: available).arrangement
        return DockGridCatalog.slots(arrangement: arrangement,
                                     controlOrder: controlOrder,
                                     quickActions: quickActions,
                                     showsActions: showsActions)
    }

    /// Four tiles at their floor width need ~268 pt, which every supported width provides. At
    /// accessibility sizes a tile lays its glyph beside its label and needs the width of a phrase,
    /// so the same four columns would shred every caption — two is the honest count there.
    private var columnCount: Int { typeSize.isAccessibilitySize ? 2 : 4 }

    /// The two scaled parts a tile is made of, so the panel snaps to the height the tile actually
    /// draws rather than to a constant that happens to match at one text size. `BarButton` composes
    /// its glyph box and its single caption line from exactly these.
    @ScaledMetric(relativeTo: .callout) private var tileGlyphBox: CGFloat
        = DockGridMetrics.tileGlyphBox
    @ScaledMetric(relativeTo: .caption) private var tileCaptionLine: CGFloat
        = DockGridMetrics.tileCaptionLine

    /// A row's height: the tile's own, floored at a fingertip. Glyph over caption normally, glyph
    /// beside it at accessibility sizes — the same switch `BarButton` makes.
    private var tileHeight: CGFloat {
        let content = typeSize.isAccessibilitySize
            ? max(tileGlyphBox, tileCaptionLine)
            : tileGlyphBox + DockGridMetrics.tileStackSpacing + tileCaptionLine
        return max(DockGridMetrics.tileMinHeight, content)
    }

    var body: some View {
        // Bottom-most control last: the grid panel, then the capsule beneath it.
        VStack(spacing: 8) {
            gridPanel
            capsule
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .sheet(isPresented: $showLayoutEditor) {
            NavigationStack { DockLayoutEditorView() }
        }
    }

    // MARK: - Grid panel

    private var gridPanel: some View {
        let slots = slots
        let rows = DockGridMetrics.visibleRows(slotCount: slots.count, columns: columnCount)

        // The one grid: controls and content actions, wrapping into rows and scrolling vertically
        // past three of them. Nothing is ever cut off — a tile past the third row is a scroll away,
        // never a sliver at the panel's edge, and VoiceOver walks the same order either way.
        return ScrollView(.vertical) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: DockGridMetrics.rowSpacing),
                               count: columnCount),
                spacing: DockGridMetrics.rowSpacing
            ) {
                // Slots render in the user's arranged order (Settings → Quick Actions → Bar
                // Layout); contextual ones still gate themselves.
                ForEach(slots) { slot in
                    dockView(for: slot)
                }
            }
            .padding(.horizontal, 4)
        }
        // An exact height, not a maximum: a maximum lets the stack hand the panel some other
        // number, and any number that is not a whole multiple of a row is a clipped tile.
        .frame(height: DockGridMetrics.gridHeight(rows: rows, tileHeight: tileHeight))
        // Short grids should not become scroll views: bouncing a grid that already fits reads as
        // the panel coming loose from the tab.
        .scrollBounceBehavior(.basedOnSize)
        // The sighted half of the edit affordance, on the grid's *background* — behind the tiles,
        // so it answers a press on the gaps and never fires alongside a tile's action or the
        // capsule's press-and-hold mute. Settings → Quick Actions → Bar Layout is the half
        // reachable by name; a long press leaves no mark in the accessibility tree.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.6) { showLayoutEditor = true }
        )
        .padding(14)
        .glassEffect(in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12)
    }

    // MARK: - Capsule

    /// The primary control, on its own glass at the bottom of the reach.
    private var capsule: some View {
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
            .padding(.horizontal, 12)
    }

    // MARK: - Slots

    @ViewBuilder
    private func dockView(for slot: DockSlot) -> some View {
        switch slot {
        case .control(let item): dockView(for: item)
        case .action(let entry): actionTile(entry)
        }
    }

    /// A content tile — the same `BarButton` every control uses, because they now share a grid and
    /// anything less than identical reads as two grids again.
    @ViewBuilder
    private func actionTile(_ entry: HomeGridEntry) -> some View {
        if case .quickAction(let action) = entry, action.type == .toggleRecording {
            // Live tile: reflects recording state and duration, unlike the fire-and-forget tiles.
            RecordingQuickActionTile(
                action: action,
                controller: appState.sessionRecorder,
                audioRecorder: appState.audioRecorder
            )
        } else {
            let blocked = entry.capturesPhoto && photoDisabledForLocalModel
            BarButton(
                icon: entry.icon,
                label: entry.label,
                isDisabled: blocked,
                isBusy: runningActionId == entry.id,
                truncateLabel: true
            ) {
                guard runningActionId == nil else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                runningActionId = entry.id
                Task {
                    await HomeGridDispatcher.run(entry, on: appState)
                    runningActionId = nil
                }
            }
            .accessibilityHint(
                blocked ? "The on-device model cannot see images. Choose a vision model."
                : runningActionId == entry.id ? "Running." : entry.spokenHint)
        }
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
            let provider = Config.activeModel?.llmProvider ?? .custom
            BarButton(
                icon: DockLayout.modelTileGlyph(for: provider),
                label: "Model",
                assetIcon: ProviderMark.bundledAsset(for: provider)
            ) {
                showModelPicker = true
            }
            .accessibilityLabel("Model: \(appState.llmService.activeModelName). Opens the model picker.")

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
    /// A bundled image asset to draw instead of `icon` when one is present — the seam a provider's
    /// own mark drops into. Template-rendered, so it takes the tile's foreground like every other
    /// glyph and never arrives as an off-palette full-colour logo.
    var assetIcon: String? = nil
    var action: () -> Void = {}

    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var glyph: CGFloat = 18
    @ScaledMetric(relativeTo: .callout) private var tileWidth: CGFloat = 32
    /// The parts the dock panel also measures, so the height it snaps its rows to is the height
    /// this tile draws. Shared bases, not literals: the panel showing a sliver of a fourth row is
    /// exactly what these two drifting apart looks like.
    @ScaledMetric(relativeTo: .callout) private var tileHeight: CGFloat
        = DockGridMetrics.tileGlyphBox
    /// Floors, not scaled metrics: the tile's glyph box and its caption grow on
    /// their own, and these only stop a tile being smaller than a fingertip.
    private let minTileWidth = DockGridMetrics.tileMinWidth
    private let minTileHeight = DockGridMetrics.tileMinHeight
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
            VStack(spacing: DockGridMetrics.tileStackSpacing, content: content)
        }
    }

    var body: some View {
        Button(action: action) {
            // Glyph over label normally; glyph *beside* label at accessibility sizes.
            //
            // Stacked, a tile is as tall as its glyph box plus its caption, and at AX5 that is
            // around 130pt — for a grid of them, above a capsule, in a dock that also has to leave
            // the screen room for the conversation. Laid out side by side the same tile is about
            // the height of one line, and the grid scrolls vertically inside its bounded height,
            // so the space it needs is there. Nothing is dropped or renamed; the parts change
            // places.
            tileLayout {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if icon == "OpenGlassesLogo" {
                        LogoIcon(size: glyph)
                            .foregroundStyle(foreground)
                    } else if let assetIcon {
                        Image(assetIcon)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: glyph, height: glyph)
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

// MARK: - Provider mark

/// Whether a provider's own brand mark is bundled, so the model tile can prefer it over the
/// SF-symbol stand-in. Asset-first by design: dropping `ProviderMark-<provider>` into the catalog
/// is the whole change, and nothing here draws an approximation of a mark that isn't there.
enum ProviderMark {
    static func bundledAsset(for provider: LLMProvider) -> String? {
        let name = DockLayout.providerMarkAsset(for: provider)
        return UIImage(named: name) == nil ? nil : name
    }
}

// MARK: - Recording tile

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

// MARK: - Session seams

/// Every content tile reaches the session through a call some other surface already makes: a canned
/// prompt is `ChatInputBar`'s send, a photo prompt is the dock camera's capture-and-ask, and a
/// speed-dial action is the one the widget, the watch and the launcher all run.
extension AppState: HomeGridSession {
    func submitHomePrompt(_ text: String) async {
        await sendTextMessage(text)
    }

    func submitHomePhotoPrompt(_ text: String) async {
        await capturePhotoAndSend(prompt: text)
    }

    func runHomeQuickAction(_ action: QuickAction) async {
        await executeQuickAction(action)
    }
}

