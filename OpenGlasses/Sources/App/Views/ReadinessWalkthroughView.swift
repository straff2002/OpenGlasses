import SwiftUI

/// Plan FF P1/PR8 — "Check the assistant is ready", the screen that runs the readiness
/// walk-through.
///
/// Three things here are deliberate and none of them is visual:
///
/// * **Each result is one accessibility element.** Title, status and the next instruction are read
///   as one thought. Split across three elements, VoiceOver stops three times on half a sentence
///   each and the wearer has to assemble the answer themselves.
/// * **Focus moves to the result as it lands.** The runner names the step it just finished; this
///   view moves focus there. Without it, a wearer who swiped away while a step was running is left
///   wherever they were, listening to a status about a row they cannot find.
/// * **Retry re-runs from that step, not from the top.** A permission granted in iOS Settings
///   should cost one step, not five — and on the camera step, not another twelve seconds of
///   stream.
@MainActor
struct ReadinessWalkthroughView: View {
    @StateObject private var runner: ReadinessWalkthroughRunner
    @AccessibilityFocusState private var focusedStep: ReadinessWalkthrough.Step?

    init(runner: ReadinessWalkthroughRunner? = nil) {
        _runner = StateObject(wrappedValue: runner ?? ReadinessWalkthroughView.liveRunner())
    }

    /// The production wiring: the real probe over `AppState`'s services, speaking through the
    /// app's own voice so the statuses are heard with VoiceOver off as well.
    static func liveRunner() -> ReadinessWalkthroughRunner {
        let appState = AppStateProvider.shared
        let probe = LiveReadinessProbe(
            launchInputs: {
                guard let appState else { return BlindAssistantLaunchPolicy.Inputs() }
                return await appState.blindAssistantLaunchInputs(awaitRegistration: false)
            },
            camera: appState?.cameraService,
            wakeWord: appState?.wakeWordService,
            speech: appState?.speechService)
        return ReadinessWalkthroughRunner(probe: probe) { line in
            guard let speech = appState?.speechService else { return }
            _ = await speech.speakReporting(line, urgency: .high)
        }
    }

    var body: some View {
        Form {
            Section {
                Button(runner.results.isEmpty ? "Start the Check" : "Run the Check Again") {
                    Task { await runner.run() }
                }
                .disabled(runner.isRunning)
                .accessibilityHint("Runs five checks in order and says each result out loud.")

                if let running = runner.runningStep {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking \(running.title.lowercased())…")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Checking \(running.title). \(running.purpose)")
                }
            } header: {
                Text("Readiness Check")
            } footer: {
                Text("Runs five checks in order and stops at the first one that fails, so there is only ever one thing to fix. Each result is said out loud, whether or not VoiceOver is on.\n\nNothing passes because a part reports that it exists: the camera check waits for an actual picture, and the microphone check plays a line you have to be able to hear. The check gives back everything it borrows — if it started the camera, it stops it again, unless something else was already using it.")
            }

            if !runner.results.isEmpty {
                Section {
                    ForEach(runner.results) { result in
                        resultRow(result)
                    }
                } header: {
                    Text("Results")
                } footer: {
                    Text(runner.summary)
                }
            }
        }
        .navigationTitle("Readiness Check")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onChange(of: runner.focusTarget) { _, target in
            guard let target else { return }
            focusedStep = target
            // Cleared so the next result can move focus again; leaving it set would pin focus to
            // the first result for the rest of the run.
            runner.focusTarget = nil
        }
    }

    @ViewBuilder
    private func resultRow(_ result: ReadinessWalkthrough.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.step.title)
                    .font(.headline)
                Spacer()
                Text(statusWord(result.verdict))
                    .font(.footnote)
                    .foregroundStyle(statusColor(result.verdict))
            }
            Text(result.spokenStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let instruction = result.nextInstruction {
                Text(instruction)
                    .font(.footnote)
            }
        }
        .padding(.vertical, 2)
        // One element for the whole row, and the status as its *value* — a wearer moving down the
        // list hears "Glasses, passed" and can stop there, or wait for the rest.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.step.title)
        .accessibilityValue(result.accessibilityLabel)
        .accessibilityFocused($focusedStep, equals: result.step)

        if result.retryAvailable {
            Button("Retry \(result.step.title)") {
                Task { await runner.retry(result.step) }
            }
            .disabled(runner.isRunning)
            .accessibilityHint("Runs this check again and carries on from here.")
        }
    }

    private func statusWord(_ verdict: ReadinessWalkthrough.Verdict) -> String {
        switch verdict {
        case .passed(let note): return note == nil ? "Passed" : "Passed with a note"
        case .failed: return "Needs attention"
        case .skipped: return "Skipped"
        }
    }

    private func statusColor(_ verdict: ReadinessWalkthrough.Verdict) -> Color {
        // Colour is never the only carrier: the word beside it says the same thing, and the row's
        // accessibility value says it again.
        switch verdict {
        case .passed: return .secondary
        case .failed: return AppAccent.color
        case .skipped: return .secondary
        }
    }
}
