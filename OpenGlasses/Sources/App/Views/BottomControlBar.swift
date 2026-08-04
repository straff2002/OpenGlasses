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

            // Utility row: everything else, one tile idiom, scrolls when it outgrows the width.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // Contextual: on-device model chip (was a full-width band above the bar).
                    if let local = appState.llmService.localLLMService,
                       let active = Config.activeModel, active.llmProvider == .local {
                        LocalModelTile(service: local, modelConfig: active)
                    }

                    // Model picker rides next to the load chip — the two model controls
                    // read as one group.
                    BarButton(
                        icon: "brain",
                        label: appState.llmService.activeModelName,
                        truncateLabel: true
                    ) {
                        showModelPicker = true
                    }

                    // The user's quick actions (was its own band of glass tiles).
                    if appState.isConnected && appState.currentMode == .direct {
                        QuickActionTiles()
                    }

                    cameraButton

                    if previewVisible {
                        BarButton(
                            icon: "eye",
                            label: "Preview",
                            isActive: appState.videoRecorder.isRecording
                        ) {
                            showPreview = true
                        }
                    }

                    if let chatBinding = showChatInput {
                        BarButton(icon: "keyboard", label: "Type") {
                            chatBinding.wrappedValue = true
                        }
                    }

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

                    if Config.accessibilityModeEnabled {
                        BarButton(
                            icon: assistive.isActive ? "eye.fill" : "eye",
                            label: assistive.isActive ? "Assistive On" : "Assistive",
                            isActive: assistive.isActive
                        ) {
                            appState.toggleAssistiveMode()
                        }
                    }

                    if appState.isConnected {
                        // "Sleep" undersold what this does — it disconnects the glasses
                        // session outright (stops speech, wake word, camera, live sessions).
                        BarButton(icon: "moon.fill", label: "Disconnect") {
                            appState.disconnectGlasses()
                        }
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
                isActive: true,
                color: .orange
            ) {
                appState.cancelCurrentResponse()
            }
        } else if appState.isListening {
            // Active voice session — explicit End button. Shown regardless of glasses
            // connection so Push-to-Talk / phone-only sessions can always be stopped.
            ActionCapsule(
                icon: "stop.circle.fill",
                label: "Tap to stop",
                isActive: true,
                color: .orange,
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
                label: appState.cameraService.isStreaming ? "Streaming" : "Camera",
                isActive: appState.cameraService.isStreaming,
                isDisabled: !realtimeSessionActive
            ) {
                if realtimeSessionActive && !appState.cameraService.isStreaming {
                    Task {
                        do { try await appState.cameraService.startStreaming() }
                        catch { appState.errorMessage = "Camera: \(error.localizedDescription)" }
                    }
                }
            }
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
        }
    }

}

// MARK: - Action Capsule (primary touch target)

/// Wide capsule button — the main interaction element.
/// Sized for easy thumb hits from either hand edge.
private struct ActionCapsule: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    var color: Color = .white
    var showMuteBadge: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if icon == "OpenGlassesLogo" {
                        LogoIcon(size: 18)
                            .foregroundStyle(color)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(color)
                    }

                    if showMuteBadge {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.red)
                            .padding(3)
                            .background(.black.opacity(0.7), in: Circle())
                            .offset(x: 12, y: -8)
                    }
                }

                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(.label))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(isActive ? color.opacity(0.15) : Color.clear)
            .glassEffect(in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showMuteBadge ? "\(label), microphone muted" : label)
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

    private var foreground: Color {
        if isDisabled { return .secondary }
        if let tint, isActive { return tint }
        return .primary
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if icon == "OpenGlassesLogo" {
                        LogoIcon(size: 18)
                            .foregroundStyle(foreground)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(foreground)
                    }

                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(.label))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 10, y: -8)
                    }
                }
                .frame(width: 32, height: 28)

                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(foreground)   // .secondary was illegible over the ambience tint
                        .lineLimit(1)
                        .truncationMode(truncateLabel ? .middle : .tail)
                }
            }
            .frame(minWidth: 58, minHeight: 48)
            .padding(.horizontal, 2)
            .background(
                (tint ?? Color.primary).opacity(isActive ? 0.12 : 0),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .contentShape(Rectangle())
        }
        .disabled(isDisabled || isBusy)
        .opacity(isDisabled ? 0.4 : 1)
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
            tint: isLoaded ? .green : accent,
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
