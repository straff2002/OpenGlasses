import SwiftUI
import UIKit

/// Top-of-screen status bar.
///
/// Layout:
///   Row 1:  [Glasses status]  ·  [Q quick-actions]  ·  [OpenClaw status]
///   Row 2:  Full-width model/session bar
///
/// Icons are tappable — expand to show details and actions.
struct ConnectionBanner: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject var openClawBridge: OpenClawBridge
    @Environment(\.appAccent) private var accent

    @State private var expandedPill: PillType? = nil
    @State private var cameraPermissionStatus: String?
    enum PillType { case glasses, gemini, openAI, openClaw, model }

    private var registrationStateLabel: String {
        switch appState.registrationStateRaw {
        case 3: return "Registered"
        case 2: return "Registering"
        case 1: return "Pending Auth"
        default: return "Disconnected"
        }
    }

    private var registrationStateColor: Color {
        switch appState.registrationStateRaw {
        case 3: return .green
        case 2: return .orange
        case 1: return .yellow
        default: return .red.opacity(0.8)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            // Row 1: [Glasses] · [OpenClaw/Session]
            HStack {
                glassesIcon
                Spacer()
                trailingIcon
            }
            .padding(.horizontal, 20)

            // Row 2: Full-width model/session bar
            modelBar

            // Expanded dropdown
            if let expanded = expandedPill {
                expandedCard(for: expanded)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: expandedPill)
    }

    // MARK: - Row 1: Status Icons

    private var glassesIcon: some View {
        let connected = appState.isConnected
        let color: Color = connected ? .green :
            (appState.registrationStateRaw > 0 ? registrationStateColor : .red.opacity(0.7))
        let label = connected ? (appState.glassesService.deviceName ?? "Glasses") : registrationStateLabel

        return Button {
            withAnimation { expandedPill = expandedPill == .glasses ? nil : .glasses }
        } label: {
            HStack(spacing: 6) {
                LogoIcon(size: 16)
                    .foregroundStyle(color)
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
        }
        .accessibilityLabel("Glasses: \(label)")
    }

    @ViewBuilder
    private var trailingIcon: some View {
        if Config.isOpenClawConfigured {
            openClawIcon
        } else if appState.currentMode == .geminiLive {
            geminiIcon
        } else if appState.currentMode == .openaiRealtime {
            openAIIcon
        } else {
            Color.clear.frame(width: 50, height: 40)
        }
    }

    private var openClawIcon: some View {
        let (color, label): (Color, String) = {
            switch openClawBridge.connectionState {
            case .connected: return (.green, "Connected")
            case .checking: return (.orange, "Checking")
            case .unreachable: return (.red, "Unreachable")
            case .notConfigured: return (.gray, "Not Set Up")
            }
        }()

        return Button {
            withAnimation { expandedPill = expandedPill == .openClaw ? nil : .openClaw }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Image(systemName: "hand.point.up.braille.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
        }
        .accessibilityLabel("OpenClaw: \(label)")
    }

    private var geminiIcon: some View {
        let (color, label): (Color, String) = {
            switch session.connectionState {
            case .ready: return (.green, "Connected")
            case .connecting, .settingUp: return (.orange, "Connecting")
            case .error: return (.red, "Error")
            case .disconnected: return (.gray, "Disconnected")
            }
        }()

        return Button {
            withAnimation { expandedPill = expandedPill == .gemini ? nil : .gemini }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
        }
        .accessibilityLabel("Gemini: \(label)")
    }

    private var openAIIcon: some View {
        let (color, label): (Color, String) = {
            switch openAISession.connectionState {
            case .ready: return (.green, "Connected")
            case .connecting, .settingUp: return (.orange, "Connecting")
            case .error: return (.red, "Error")
            case .disconnected: return (.gray, "Disconnected")
            }
        }()

        return Button {
            withAnimation { expandedPill = expandedPill == .openAI ? nil : .openAI }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
        }
        .accessibilityLabel("OpenAI: \(label)")
    }

    // MARK: - Row 2: Model Bar

    private var modelBar: some View {
        let modelName: String
        let icon: String
        let color: Color

        if appState.currentMode == .geminiLive {
            modelName = "Gemini Live"
            icon = "sparkles"
            color = session.isActive ? .green : .gray
        } else if appState.currentMode == .openaiRealtime {
            modelName = "OpenAI Realtime"
            icon = "bolt.horizontal.fill"
            color = openAISession.isActive ? .green : .gray
        } else {
            modelName = appState.llmService.activeModelName
            icon = "brain"
            color = AppAccent.aiCoral
        }

        return Button {
            withAnimation { expandedPill = expandedPill == .model ? nil : .model }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)

                Text(modelName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)

                Spacer()

                // Active persona badge
                if let persona = appState.activePersona {
                    HStack(spacing: 4) {
                        Image(systemName: persona.icon ?? "person.circle")
                            .font(.system(size: 10))
                        Text(persona.name)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(accent.opacity(0.8))
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(expandedPill == .model ? .degrees(180) : .zero)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
        }
        .padding(.horizontal, 16)
        .accessibilityLabel("Model: \(modelName)")
    }

    // MARK: - Expanded Cards

    @ViewBuilder
    private func expandedCard(for type: PillType) -> some View {
        switch type {
        case .glasses:
            glassesCard
        case .gemini:
            geminiCard
        case .openAI:
            openAICard
        case .openClaw:
            openClawCard
        case .model:
            modelCard
        }
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.currentMode == .geminiLive {
                Text("Gemini Live — bidirectional voice streaming")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            } else if appState.currentMode == .openaiRealtime {
                Text("OpenAI Realtime — bidirectional voice streaming")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Text("Direct mode — \(appState.llmService.activeModelName)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))

                if appState.llmService.toolCallStatus.isActive {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).tint(.white)
                        Text(appState.llmService.toolCallStatus.displayText)
                            .font(.system(size: 11))
                            .foregroundStyle(AppAccent.aiCoral.opacity(0.8))
                    }
                }
            }

            Text("Tap the Model button below to switch models")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .cardBackground()
    }

    private var glassesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.glassesService.connectionStatus)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 8) {
                Circle()
                    .fill(registrationStateColor)
                    .frame(width: 7, height: 7)
                Text("Registration: \(appState.registrationStateRaw) — \(registrationStateLabel)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            }

            if appState.registrationStateRaw < 3 {
                Button {
                    Task { await appState.completeAuthorizationInMetaAI() }
                    withAnimation { expandedPill = nil }
                } label: {
                    Text("Complete in Meta AI")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Debug")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))

                Text("Callback source: \(appState.lastCallbackSource)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))

                Text("Callback URL: \(appState.lastCallbackURL)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)

                if let callbackAt = appState.lastCallbackAt {
                    Text("Last callback at: \(callbackAt.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(appState.debugEvents.suffix(20).enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.72))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .scrollIndicators(.visible)
                .padding(8)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 12) {
                    Button {
                        let payload = appState.debugEvents.joined(separator: "\n")
                        UIPasteboard.general.string = payload
                    } label: {
                        Text("Copy Debug Log")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                    }

                    Button {
                        appState.debugEvents.removeAll()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                    }

                    Button {
                        Task { await appState.resetMetaRegistration() }
                    } label: {
                        Text("Reset Reg")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.yellow)
                    }
                }
            }

            if !appState.isConnected {
                Button {
                    Task { await appState.glassesService.connect() }
                    withAnimation { expandedPill = nil }
                } label: {
                    Text("Connect Glasses")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
            } else {
                Button {
                    cameraPermissionStatus = "checking"
                    appState.cameraService.onRegistrationProgress = { state in
                        Task { @MainActor in
                            if state < 2 {
                                cameraPermissionStatus = "SDK \(state)…"
                            }
                        }
                    }
                    Task {
                        defer { appState.cameraService.onRegistrationProgress = nil }
                        do {
                            try await appState.cameraService.ensurePermission()
                            cameraPermissionStatus = "granted"
                        } catch {
                            cameraPermissionStatus = "error"
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let status = cameraPermissionStatus {
                            switch status {
                            case "granted":
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                Text("Camera Ready")
                                    .font(.system(size: 13, weight: .semibold))
                            case "error":
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                Text("Retry")
                                    .font(.system(size: 13, weight: .semibold))
                            default:
                                ProgressView().scaleEffect(0.7).tint(.white)
                                Text("Checking…")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 11))
                            Text("Camera Permission")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .foregroundStyle(
                        cameraPermissionStatus == "granted" ? .green :
                        cameraPermissionStatus == "error" ? .orange : accent
                    )
                }
                .disabled(cameraPermissionStatus != nil && cameraPermissionStatus != "granted" && cameraPermissionStatus != "error")
            }
        }
        .cardBackground()
    }

    private var geminiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.isActive {
                statusDot(color: .green, text: "Session active")

                if appState.cameraService.isStreaming {
                    statusDot(color: .blue, text: "Camera streaming")
                }

                if session.isModelSpeaking {
                    statusDot(color: .orange, text: "Speaking…")
                }

                Button {
                    session.stopSession()
                    withAnimation { expandedPill = nil }
                } label: {
                    Text("Stop Session")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.8))
                }
            } else {
                switch session.connectionState {
                case .error(let msg):
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(3)
                default:
                    Text("No active session")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button {
                    Task { await session.startSession() }
                    withAnimation { expandedPill = nil }
                } label: {
                    Text("Start Session")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }

            if let error = session.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(3)
            }
        }
        .cardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gemini Live details")
    }

    private var openAICard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if openAISession.isActive {
                statusDot(color: .green, text: "Session active")

                if appState.cameraService.isStreaming {
                    statusDot(color: .blue, text: "Camera streaming")
                }

                if openAISession.isModelSpeaking {
                    statusDot(color: .orange, text: "Speaking…")
                }

                Button {
                    openAISession.stopSession()
                    withAnimation { expandedPill = nil }
                } label: {
                    Text("Stop Session")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.8))
                }
            } else {
                switch openAISession.connectionState {
                case .error(let msg):
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(3)
                default:
                    Text("No active session")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button {
                    Task { await openAISession.startSession() }
                    withAnimation { expandedPill = nil }
                } label: {
                    Text("Start Session")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }

            if let error = openAISession.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(3)
            }
        }
        .cardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenAI Realtime details")
    }

    private var openClawCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenClaw Gateway")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))

            switch openClawBridge.connectionState {
            case .connected:
                HStack(spacing: 6) {
                    Text("Connected")
                        .font(.system(size: 12))
                        .foregroundStyle(.green.opacity(0.8))
                    if let via = openClawBridge.resolvedConnection {
                        Text("via \(via.label)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            case .unreachable(let reason):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server unreachable")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.8))
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }

                Button {
                    Task { await openClawBridge.checkConnection() }
                } label: {
                    Text("Try Again")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7).tint(.white)
                    Text("Checking connection…")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange.opacity(0.8))
                }
            case .notConfigured:
                Text("Set up OpenClaw in Settings to enable Mac-powered tools.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .cardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenClaw Gateway details")
    }

    // MARK: - Shared Components

    private func statusDot(color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(color == .blue ? .white.opacity(0.6) : color.opacity(0.8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Shared Modifiers

private extension View {
    /// Standard pill capsule background used by all connection status pills.
    func pillBackground(borderColor: Color = Color.white.opacity(0.08)) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
    }

    /// Standard card background used by all expanded detail cards.
    func cardBackground() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: 12))
    }
}
