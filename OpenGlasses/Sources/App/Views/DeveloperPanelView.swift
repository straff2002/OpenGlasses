import SwiftUI

/// Settings → Advanced & Support → Advanced → Developer (Plan CL P2): developer flags, recogniser
/// comparison, manual languages, turn latency and the live debug-event tail.
///
/// The subsystem self-test used to live here too. It is on the Advanced & Support page only
/// (`DiagnosticsSupportView`), which Simple Mode keeps visible: one self-test, not two.
struct DeveloperPanelView: View {
    @ObservedObject var appState: AppState
    /// Plan GD3 — `Config.fieldToolProfileEnabled`, the same key and default.
    @AppStorage("fieldToolProfileEnabled") private var fieldToolProfileEnabled = true
    /// Plan GU §5 — `Config.wakeSpeechGateEnabled`, the same key and default (off until tuned).
    @AppStorage("wakeSpeechGateEnabled") private var wakeSpeechGateEnabled = false
    /// Plan HZ P1 — `Config.directSentenceStreamingEnabled`, the same key and default (off until
    /// measured on device).
    @AppStorage("directSentenceStreamingEnabled") private var directSentenceStreamingEnabled = false
    /// Plan JM P0 — `Config.dictationVoiceProcessingEnabled`, the same key and default (off until
    /// measured on device).
    @AppStorage("dictationVoiceProcessingEnabled") private var dictationVoiceProcessingEnabled = false
    /// Plan JM P3 — `Config.recognizerComparisonEnabled`, the same key and default (off).
    @AppStorage("recognizerComparisonEnabled") private var recognizerComparisonEnabled = false
    /// Instant Replay P0 — `Config.frameCadenceLoggingEnabled`, the same key and default (off).
    @AppStorage("frameCadenceLoggingEnabled") private var frameCadenceLoggingEnabled = false

    init(appState: AppState) {
        self.appState = appState
    }

    var body: some View {
        OGScrollPage {
            #if DAT_MOCK_DISPLAY
            // Plan KV P4: only in a project generated with AVENKIN_DAT_MOCK_DISPLAY=1 (Simulator only).
            SimulatedDisplaySection(appState: appState)
            #endif

            OGSection(
                header: "Field Assist",
                footer: "During a Field Assist job, only field tools are offered to the model, which cuts cost per request. Turn off to offer every tool."
            ) {
                OGRow("Field-mode tool profile", isOn: $fieldToolProfileEnabled,
                      icon: "wrench.and.screwdriver")
            }

            OGSection(
                header: "Wake Word",
                footer: "Runs full speech recognition only while someone is talking, after a cheap loudness check. Saves battery; may miss a quiet wake phrase until tuned. Applies the next time listening starts."
            ) {
                OGRow("Speech gate", isOn: $wakeSpeechGateEnabled, icon: "waveform.badge.magnifyingglass")
                    .onChange(of: wakeSpeechGateEnabled) { _, _ in
                        appState.restartWakeWordIfDirect()
                    }
            }

            OGSection(
                header: "Reply Speech",
                footer: GlassesSupportPolicy.isSupported
                    ? "Starts speaking a reply at its first sentence while the rest is still being written, instead of waiting for the whole answer. The words are the same; only the timing changes. Off until it has been measured on the glasses."
                    : "Starts speaking a reply at its first sentence while the rest is still being written, instead of waiting for the whole answer. The words are the same; only the timing changes."
            ) {
                OGRow("Speak as it writes", isOn: $directSentenceStreamingEnabled,
                      icon: "text.bubble")
            }

            OGSection(
                header: "Dictation",
                footer: "An experiment: asks the iPhone's own mic for noise suppression while you dictate. Only on the iPhone mic, and only when dictation runs its own audio engine. It changes the input format and may add delay, so it stays off until it has been measured. Applies from the next turn."
            ) {
                OGRow("Voice processing on the phone mic (dictation)", isOn: $dictationVoiceProcessingEnabled,
                      icon: "waveform.and.mic")
            }

            // Plan JM P3: the rest of Dictation, as its own card so each footer sits under its switch.
            OGSection(
                footer: "Keeping the last question holds the audio of your most recent question in memory only, until your next question or until the app leaves the screen. Comparing sends that audio to any cloud recogniser you have configured."
            ) {
                OGRow("Keep the last question for recogniser comparison", isOn: $recognizerComparisonEnabled,
                      icon: "waveform.badge.magnifyingglass")
                OGDivider()
                NavigationLink {
                    RecognizerComparisonView(appState: appState)
                } label: {
                    OGRow(
                        "Compare recognisers", icon: "chart.bar.xaxis",
                        subtitle: "Every recogniser on the last question, scored by word error rate"
                    )
                }
                .buttonStyle(.plain)
            }
            .onChange(of: recognizerComparisonEnabled) { _, keep in
                // Off means forgotten now, not at the next question.
                if !keep { appState.transcriptionService.forgetKeptUtterance() }
            }

            OGSection(
                header: "Frame Cadence",
                footer: "Measures the first minute of each glasses stream: whether frames arrive evenly or in bursts, from their arrival times and the glasses' own timestamps. The reading goes to the camera log and shows here. Start a stream after turning this on."
            ) {
                OGRow("Measure frame cadence", isOn: $frameCadenceLoggingEnabled,
                      icon: "metronome")
                if let report = FrameCadenceRecorder.shared.lastReport {
                    OGDivider()
                    Text(verbatim: FrameCadenceSummary.line(report))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }

            // Plan JY P1: documents' languages and their search models — labels and counts only.
            OGSection(
                header: "Manual Languages",
                footer: "Each document's detected language and the model its passages are searched with."
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ManualLanguageReport.current(store: appState.documentStore), id: \.self) { line in
                        Text(verbatim: line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }

            // Plan KQ P0: the search-trained embedding model on this phone. Files copied in by hand.
            OGSection(header: "Search Model") {
                NavigationLink {
                    SearchModelCheckView()
                } label: {
                    OGRow(
                        "Search Model Check", icon: "gauge.with.dots.needle.67percent",
                        subtitle: "Speed, memory and vector parity on this phone"
                    )
                }
                .buttonStyle(.plain)
            }

            OGSection(header: "Turn Latency") {
                NavigationLink {
                    TurnTimelineDebugView(ledger: appState.turnLedger)
                } label: {
                    OGRow(
                        "Turn Timeline", icon: "waveform.path.ecg",
                        subtitle: "Recorded voice turns, stage breakdown, cohort latency"
                    )
                }
                .buttonStyle(.plain)
            }

            // Plan LM P1: what the shared background wake actually did — the device pass's evidence.
            BackgroundRefreshSection(ledger: BackgroundRefreshCoordinator.shared.ledger)
            NotificationButtonTestSection(log: NotificationButtonTestLog.shared)

            OGSection(
                header: "Debug Events",
                footer: "The persistent field log lives in Documents/debug-events.log and survives relaunches."
            ) {
                if appState.debugEvents.isEmpty {
                    Text("No events yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(appState.debugEvents.suffix(60).reversed(), id: \.self) { event in
                                Text(event)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 260)
                    OGDivider()
                    Button {
                        UIPasteboard.general.string = appState.debugEvents.joined(separator: "\n")
                    } label: {
                        OGRow("Copy Log", icon: "doc.on.doc", mutedIcon: true, showsChevron: false) {
                            OGRowValue(value: "\(appState.debugEvents.count) events")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Developer")
    }
}

/// Plan LM P4 — a test notification with the Done / Stop for today buttons, and what each press
/// recorded. Kill the app after posting it to test a press that has to launch the app.
private struct NotificationButtonTestSection: View {
    @ObservedObject var log: NotificationButtonTestLog
    @State private var status: String?

    var body: some View {
        OGSection(
            header: "Notification Buttons",
            footer: "Posts a notification with Done and Stop for today in 20 seconds. Kill the app first to test a cold launch: a press that arrives \"background\" a few seconds after launch woke the app for it."
        ) {
            VStack(alignment: .leading, spacing: 3) {
                if let status { Text(verbatim: status) }
                if log.presses.isEmpty {
                    Text(verbatim: "No presses recorded yet.")
                } else {
                    ForEach(Array(log.presses.reversed().enumerated()), id: \.offset) { _, press in
                        Text(verbatim: press.line())
                    }
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            OGDivider()
            Button {
                Task { @MainActor in
                    let posted = await NotificationButtonTest.post()
                    status = posted ? "Test notification in 20 s." : "Notifications are not allowed."
                }
            } label: {
                OGRow("Post a test notification with buttons", icon: "bell.badge", mutedIcon: true, showsChevron: false)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Plan LM P1 — the last background wakes and the last request made of iOS, with Run now (the same
/// pass in the foreground, the only way to exercise it on the Simulator).
private struct BackgroundRefreshSection: View {
    @ObservedObject var ledger: BackgroundRunLedger
    @State private var running = false

    var body: some View {
        OGSection(
            header: "Background Refresh",
            footer: "When iOS woke the app, how late against what was asked, and what each participant did. iOS decides when; this records what really happened."
        ) {
            VStack(alignment: .leading, spacing: 3) {
                if let request = ledger.lastRequest {
                    Text(verbatim: BackgroundRunSummary.line(request))
                }
                if ledger.records.isEmpty {
                    Text(verbatim: "No wakes recorded yet.")
                } else {
                    ForEach(Array(ledger.records.suffix(20).reversed().enumerated()), id: \.offset) { _, record in
                        Text(verbatim: BackgroundRunSummary.line(record))
                    }
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            OGDivider()
            Button {
                running = true
                Task { @MainActor in
                    await BackgroundRefreshCoordinator.shared.runNow()
                    running = false
                }
            } label: {
                OGRow("Run a background pass now", icon: "arrow.clockwise", mutedIcon: true, showsChevron: false)
            }
            .buttonStyle(.plain)
            .disabled(running)
        }
    }
}
