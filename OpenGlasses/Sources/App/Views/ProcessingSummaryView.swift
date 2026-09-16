import SwiftUI

/// Recomputes `ProcessingSummary` whenever a setting that could change it is written.
///
/// There is no app-wide "a setting changed" notification in this app — settings screens read
/// `Config` on appear and on their own `onChange`. `UserDefaults.didChangeNotification` is the one
/// real, existing source that covers the whole set at once: the selected model, the live mode, the
/// voice-engine preference, the recogniser preference, Agent Mode, diarization and the medical
/// local-only flag are all `UserDefaults` keys, so writing any of them wakes this.
///
/// **What it does not catch**, stated rather than hidden: the saved model configurations live in
/// the Keychain, so editing the *active model's own provider or base URL* — as opposed to
/// selecting a different model — does not post a defaults change. That is why the summary is also
/// recomputed on appear, which is the path a wearer takes when they come back from the editor.
@MainActor
final class ProcessingSummaryModel: ObservableObject {
    @Published private(set) var summary: ProcessingSummary.Composed

    private let facts: @MainActor () -> ProcessingFacts
    private var observer: NSObjectProtocol?

    init(facts: @escaping @MainActor () -> ProcessingFacts = { ProcessingFactsProvider.current() }) {
        self.facts = facts
        self.summary = ProcessingSummary.compose(facts: facts())
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let recomputed = ProcessingSummary.compose(facts: facts())
        guard recomputed != summary else { return }
        summary = recomputed
    }
}

/// Plan FF P1/PR8 — "How your requests are processed".
///
/// Five rows, a verdict, the offline line and the caveat. Reached from two places on purpose: the
/// accessibility category, because a blind wearer deciding whether to hold up a prescription needs
/// it, and the privacy category, because that is where anyone else will look for it.
@MainActor
struct ProcessingSummaryView: View {
    @StateObject private var model: ProcessingSummaryModel
    @State private var speaking = false

    init(model: ProcessingSummaryModel? = nil) {
        _model = StateObject(wrappedValue: model ?? ProcessingSummaryModel())
    }

    var body: some View {
        Form {
            Section {
                Text(ProcessingSummary.verdictSentence(model.summary.verdict, rows: model.summary.rows))
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                if let offline = model.summary.offlineLine {
                    Text(offline)
                        .font(.footnote)
                        .accessibilityElement(children: .combine)
                }
                Button {
                    guard !speaking else { return }
                    speaking = true
                    Task { @MainActor in
                        if let speech = AppStateProvider.shared?.speechService {
                            _ = await speech.speakReporting(model.summary.spoken, urgency: .high)
                        }
                        speaking = false
                    }
                } label: {
                    Label(speaking ? "Reading it out…" : "Read This Out",
                          systemImage: "speaker.wave.2")
                }
                .disabled(speaking)
                .accessibilityHint("Says the whole summary out loud, including where each part of a request goes.")
            } header: {
                Text("Where Your Requests Go")
            }

            Section {
                ForEach(model.summary.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.kind.title)
                        Spacer()
                        Text(row.shortValue)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    // The spoken form is the value, so the row reads as a complete statement
                    // ("What you say — goes to Apple's speech recognition") rather than as a
                    // label and a bare host the wearer has to interpret.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.kind.title)
                    .accessibilityValue(row.destination.phrase)
                }
            } header: {
                Text("Each Part of a Request")
            } footer: {
                Text(ProcessingSummary.evidenceCaveat)
            }

            Section {
                NavigationLink {
                    NetworkMonitorView()
                } label: {
                    Label("Network Activity", systemImage: "antenna.radiowaves.left.and.right")
                }
                .accessibilityHint("Shows the requests the app observed. Separate from this summary, and not a complete audit.")
            } header: {
                Text("Observed Requests")
            } footer: {
                Text("This page describes what your settings are set up to do. Network Activity is the other half — what the app saw go out. They are different kinds of evidence, and neither is a complete packet capture.")
            }
        }
        .navigationTitle("How Requests Are Processed")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear { model.refresh() }
    }
}
