import SwiftUI
import UIKit

/// Center status panel — card showing current state + quick action buttons.
///
/// The panel grows vertically as the user adds more quick actions.
/// Status info at top, action grid below.
struct StatusIndicator: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject var openClawBridge: OpenClawBridge
    @Environment(\.appAccent) private var accent
    @State private var showDisconnectConfirm = false

    /// The status tile, and the glyph inside it. Scaled rather than fixed so the
    /// tile keeps its proportion to the two lines of text beside it at every
    /// Dynamic Type size instead of shrinking against them.
    @ScaledMetric(relativeTo: .body) private var statusTile: CGFloat = 48
    @ScaledMetric(relativeTo: .title2) private var statusGlyph: CGFloat = 26
    /// The connection pills' logo, which scales with the type beside it.
    @ScaledMetric(relativeTo: .caption) private var pillGlyph: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var statusDot: CGFloat = 5

    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode == .openaiRealtime }
    private var isRealtime: Bool { appState.currentMode.isRealtime }

    var body: some View {
        VStack(spacing: 0) {
            // Status row
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(ringColor.opacity(OGTheme.Opacity.accentPillFill))
                        .frame(width: statusTile, height: statusTile)

                    Group {
                        if iconName == "OpenGlassesLogo" {
                            LogoIcon(size: statusGlyph)
                        } else {
                            Image(systemName: iconName)
                                .font(.title2)
                        }
                    }
                    // The tile paints a hue on a wash of itself, which is the
                    // case `tintedAccentLabel` exists for: it nudges any hue to
                    // the nearest value that clears AA on its own tint, against
                    // the *stronger* wash, so the 0.12 pill fill is covered too.
                    .foregroundStyle(OGTheme.tintedAccentLabel(ringColor))
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color(.label))
                        // Uncapped. The state of the session is the one thing
                        // this card exists to report, the line can be a whole
                        // error message, and the card is free to grow — it is a
                        // card on a screen, not a row in a list. A cap here only
                        // ever buys a card that doesn't change height, and pays
                        // for it by dropping the words.
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(modeLabel)
                            .font(.caption)
                            .foregroundStyle(OGTheme.secondaryLabel)
                            // Wrap rather than truncate: this line shares its
                            // row with the camera chip and its width with a
                            // model name nobody chose for its length.
                            .fixedSize(horizontal: false, vertical: true)

                        if isRealtime && appState.cameraService.isStreaming {
                            HStack(spacing: 3) {
                                Circle().fill(OGTheme.ok)
                                    .frame(width: statusDot, height: statusDot)
                                    .accessibilityHidden(true)
                                Text("CAM")
                                    .font(.system(.caption, design: .monospaced).weight(.bold))
                                    .foregroundStyle(OGTheme.okLabel)
                            }
                            .accessibilityLabel("Camera streaming")
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
            // One stop, one sentence. Split across three Texts it read as "Listening…",
            // "Voice middle dot Claude", "Camera streaming" — three swipes to assemble a fact
            // that is one glance for a sighted user. `.updatesFrequently` is the non-intrusive
            // half of the announcement design: VoiceOver re-reads this while focus is on it,
            // and stays quiet when it isn't, because the transitions themselves are narrated
            // from the state machine.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenStatus)
            .accessibilityAddTraits(.updatesFrequently)

            // Tool call / reconnecting
            if isGemini && session.toolCallStatus.isActive {
                toolCallPill(session.toolCallStatus.displayText, color: AppAccent.aiCoral)
                    .padding(.bottom, 10)
            } else if !isRealtime && appState.llmService.toolCallStatus.isActive {
                toolCallPill(appState.llmService.toolCallStatus.displayText, color: AppAccent.aiCoral)
                    .padding(.bottom, 10)
            }

            if isGemini && session.reconnecting {
                reconnectingLabel.padding(.bottom, 10)
            }
            if isOpenAI && openAISession.reconnecting {
                reconnectingLabel.padding(.bottom, 10)
            }

            // Bottom row: active mode + the connection pills (formerly a separate band above
            // the card — merged here so the home screen is one status surface, not two).
            HStack(spacing: 8) {
                activeModeBadge
                Spacer()
                glassesPill
                if Config.isOpenClawConfigured {
                    openClawPill
                }
            }
            .padding(.horizontal, 16)
            // The pills now carry a full 44pt target, which is taller than the
            // capsules they draw — so the row's own bottom padding comes off to
            // pay for most of it and the card grows by a few points rather than
            // by twenty.
            .padding(.bottom, 4)
        }
        .glassEffect(in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        // A group *name*, not a summary. The card's label used to restate the status and the
        // mode, which the row above now says properly — so a VoiceOver user heard the whole
        // sentence on entering the group and then again on the first swipe inside it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session status")
    }

    // MARK: - Connection pills (merged from the old StatusPillsRow)

    private var glassesPill: some View {
        let connected = appState.isConnected
        let color: Color = connected ? OGTheme.okLabel : OGTheme.errorLabel
        let label = connected ? (appState.glassesService.deviceName ?? "Glasses") : "Disconnected"

        return Button {
            if connected {
                showDisconnectConfirm = true
            } else {
                Task { await appState.glassesService.connect() }
            }
        } label: {
            HStack(spacing: 5) {
                LogoIcon(size: pillGlyph)
                    .foregroundStyle(color)
                if connected {
                    Circle().fill(OGTheme.ok).frame(width: statusDot, height: statusDot)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: .capsule)
            // The drawn capsule stays the size the signature draws it; what
            // grows is the target around it. A pill that *looked* 44pt would be
            // a different status card — this is the same card with a control a
            // finger can actually land on, and it is the reason the footer row
            // gave up its bottom padding above.
            //
            // A *floor*, and deliberately not a `@ScaledMetric` one. 44pt is an
            // absolute minimum for a fingertip, not a type-relative measure: a
            // reader who turns the text up has not grown their thumb, and a
            // scaled 44 reaches about 130pt at AX5, which is a third of the
            // screen for a status dot. The drawn pill still grows on its own,
            // and when it outgrows 44 this stops applying.
            .frame(minWidth: OGMetrics.minTouchTarget,
                   minHeight: OGMetrics.minTouchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .confirmationDialog("Disconnect Glasses", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                appState.disconnectGlasses()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stop mic, camera, and TTS. Gateway tasks keep running.")
        }
        // Without `children: .ignore` the element is the union of the pill's children — a 13pt
        // logo — rather than the pill itself, so VoiceOver's focus ring landed inside the
        // capsule instead of around it.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        // The pill is drawn as a status dot, but it is a button that does opposite things in its
        // two states — which is exactly what a hint is for.
        .accessibilityLabel("Glasses: \(label)")
        .accessibilityHint(connected ? "Double-tap to disconnect the glasses."
                                     : "Double-tap to connect the glasses.")
    }

    private var openClawPill: some View {
        // A 5pt dot reads from the uncorrected hue; the word beside it is what
        // carries the state, so the colour is reinforcement rather than signal.
        let (color, label): (Color, String) = {
            switch openClawBridge.connectionState {
            case .connected: return (OGTheme.ok, "Connected")
            case .checking: return (OGTheme.warn, "Checking")
            case .unreachable: return (OGTheme.error, "Unreachable")
            case .notConfigured: return (OGTheme.secondaryLabel, "Not Set Up")
            }
        }()

        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: statusDot, height: statusDot)
                .accessibilityHidden(true)
            Text("OpenClaw")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OpenClaw: \(label)")
    }

    // MARK: - Active Mode Badge

    private var activeModeBadge: some View {
        let persona = appState.activePersona
        let name = persona?.name ?? "OpenGlasses"
        let icon = persona?.icon ?? "sparkles"
        let connected = appState.isConnected
        // The dot is a fill and the name beside it is text — the same state, two
        // roles, and the raw success hue is unreadable as the second one.
        let dotColor: Color = connected ? OGTheme.ok : OGTheme.secondaryLabel
        let nameColor: Color = connected ? OGTheme.okLabel : OGTheme.secondaryLabel

        return HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: statusDot, height: statusDot)
                .accessibilityHidden(true)
            Group {
                if icon == "OpenGlassesLogo" {
                    LogoIcon(size: pillGlyph)
                } else {
                    Image(systemName: icon)
                        .font(.caption.weight(.medium))
                }
            }
            .foregroundStyle(nameColor)
            .accessibilityHidden(true)
            Text(connected ? "Active mode:" : "Mode:")
                .font(.caption)
                .foregroundStyle(OGTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(nameColor)
                // The badge shares the footer row with the connection pills, and
                // a persona name is user-supplied. Wrapping is the only honest
                // option: truncating loses the one word that says which mode is
                // running.
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        // Disconnected, the interpolation used to open with an empty string, so the line began
        // with a pause and read as " mode: OpenGlasses".
        .accessibilityLabel(connected ? "Active mode: \(name)" : "Mode: \(name)")
    }

    // MARK: - Computed Properties

    private var iconName: String {
        if !appState.isConnected {
            return "OpenGlassesLogo"
        }

        if appState.glassesIdle {
            return "moon.zzz.fill"
        }

        if isGemini {
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return "speaker.wave.3.fill"
            case .ready: return "OpenGlassesLogo"
            case .connecting, .settingUp: return "antenna.radiowaves.left.and.right"
            case .error: return "exclamationmark.triangle.fill"
            case .disconnected: return "OpenGlassesLogo"
            }
        } else if isOpenAI {
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return "speaker.wave.3.fill"
            case .ready: return "OpenGlassesLogo"
            case .connecting, .settingUp: return "antenna.radiowaves.left.and.right"
            case .error: return "exclamationmark.triangle.fill"
            case .disconnected: return "OpenGlassesLogo"
            }
        } else {
            if appState.isListening { return "ear.fill" }
            if appState.speechService.isSpeaking { return "speaker.wave.3.fill" }
            return "OpenGlassesLogo"
        }
    }

    /// The hue the status tile is built from — the wash is this at the pill-fill
    /// opacity and the glyph is this corrected to read on that wash. Every value
    /// is a palette token so both halves are measurable.
    private var ringColor: Color {
        if !appState.isConnected { return OGTheme.inactive }
        if appState.glassesIdle { return OGTheme.inactive }

        if isGemini {
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return OGTheme.warn
            case .ready: return accent
            case .connecting, .settingUp: return OGTheme.warn
            case .error: return OGTheme.error
            case .disconnected: return OGTheme.inactive
            }
        } else if isOpenAI {
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return OGTheme.warn
            case .ready: return accent
            case .connecting, .settingUp: return OGTheme.warn
            case .error: return OGTheme.error
            case .disconnected: return OGTheme.inactive
            }
        } else {
            if appState.isListening { return accent }
            if appState.speechService.isSpeaking { return OGTheme.warn }
            return OGTheme.inactive
        }
    }

    private var statusLabel: String {
        if !appState.isConnected {
            let status = appState.glassesService.connectionStatus
            if status == "Not connected" { return "Glasses Not Connected" }
            return status
        }

        if appState.glassesIdle {
            return "Glasses Idle"
        }

        if isGemini {
            if !session.isActive { return "Ready" }
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return "Speaking..."
            case .ready: return "Listening..."
            case .connecting: return "Connecting..."
            case .settingUp: return "Setting Up..."
            case .error(let msg): return msg
            case .disconnected: return session.reconnecting ? "Reconnecting..." : "Disconnected"
            }
        } else if isOpenAI {
            if !openAISession.isActive { return "Ready" }
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return "Speaking..."
            case .ready: return "Listening..."
            case .connecting: return "Connecting..."
            case .settingUp: return "Setting Up..."
            case .error(let msg): return msg
            case .disconnected: return openAISession.reconnecting ? "Reconnecting..." : "Disconnected"
            }
        } else {
            if appState.isListening { return "Listening..." }
            if appState.speechService.isSpeaking { return "Speaking..." }
            return "Ready"
        }
    }

    private var modeLabel: String {
        if isGemini {
            return "Gemini Live"
        } else if isOpenAI {
            return "OpenAI Realtime"
        } else {
            return "Voice \u{00B7} \(appState.llmService.activeModelName)"
        }
    }

    /// The mode as a sentence rather than as displayed: the middot is a visual separator and
    /// VoiceOver reads it aloud as "middle dot", so it becomes the pause it was drawn to be.
    private var spokenModeLabel: String {
        modeLabel.replacingOccurrences(of: " \u{00B7} ", with: ", ")
    }

    /// Status, mode, and — only when it is actually on — the camera, as one spoken line. The
    /// trailing ellipses of "Listening…" are dropped: they mean "ongoing" to the eye and are
    /// read as a stumble.
    private var spokenStatus: String {
        let state = statusLabel
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "\u{2026}", with: "")
        var parts = [state, spokenModeLabel]
        if isRealtime && appState.cameraService.isStreaming {
            parts.append("camera streaming")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Helpers

    private var reconnectingLabel: some View {
        Text("Reconnecting...")
            .font(.caption)
            .foregroundStyle(OGTheme.warnLabel)
    }

    private func toolCallPill(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.7).tint(.primary)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(OGTheme.Opacity.accentFill))
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Running: \(text)")
    }

}

