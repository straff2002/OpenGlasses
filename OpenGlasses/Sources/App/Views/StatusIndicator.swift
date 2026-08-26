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

    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode == .openaiRealtime }
    private var isRealtime: Bool { appState.currentMode.isRealtime }

    var body: some View {
        VStack(spacing: 0) {
            // Status row
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(ringColor.opacity(0.12))
                        .frame(width: 48, height: 48)

                    Group {
                        if iconName == "OpenGlassesLogo" {
                            LogoIcon(size: 26)
                        } else {
                            Image(systemName: iconName)
                                .font(.system(size: 22, weight: .regular))
                        }
                    }
                    .foregroundStyle(ringColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(modeLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        if isRealtime && appState.cameraService.isStreaming {
                            HStack(spacing: 3) {
                                Circle().fill(.green).frame(width: 5, height: 5)
                                    .accessibilityHidden(true)
                                Text("CAM")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.green.opacity(0.8))
                            }
                            .accessibilityLabel("Camera streaming")
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 14)
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
            .padding(.bottom, 12)
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
        let color: Color = connected ? .green : .red.opacity(0.7)
        let label = connected ? (appState.glassesService.deviceName ?? "Glasses") : "Disconnected"

        return Button {
            if connected {
                showDisconnectConfirm = true
            } else {
                Task { await appState.glassesService.connect() }
            }
        } label: {
            HStack(spacing: 5) {
                LogoIcon(size: 13)
                    .foregroundStyle(color)
                if connected {
                    Circle().fill(color).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(in: .capsule)
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
        // The pill is drawn as a status dot, but it is a button that does opposite things in its
        // two states — which is exactly what a hint is for.
        .accessibilityLabel("Glasses: \(label)")
        .accessibilityHint(connected ? "Double-tap to disconnect the glasses."
                                     : "Double-tap to connect the glasses.")
    }

    private var openClawPill: some View {
        let (color, label): (Color, String) = {
            switch openClawBridge.connectionState {
            case .connected: return (.green, "Connected")
            case .checking: return (.orange, "Checking")
            case .unreachable: return (.red, "Unreachable")
            case .notConfigured: return (.gray, "Not Set Up")
            }
        }()

        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("OpenClaw")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
        .accessibilityLabel("OpenClaw: \(label)")
    }

    // MARK: - Active Mode Badge

    private var activeModeBadge: some View {
        let persona = appState.activePersona
        let name = persona?.name ?? "OpenGlasses"
        let icon = persona?.icon ?? "sparkles"
        let connected = appState.isConnected
        let badgeColor: Color = connected ? .green : .gray

        return HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Group {
                if icon == "OpenGlassesLogo" {
                    LogoIcon(size: 11)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(badgeColor)
            .accessibilityHidden(true)
            Text(connected ? "Active mode:" : "Mode:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(badgeColor)
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

    private var ringColor: Color {
        if !appState.isConnected { return .gray }
        if appState.glassesIdle { return .gray }

        if isGemini {
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return .orange
            case .ready: return accent
            case .connecting, .settingUp: return .orange
            case .error: return .red
            case .disconnected: return .gray
            }
        } else if isOpenAI {
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return .orange
            case .ready: return accent
            case .connecting, .settingUp: return .orange
            case .error: return .red
            case .disconnected: return .gray
            }
        } else {
            if appState.isListening { return accent }
            if appState.speechService.isSpeaking { return .orange }
            return .gray
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
            .font(.system(size: 12))
            .foregroundStyle(.orange.opacity(0.8))
    }

    private func toolCallPill(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.7).tint(.primary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(0.15))
        .glassEffect(in: .capsule)
        .accessibilityLabel("Running: \(text)")
    }

}

