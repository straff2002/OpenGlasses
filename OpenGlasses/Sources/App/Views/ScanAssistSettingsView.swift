import SwiftUI

/// Scan Assist: configure directional reminders and run one session.
///
/// Free, like everything else on the accessibility screen — no entitlement, no paywall, and
/// nothing here belongs to Medical Compliance.
///
/// Two layout decisions are requirements rather than taste (docs/plans/FB-scan-assist.md P2):
/// Stop is centred and full-width with the word "Stop" in it, never an arrow or a colour alone,
/// and it is never placed on the side the wearer has said they have trouble noticing. The side
/// question is asked in words, answered explicitly, and described from the wearer's own
/// perspective every time it appears.
@MainActor
struct ScanAssistSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = ScanAssistSettingsStore.shared
    @ObservedObject private var session = ScanAssistService.shared

    /// The countdown, refreshed once a second and only while a session is live. No animation, so
    /// nothing here changes under Reduce Motion.
    @State private var remainingText: String?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            enableSection
            if store.settings.enabled {
                sideSection
                cueStyleSection
                timingSection
                previewSection
                sessionSection
            }
        }
        .navigationTitle("Scan Assist")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear { session.configure(speech: appState.speechService) }
        .onReceive(tick) { _ in refreshRemaining() }
        .onChange(of: session.state) { _, _ in refreshRemaining() }
        // The refusal and the ending are the two moments a wearer most needs told about, and both
        // can happen while their eyes are elsewhere.
        .onChange(of: session.statusMessage) { _, message in
            if let message { SessionAnnouncer.say(message) }
        }
    }

    // MARK: - Enable

    private var enableSection: some View {
        Section {
            Toggle("Enable Scan Assist", isOn: Binding(
                get: { store.settings.enabled },
                set: { session.setEnabled($0) }))
                .tint(AppAccent.color)
        } footer: {
            Text("Plays a reminder to check one side while you read or work at a table. It helps you practise checking a side you've chosen — it doesn't use the camera, doesn't know where you looked, and can't tell whether you checked. Free, and it never starts on its own.")
        }
    }

    // MARK: - Side

    private var sideSection: some View {
        Section {
            ForEach(ScanAssistSide.allCases) { side in
                Button {
                    session.chooseSide(side)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: ScanAssistCopy.sideLabel(side))
                                .foregroundStyle(Color.primary)
                            Text(verbatim: ScanAssistCopy.sideDescription(side))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        // The tick is confirmation for people who can see it; the selected trait
                        // below is the same fact for people who can't. Neither is the only copy.
                        if store.settings.side == side {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AppAccent.color)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(ScanAssistCopy.sideLabel(side)). \(ScanAssistCopy.sideDescription(side))"))
                .accessibilityAddTraits(store.settings.side == side ? [.isButton, .isSelected] : .isButton)
            }
        } header: {
            Text("Which side would you like reminders to check?")
        } footer: {
            Text("Your own left or right as you're wearing the glasses — not the page's, not the room's, not the side someone opposite you would call it. Nothing picks this for you, and you can change it whenever you like.")
        }
    }

    // MARK: - Cue style

    private var cueStyleSection: some View {
        Section {
            Picker("Reminder", selection: Binding(
                get: { store.settings.cueStyle },
                set: { session.setCueStyle($0) })) {
                    ForEach(ScanAssistCueStyle.allCases) { style in
                        Text(verbatim: ScanAssistCopy.cueStyleLabel(style)).tag(style)
                    }
                }
        } header: {
            Text("Reminder Style")
        } footer: {
            Text("A spoken direction says which side. A sound is quieter once you've learned what it means — it plays on whatever you're already listening through, and it doesn't come only from the chosen side.")
        }
    }

    // MARK: - Timing

    private var timingSection: some View {
        Section {
            Picker("How often", selection: Binding(
                get: { store.settings.interval },
                set: { session.setTiming(interval: $0, sessionDuration: store.settings.sessionDuration) })) {
                    ForEach(ScanAssistInterval.allCases) { interval in
                        Text(verbatim: ScanAssistCopy.intervalLabel(interval)).tag(interval)
                    }
                }
            Picker("Session length", selection: Binding(
                get: { store.settings.sessionDuration },
                set: { session.setTiming(interval: store.settings.interval, sessionDuration: $0) })) {
                    ForEach(ScanAssistSessionDuration.allCases) { duration in
                        Text(verbatim: ScanAssistCopy.sessionDurationLabel(duration)).tag(duration)
                    }
                }
        } header: {
            Text("Timing")
        } footer: {
            Text("Every session ends by itself after the length you choose. Changing either of these while a session is running restarts the timing from now — it never queues up the reminders you've missed.")
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section {
            Button {
                session.preview()
            } label: {
                Label("Play a Preview", systemImage: "speaker.wave.2")
            }
            .disabled(store.settings.side == nil)
        } footer: {
            Text("Plays one reminder now, without starting a session, so you can hear how it sounds where you actually are and through whatever you're listening with.")
        }
    }

    // MARK: - Session

    @ViewBuilder
    private var sessionSection: some View {
        Section {
            switch session.state {
            case .running, .paused:
                if let remainingText {
                    HStack {
                        Text("Time left")
                        Spacer()
                        Text(verbatim: remainingText).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: remainingText))
                }

                if session.state.isPaused {
                    Button {
                        session.resume()
                    } label: {
                        Label("Resume Reminders", systemImage: "play.fill")
                    }
                } else {
                    Button {
                        session.pause()
                    } label: {
                        Label("Pause Reminders", systemImage: "pause.fill")
                    }
                }

                stopButton
            case .idle, .ended:
                Button {
                    session.start()
                } label: {
                    Label("Start Reminders", systemImage: "play.fill")
                }
                .disabled(store.settings.side == nil)
            }

            if let message = session.statusMessage {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Session")
        } footer: {
            Text("Reminders run only while this session does. They stop if you stop them, when the session length runs out, and they never come back on their own when you reopen the app.")
        }
    }

    /// Centred, full-width, and the word "Stop" is in the label — the plan's requirement is that
    /// the one control a wearer needs in a hurry can't be something they have to find on the side
    /// they already told us they have trouble noticing, or recognise by colour alone.
    private var stopButton: some View {
        Button(role: .destructive) {
            session.stop()
        } label: {
            HStack {
                Spacer(minLength: 0)
                Label("Stop Reminders", systemImage: "stop.fill")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Stop reminders")
        .accessibilityHint("Ends this session now.")
    }

    private func refreshRemaining() {
        guard session.state.isLive, let seconds = session.remainingSeconds else {
            remainingText = nil
            return
        }
        remainingText = ScanAssistCopy.remaining(seconds: seconds)
    }
}
