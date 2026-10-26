import SwiftUI

/// Settings → Advanced → Developer (Plan CL P2): one-tap cold-start
/// verification that each subsystem is alive — glasses link, camera,
/// HUD, AI round-trip, TTS, wake word — plus the live debug-event tail.
/// Field debugging starts here instead of "say the wake word and guess".
struct DeveloperPanelView: View {
    @ObservedObject var appState: AppState
    @StateObject private var runner: SubsystemTestRunner
    @Environment(\.appAccent) private var accent
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
    /// `Config.cameraBackend`, the same key and default (Ray-Ban Meta).
    @AppStorage("cameraBackend") private var cameraBackend: CameraBackendChoice = .metaRayBan

    private var rokidCameraBinding: Binding<Bool> {
        Binding(
            get: { cameraBackend == .rokidRV101 },
            set: { cameraBackend = $0 ? .rokidRV101 : .metaRayBan }
        )
    }

    init(appState: AppState) {
        self.appState = appState
        _runner = StateObject(wrappedValue: SubsystemProbes.makeRunner(appState: appState))
    }

    var body: some View {
        OGScrollPage {
            OGNotice(
                text: "Each test exercises the real path — the camera takes a photo, the AI answers a tiny query, the lens renders a card.",
                systemImage: "stethoscope"
            )

            OGSection(header: "Subsystems") {
                ForEach(Array(runner.tests.enumerated()), id: \.element.id) { index, test in
                    if index > 0 { OGDivider() }
                    Button {
                        Task { await runner.run(test.id) }
                    } label: {
                        OGRow(test.name, icon: test.icon, showsChevron: false) {
                            trailingState(for: test.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(runner.running.contains(test.id))
                }

                if let failure = runner.lastFailure {
                    OGDivider()
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(OGTheme.errorLabel)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }

            Button {
                Task { await runner.runAll() }
            } label: {
                HStack(spacing: 8) {
                    if runner.isRunning {
                        ProgressView().tint(Color.primary)
                    } else {
                        Image(systemName: "checklist")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(runner.isRunning ? "Running…" : "Run All")
                        .font(.body.weight(.semibold))
                }
                // The accent is the *ground* here, so the label is whichever pole
                // reads on it — a hard-coded white loses a bright preset.
                .foregroundStyle(runner.isRunning
                    ? AnyShapeStyle(Color.primary)
                    : AnyShapeStyle(OGTheme.onAccentLabel(accent)))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(runner.isRunning ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(accent), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(runner.isRunning)

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
                footer: "Starts speaking a reply at its first sentence while the rest is still being written, instead of waiting for the whole answer. The words are the same; only the timing changes. Off until it has been measured on the glasses."
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

            // Rokid RV101 support is early and unproven on hardware, so its camera switch and the
            // link probe live here rather than in the glasses settings everyone sees.
            OGSection(
                header: "Rokid Glasses",
                footer: "Early support that has not been tested on the glasses yet. The camera choice applies from the next launch, and until the glasses can send photos, captures use the iPhone camera."
            ) {
                OGRow("Use the Rokid camera", isOn: rokidCameraBinding, icon: "camera")
                OGDivider()
                NavigationLink {
                    RokidDiagnosticsView()
                } label: {
                    OGRow(
                        "Rokid glasses probe", icon: "antenna.radiowaves.left.and.right",
                        subtitle: "Accessory list, link probes and the raw frame log"
                    )
                }
                .buttonStyle(.plain)
            }

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

    @ViewBuilder
    private func trailingState(for id: String) -> some View {
        if runner.running.contains(id) {
            ProgressView()
        } else if let outcome = runner.outcomes[id] {
            HStack(spacing: 6) {
                if outcome.passed {
                    Text("\(outcome.detail) · \(SubsystemTestRunner.format(outcome.seconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: outcome.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(outcome.passed ? OGTheme.ok : OGTheme.error)
            }
        } else {
            Image(systemName: "play.circle")
                .foregroundStyle(.tertiary)
        }
    }
}
