import SwiftUI

/// Large central ambient status indicator — the visual heartbeat of the app.
/// Adapts to Direct, Gemini Live, and OpenAI Realtime modes.
/// When glasses aren't connected, acts as a connect button.
struct StatusIndicator: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

    /// Outer ring pulse
    @State private var ringScale: CGFloat = 1.0
    @State private var ringOpacity: Double = 0.3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode == .openaiRealtime }
    private var isRealtime: Bool { appState.currentMode.isRealtime }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                // Ambient ring — pulses when active
                Circle()
                    .stroke(ringColor.opacity(ringOpacity), lineWidth: 2)
                    .frame(width: 160, height: 160)
                    .scaleEffect(ringScale)

                // Inner glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [ringColor.opacity(0.15), Color.clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 80
                        )
                    )
                    .frame(width: 140, height: 140)

                // Icon
                Image(systemName: iconName)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(ringColor)
                    .symbolEffect(.pulse, isActive: isPulsing)

                // Camera streaming badge (realtime modes)
                if isRealtime && appState.cameraService.isStreaming {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .offset(x: 50, y: -50)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: iconName)
            .onAppear { startRingAnimation() }
            .onChange(of: isPulsing) { _, active in
                if active { startRingAnimation() } else { stopRingAnimation() }
            }
            // Tap to connect when glasses aren't connected
            .onTapGesture {
                if !appState.isConnected {
                    Task { await appState.glassesService.connect() }
                }
            }

            // Status text
            VStack(spacing: 4) {
                Text(statusLabel)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(modeLabel)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                // Connection hint when not connected
                if !appState.isConnected {
                    Text("Tap to connect your glasses")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.cyan.opacity(0.7))
                        .padding(.top, 4)
                }
            }

            // Tool call status
            if isGemini && session.toolCallStatus.isActive {
                toolCallPill(session.toolCallStatus.displayText, color: .purple)
            } else if !isRealtime && appState.llmService.toolCallStatus.isActive {
                toolCallPill(appState.llmService.toolCallStatus.displayText, color: .purple)
            }

            // Reconnecting
            if isGemini && session.reconnecting {
                Text("Reconnecting…")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange.opacity(0.8))
            }
            if isOpenAI && openAISession.reconnecting {
                Text("Reconnecting…")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange.opacity(0.8))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusLabel). \(modeLabel)")
        .accessibilityHint(appState.isConnected ? "" : "Double-tap to connect your glasses")
    }

    // MARK: - Computed Properties

    private var iconName: String {
        if !appState.isConnected {
            return "eyeglasses"
        }

        if isGemini {
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return "speaker.wave.3.fill"
            case .ready: return "waveform.circle.fill"
            case .connecting, .settingUp: return "antenna.radiowaves.left.and.right"
            case .error: return "exclamationmark.triangle.fill"
            case .disconnected: return "waveform.circle"
            }
        } else if isOpenAI {
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return "speaker.wave.3.fill"
            case .ready: return "waveform.circle.fill"
            case .connecting, .settingUp: return "antenna.radiowaves.left.and.right"
            case .error: return "exclamationmark.triangle.fill"
            case .disconnected: return "waveform.circle"
            }
        } else {
            if appState.isListening { return "waveform.circle.fill" }
            if appState.speechService.isSpeaking { return "speaker.wave.3.fill" }
            return "mic.circle"
        }
    }

    private var ringColor: Color {
        if !appState.isConnected { return .gray }

        if isGemini {
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return .orange
            case .ready: return .cyan
            case .connecting, .settingUp: return .orange
            case .error: return .red
            case .disconnected: return .gray
            }
        } else if isOpenAI {
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return .orange
            case .ready: return .cyan
            case .connecting, .settingUp: return .orange
            case .error: return .red
            case .disconnected: return .gray
            }
        } else {
            if appState.isListening { return .cyan }
            if appState.speechService.isSpeaking { return .orange }
            return .gray
        }
    }

    private var isPulsing: Bool {
        if !appState.isConnected { return false }

        if isGemini {
            return session.isActive && session.connectionState == .ready
        } else if isOpenAI {
            return openAISession.isActive && openAISession.connectionState == .ready
        } else {
            return appState.isListening
        }
    }

    private var statusLabel: String {
        if !appState.isConnected {
            let status = appState.glassesService.connectionStatus
            if status == "Not connected" { return "Glasses Not Connected" }
            return status
        }

        if isGemini {
            if !session.isActive { return "Ready" }
            switch session.connectionState {
            case .ready where session.isModelSpeaking: return "Speaking…"
            case .ready: return "Listening…"
            case .connecting: return "Connecting…"
            case .settingUp: return "Setting Up…"
            case .error(let msg): return msg
            case .disconnected: return session.reconnecting ? "Reconnecting…" : "Disconnected"
            }
        } else if isOpenAI {
            if !openAISession.isActive { return "Ready" }
            switch openAISession.connectionState {
            case .ready where openAISession.isModelSpeaking: return "Speaking…"
            case .ready: return "Listening…"
            case .connecting: return "Connecting…"
            case .settingUp: return "Setting Up…"
            case .error(let msg): return msg
            case .disconnected: return openAISession.reconnecting ? "Reconnecting…" : "Disconnected"
            }
        } else {
            if appState.isListening { return "Listening…" }
            if appState.speechService.isSpeaking { return "Speaking…" }
            return "Ready"
        }
    }

    private var modeLabel: String {
        if isGemini {
            return "Gemini Live"
        } else if isOpenAI {
            return "OpenAI Realtime"
        } else {
            return "Voice · \(appState.llmService.activeModelName)"
        }
    }

    // MARK: - Helpers

    private func toolCallPill(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.7).tint(.white)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(0.3), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
    }

    private func startRingAnimation() {
        guard !reduceMotion else {
            ringScale = 1.0
            ringOpacity = 0.6
            return
        }
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            ringScale = 1.12
            ringOpacity = 0.6
        }
    }

    private func stopRingAnimation() {
        withAnimation(.easeOut(duration: reduceMotion ? 0.01 : 0.5)) {
            ringScale = 1.0
            ringOpacity = 0.3
        }
    }
}
