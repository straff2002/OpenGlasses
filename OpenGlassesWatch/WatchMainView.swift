import SwiftUI

struct WatchMainView: View {
    @ObservedObject var connectivity: WatchConnectivityService
    @State private var errorMessage: String?
    @State private var feedbackTrigger: Int = 0
    @State private var errorFeedbackTrigger: Int = 0
    /// A dictated question is with the phone and has not been answered yet.
    @State private var isAsking = false
    /// Counts dictated answers as they arrive, so the list can bring each one into view.
    @State private var answerArrivals: Int = 0

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

    private var videoBinding: Binding<Bool> {
        Binding(
            get: { connectivity.isVideoRecording },
            set: { _ in
                errorMessage = nil
                connectivity.sendCommand("toggleVideo") { error in
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        // Status bar
                        statusBar

                        // A map card from the phone (Plan GM): "how far is that tower?", "where
                        // am I?", "find a pharmacy". Directly under the status, because a spatial
                        // answer is what the wearer raised the wrist for.
                        WatchNowShowingRow(connectivity: connectivity, accent: accentColor)

                        // The job in hand (Plan FO P3a). Read-only, and directly under the status,
                        // because on a service visit it is the thing being glanced at.
                        if let job = connectivity.job {
                            jobSection(job)
                            Divider()
                        }

                        // Listen toggle
                        listenRow

                        // Ask by speaking to the watch itself
                        dictateRow

                        // Record toggle (transcription)
                        recordRow

                        // Take a photo on the glasses
                        photoRow

                        // Record video on the glasses
                        videoRow

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
                            compactActionButton(label: "Connect", icon: "AvenkinMark", command: "connect")
                        }

                        // Recent conversations
                        if !connectivity.recentThreads.isEmpty {
                            Divider()
                            conversationsSection
                        }

                        // Response
                        if !connectivity.lastResponse.isEmpty {
                            responseSection
                                .id(Self.responseAnchor)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
                .onChange(of: answerArrivals) {
                    withAnimation { proxy.scrollTo(Self.responseAnchor, anchor: .top) }
                }
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
        // One tap for a map the wearer asked to see on the watch; automatic cards arrive silently.
        .sensoryFeedback(.impact, trigger: connectivity.surfaceTaps)
        // A tap on a complication lands here: it can only open the app, so the app does the work.
        .onOpenURL { url in
            guard let command = WatchComplicationLink.command(from: url) else { return }
            errorMessage = nil
            connectivity.runComplicationCommand(command) { error in
                if let error {
                    errorMessage = error
                    errorFeedbackTrigger += 1
                } else {
                    feedbackTrigger += 1
                }
            }
        }
    }

    // MARK: - Wordmark

    /// The Avenkin wordmark, drawn the way the old one was: a large capital with the rest of the
    /// name set small and raised beside it. Built from pieces, so it says its name to VoiceOver.
    private var ogLogo: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(verbatim: "A")
                .font(.system(size: 28, weight: .bold))
            Text(verbatim: "venkin")
                .font(.system(size: 11, weight: .semibold))
                .offset(y: -6)
        }
        .foregroundStyle(accentColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Avenkin")
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

    // MARK: - Dictate Row

    /// Ask with the watch's own microphone. Listen opens a microphone the phone can reach — the
    /// glasses, earbuds, or the phone itself; this one needs none of them. The system's dictation
    /// turns what is said into text here on the wrist, and the text is what goes to the phone.
    private var dictateRow: some View {
        TextFieldLink(prompt: Text("Ask Avenkin")) {
            Label {
                HStack {
                    Text("Dictate")
                        .font(.body)
                    if isAsking {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Spacer(minLength: 0)
                }
            } icon: {
                Image(systemName: "waveform")
                    .foregroundStyle(accentColor)
            }
        } onSubmit: { question in
            errorMessage = nil
            isAsking = true
            connectivity.sendCommand(WatchDictationWire.command,
                                     extra: [WatchDictationWire.textKey: question]) { error in
                isAsking = false
                if let error {
                    errorMessage = error
                    errorFeedbackTrigger += 1
                } else {
                    feedbackTrigger += 1
                    // The answer is the point, and it is drawn at the foot of the list.
                    answerArrivals += 1
                }
            }
        }
        .disabled(!connectivity.isReachable || connectivity.isProcessing)
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

    // MARK: - Glasses Photo

    private var photoRow: some View {
        Button {
            errorMessage = nil
            connectivity.sendCommand("capturePhoto") { error in
                if let error {
                    errorMessage = error
                    errorFeedbackTrigger += 1
                } else {
                    feedbackTrigger += 1
                }
            }
        } label: {
            Label {
                Text("Photo")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: "camera.fill")
                    .foregroundStyle(accentColor)
            }
        }
        .disabled(!connectivity.isReachable || !connectivity.isConnected || connectivity.isProcessing)
    }

    // MARK: - Glasses Video Toggle

    private var videoRow: some View {
        Toggle(isOn: videoBinding) {
            Label {
                Text(connectivity.isVideoRecording ? "Recording Video" : "Video")
                    .font(.body)
            } icon: {
                Image(systemName: connectivity.isVideoRecording ? "video.fill" : "video")
                    .foregroundStyle(connectivity.isVideoRecording ? .red : .secondary)
            }
        }
        .disabled(!connectivity.isReachable || !connectivity.isConnected)
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

    // MARK: - Job (Plan FO P3a)

    /// What the wrist says about the open job. No buttons: every decision a job needs — the number,
    /// the unit question, closing it — is put where it can actually be answered.
    private func jobSection(_ job: WatchConnectivityService.JobInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(job.jobNumber)
                    .font(.caption)
                    .bold()
                Spacer()
                Text(job.state)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !job.unit.isEmpty {
                Text(job.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !job.nextAction.isEmpty {
                Text(job.nextAction)
                    .font(.caption2)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

    private static let responseAnchor = "response"

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Response")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // In full: for a question dictated with nothing else on, this is the whole answer.
            Text(connectivity.lastResponse)
                .font(.caption)
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
                if icon == "AvenkinMark" {
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
