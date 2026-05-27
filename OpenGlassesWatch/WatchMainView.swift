import SwiftUI

struct WatchMainView: View {
    @StateObject private var connectivity = WatchConnectivityService()
    @State private var errorMessage: String?
    @State private var feedbackTrigger: Int = 0
    @State private var errorFeedbackTrigger: Int = 0

    private var accentColor: Color {
        Self.color(for: connectivity.accentColorName)
    }

    // MARK: - Toggle Bindings

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { connectivity.isListening },
            set: { _ in
                errorMessage = nil
                connectivity.sendCommand("toggleListen") { error in
                    if let error {
                        errorMessage = error
                        errorFeedbackTrigger += 1
                    } else {
                        feedbackTrigger += 1
                    }
                }
            }
        )
    }

    private var recordingBinding: Binding<Bool> {
        Binding(
            get: { connectivity.isRecording },
            set: { _ in
                errorMessage = nil
                connectivity.sendCommand("toggleRecord") { error in
                    if let error {
                        errorMessage = error
                        errorFeedbackTrigger += 1
                    } else {
                        feedbackTrigger += 1
                    }
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Status bar
                    statusBar

                    // Listen toggle
                    listenRow

                    // Record toggle
                    recordRow

                    Divider()

                    // Quick Actions (top 4 from iOS app)
                    if !connectivity.quickActions.isEmpty {
                        quickActionsSection
                        Divider()
                    }

                    // Persona agents
                    if !connectivity.personas.isEmpty {
                        personasSection
                        Divider()
                    }

                    // Connect / Sleep — compact
                    if connectivity.isConnected {
                        compactActionButton(label: "Sleep", icon: "moon.fill", command: "sleep")
                    } else {
                        compactActionButton(label: "Connect", icon: "OpenGlassesLogo", command: "connect")
                    }

                    // Recent conversations
                    if !connectivity.recentThreads.isEmpty {
                        Divider()
                        conversationsSection
                    }

                    // Response
                    if !connectivity.lastResponse.isEmpty {
                        responseSection
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ogLogo
                }
            }
        }
        .sensoryFeedback(.success, trigger: feedbackTrigger)
        .sensoryFeedback(.error, trigger: errorFeedbackTrigger)
    }

    // MARK: - OG Logo

    private var ogLogo: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text("O")
                .font(.system(size: 28, weight: .bold))
            Text("pen")
                .font(.system(size: 11, weight: .semibold))
                .offset(y: -6)
            Text("G")
                .font(.system(size: 28, weight: .bold))
            Text("lasses")
                .font(.system(size: 11, weight: .semibold))
                .offset(y: -6)
        }
        .foregroundStyle(accentColor)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectivity.isReachable ? .green : .red)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(connectivity.isReachable
                 ? (connectivity.isConnected ? "Glasses Connected" : "iPhone Connected")
                 : "Not Reachable")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let battery = connectivity.batteryLevel, battery > 0 {
                Text("\(battery)%")
                    .font(.caption2)
                    .foregroundStyle(battery < 20 ? .red : .secondary)
                    .accessibilityLabel("Battery \(battery) percent")
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Listen Toggle Row

    private var listenRow: some View {
        Toggle(isOn: listeningBinding) {
            Label {
                HStack {
                    Text(connectivity.isListening ? "Listening" : "Listen")
                        .font(.body)
                    if connectivity.isProcessing {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            } icon: {
                Image(systemName: connectivity.isListening ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(connectivity.isListening ? accentColor : .secondary)
            }
        }
        .disabled(!connectivity.isReachable)
        .tint(accentColor)
    }

    // MARK: - Record Toggle Row

    private var recordRow: some View {
        Toggle(isOn: recordingBinding) {
            Label {
                Text(connectivity.isRecording ? "Recording" : "Transcribe")
                    .font(.body)
            } icon: {
                Image(systemName: connectivity.isRecording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(connectivity.isRecording ? .red : .secondary)
            }
        }
        .disabled(!connectivity.isReachable)
        .tint(.red)
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(spacing: 8) {
            Text("Quick Actions")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(connectivity.quickActions) { action in
                Button {
                    errorMessage = nil
                    connectivity.sendCommand("quickAction", extra: ["action_id": action.id]) { error in
                        if let error {
                            errorMessage = error
                            errorFeedbackTrigger += 1
                        } else {
                            feedbackTrigger += 1
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: action.icon)
                            .font(.body)
                            .foregroundStyle(accentColor)
                        Text(action.label)
                            .font(.body)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .disabled(!connectivity.isReachable || connectivity.isProcessing)
            }
        }
    }

    // MARK: - Personas

    private var personasSection: some View {
        VStack(spacing: 8) {
            Text("Personas")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(connectivity.personas) { persona in
                Button {
                    errorMessage = nil
                    connectivity.sendCommand("persona", extra: ["persona_id": persona.id]) { error in
                        if let error {
                            errorMessage = error
                            errorFeedbackTrigger += 1
                        } else {
                            feedbackTrigger += 1
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.fill")
                            .font(.body)
                            .foregroundStyle(accentColor)
                        Text(persona.name)
                            .font(.body)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .disabled(!connectivity.isReachable || connectivity.isProcessing)
            }
        }
    }

    // MARK: - Conversations

    private var conversationsSection: some View {
        VStack(spacing: 8) {
            Text("Recent")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(connectivity.recentThreads) { thread in
                Button {
                    errorMessage = nil
                    connectivity.sendCommand("resumeThread", extra: ["thread_id": thread.id]) { error in
                        if let error {
                            errorMessage = error
                            errorFeedbackTrigger += 1
                        } else {
                            feedbackTrigger += 1
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(thread.title)
                            .font(.caption)
                            .lineLimit(1)
                        if !thread.summary.isEmpty {
                            Text(thread.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .disabled(!connectivity.isReachable || connectivity.isProcessing)
            }
        }
    }

    // MARK: - Response

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Response")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(connectivity.lastResponse)
                .font(.caption)
                .lineLimit(6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - Compact Action Button

    @ViewBuilder
    private func compactActionButton(label: String, icon: String, command: String) -> some View {
        Button {
            errorMessage = nil
            connectivity.sendCommand(command) { error in
                if let error {
                    errorMessage = error
                    errorFeedbackTrigger += 1
                } else {
                    feedbackTrigger += 1
                }
            }
        } label: {
            Label {
                Text(label)
            } icon: {
                if icon == "OpenGlassesLogo" {
                    LogoIcon(size: 14)
                } else {
                    Image(systemName: icon)
                }
            }
            .font(.footnote)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(accentColor)
        .disabled(!connectivity.isReachable || connectivity.isProcessing)
    }

    // MARK: - Accent Color

    /// Mirrors AppAccent presets from the iOS app.
    private static func color(for name: String) -> Color {
        switch name {
        case "green":   return Color(red: 0.3, green: 0.75, blue: 0.4)
        case "violet":  return AccentColors.aiCoral
        case "blue":    return Color(red: 0.25, green: 0.5, blue: 1.0)
        case "teal":    return Color(red: 0.2, green: 0.7, blue: 0.7)
        case "orange":  return Color(red: 1.0, green: 0.6, blue: 0.2)
        case "pink":    return Color(red: 0.95, green: 0.35, blue: 0.55)
        case "red":     return Color(red: 0.9, green: 0.25, blue: 0.3)
        case "white":   return .white
        default:        return Color(red: 0.3, green: 0.75, blue: 0.4)
        }
    }
}
