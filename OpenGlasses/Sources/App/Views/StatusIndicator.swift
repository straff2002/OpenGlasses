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
    @Environment(\.appAccent) private var accent

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
                        .font(.system(size: 17, weight: .medium))
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

            // Active mode indicator
            activeModeBadge
                .padding(.bottom, 12)
        }
        .glassEffect(in: .rect(cornerRadius: 16))
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusLabel). \(modeLabel). \(appState.isConnected ? "Connected" : "Disconnected")")
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
        .accessibilityLabel("\(connected ? "Active" : "") mode: \(name)")
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

// MARK: - Quick Actions Grid (standalone)

/// Horizontal grid of quick action buttons, shown above the hero capsule.
struct QuickActionsGrid: View {
    @EnvironmentObject var appState: AppState
    @State private var executingActionId: String?

    private var allActions: [QuickAction] { Config.quickActions }

    /// Show top 4 or all, based on user preference.
    private var actions: [QuickAction] {
        let all = allActions
        if Config.showAllQuickActions {
            return all
        }
        return Array(all.prefix(4))
    }

    private var isExecutingAction: Bool { executingActionId != nil }

    private var visible: Bool {
        guard appState.isConnected && appState.currentMode == .direct && !actions.isEmpty else { return false }
        // Stay visible while an action is executing (shows spinner)
        if isExecutingAction { return true }
        // Otherwise hide when busy
        return !appState.isProcessing
            && !appState.isListening
            && !appState.speechService.isSpeaking
            && !appState.cameraService.isCaptureInProgress
    }

    var body: some View {
        if appState.isConnected && appState.currentMode == .direct && !allActions.isEmpty {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(actions) { action in
                    quickActionButton(action)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(.easeInOut(duration: 0.2), value: visible)
        }
    }

    private func quickActionButton(_ action: QuickAction) -> some View {
        let isExecuting = executingActionId == action.id

        return Button {
            guard !isExecuting else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            executingActionId = action.id
            Task {
                await appState.executeQuickAction(action)
                executingActionId = nil
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if isExecuting {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: action.icon)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color(.label))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .glassEffect(in: .rect(cornerRadius: 12))

                Text(action.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .accessibilityLabel(action.label)
        .accessibilityHint(isExecuting ? "Running" : "Double-tap to execute")
    }
}
