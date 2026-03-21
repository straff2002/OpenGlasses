import SwiftUI
import UIKit

/// Top-of-screen status pills showing glasses, Gemini, and OpenClaw connection state.
/// Each pill is tappable — expands to show details and actions.
struct ConnectionBanner: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject var openClawBridge: OpenClawBridge

    @State private var expandedPill: PillType? = nil
    @State private var cameraPermissionStatus: String?

    enum PillType { case glasses, gemini, openAI, openClaw }

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                glassesPill
                if appState.currentMode == .geminiLive {
                    geminiPill
                } else if appState.currentMode == .openaiRealtime {
                    openAIPill
                } else {
                    activeModelPill
                }
                if Config.isOpenClawConfigured {
                    openClawPill
                }
                Spacer()
            }

            // Expanded dropdown
            if let expanded = expandedPill {
                expandedCard(for: expanded)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: expandedPill)
    }

    // MARK: - Pills

    private var glassesPill: some View {
        let connected = appState.isConnected
        let color: Color
        let label: String

        if connected {
            color = .green
            label = appState.glassesService.deviceName ?? "Glasses"
        } else if appState.registrationStateRaw > 0 {
            color = registrationStateColor
            label = registrationStateLabel
        } else {
            color = .red.opacity(0.7)
            label = "Disconnected"
        }

        return iconPill(
            systemIcon: "eyeglasses",
            color: color,
            label: label,
            accessibilityDescription: "Glasses: \(label)",
            isExpanded: expandedPill == .glasses
        ) {
            withAnimation { expandedPill = expandedPill == .glasses ? nil : .glasses }
        }
    }

    private var geminiPill: some View {
        let (color, label): (Color, String) = {
            switch session.connectionState {
            case .ready: return (.green, "Gemini")
            case .connecting, .settingUp: return (.orange, "Connecting")
            case .error: return (.red, "Error")
            case .disconnected: return (.gray, "Gemini")
            }
        }()

        return iconPill(
            systemIcon: "sparkles",
            color: color,
            label: label,
            accessibilityDescription: "Gemini Live: \(label)",
            isExpanded: expandedPill == .gemini
        ) {
            withAnimation { expandedPill = expandedPill == .gemini ? nil : .gemini }
        }
    }

    private var openClawPill: some View {
        let (color, label): (Color, String) = {
            switch openClawBridge.connectionState {
            case .connected: return (.green, "OpenClaw")
            case .checking: return (.orange, "Checking")
            case .unreachable: return (.red, "Unreachable")
            case .notConfigured: return (.gray, "Not Set Up")
            }
        }()

        return iconPill(
            systemIcon: "hand.point.up.braille.fill",
            color: color,
            label: label,
            accessibilityDescription: "OpenClaw: \(label)",
            isExpanded: expandedPill == .openClaw
        ) {
            withAnimation { expandedPill = expandedPill == .openClaw ? nil : .openClaw }
        }
    }

    private var openAIPill: some View {
        let (color, label): (Color, String) = {
            switch openAISession.connectionState {
            case .ready: return (.green, "OpenAI")
            case .connecting, .settingUp: return (.orange, "Connecting")
            case .error: return (.red, "Error")
            case .disconnected: return (.gray, "OpenAI")
            }
        }()

        return iconPill(
            systemIcon: "bolt.fill",
            color: color,
            label: label,
            accessibilityDescription: "OpenAI Realtime: \(label)",
            isExpanded: expandedPill == .openAI
        ) {
            withAnimation { expandedPill = expandedPill == .openAI ? nil : .openAI }
        }
    }

    private var activeModelPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "brain")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.purple)
            Text(appState.llmService.activeModelName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .fixedSize()
        .pillBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Active model: \(appState.llmService.activeModelName)")
    }

    // MARK: - Reusable Pill

    private func iconPill(systemIcon: String, color: Color, label: String, accessibilityDescription: String, isExpanded: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemIcon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .rotationEffect(isExpanded ? .degrees(180) : .zero)
        }
        .fixedSize()
        .pillBackground(borderColor: isExpanded ? color.opacity(0.4) : Color.white.opacity(0.08))
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Tap to \(isExpanded ? "collapse" : "expand") details")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Expanded Card

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
        }
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
                            .foregroundStyle(.cyan)
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
                        .foregroundStyle(.cyan)
                }
            } else {
                if let battery = appState.glassesService.batteryLevel {
                    Text("Battery: \(battery)%")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }

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
                        cameraPermissionStatus == "error" ? .orange : .cyan
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
                        .foregroundStyle(.cyan)
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
                        .foregroundStyle(.cyan)
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
                        .foregroundStyle(.cyan)
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
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(color == .blue ? .white.opacity(0.6) : color.opacity(0.8))
        }
    }
}

// MARK: - Shared Modifiers

private extension View {
    /// Standard pill capsule background used by all connection status pills.
    func pillBackground(borderColor: Color = Color.white.opacity(0.08)) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.5))
    }

    /// Standard card background used by all expanded detail cards.
    func cardBackground() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}
