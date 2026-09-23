import SwiftUI

/// What a finished job's debriefs look like on its page (Plan FO §6, P3b).
///
/// Each one is its own dated entry, under its own headings, with the items exactly as they were
/// saved. An item the summary marked carries its note in **words** — "reported, not verified" —
/// rather than a colour, because the whole point of the mark is that it survives being read aloud.
struct JobDebriefSection: View {

    let debriefs: [JobDebrief]
    /// Opening one turn's source text, when the reader wants to see where an item came from.
    @State private var showingSources: JobDebrief?

    var body: some View {
        Section {
            ForEach(debriefs) { debrief in
                VStack(alignment: .leading, spacing: 6) {
                    Text(debrief.attributionLine())
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if debrief.unsummarised {
                        Text(JobDebrief.unsummarisedNote)
                            .font(.caption)
                            .foregroundStyle(OGTheme.warnLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(debrief.summaryLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)

                if !debrief.turns.isEmpty {
                    Button { showingSources = debrief } label: {
                        Text("What was said")
                            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                                   alignment: .leading)
                    }
                    .accessibilityHint("Shows the debrief turns each item was taken from.")
                }
            }
        } header: {
            Text(JobDebrief.blockTitle)
        } footer: {
            Text(JobDebrief.disclaimer)
        }
        .sheet(item: $showingSources) { debrief in
            DebriefSourcesSheet(debrief: debrief) { showingSources = nil }
        }
    }
}

/// The debrief's own turns, so a reader can check an item against what was actually said.
struct DebriefSourcesSheet: View {
    let debrief: JobDebrief
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(debrief.turns) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.at.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(turn.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("What was said")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
    }
}

/// The debrief as it is being taken, on the phone (Plan FO P3b).
///
/// The car needs none of this — a debrief there is voice only — but the same conversation has to
/// be possible with a customer standing there and the phone in hand, and the read-back has to be
/// something a technician can *see* before they agree to it.
struct JobDebriefSheet: View {

    let debrief: ActiveDebrief
    let onFinish: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void
    let onRetry: () -> Void
    let onKeepRaw: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(debrief.job.spoken)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Talk the job over. Nothing goes on the record until you save it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Debriefing")
                }

                switch debrief.state {
                case .listening:
                    listening
                case .summarising:
                    Section { Text("Putting that together…").font(.callout) }
                case .readBack(let summary), .awaitingDecision(let summary):
                    readBack(summary)
                case .editing(_, _, let summary):
                    readBack(summary)
                    Section { Text("Say what it should be instead.").font(.callout) }
                case .failed(let reason):
                    failed(reason)
                case .saved:
                    Section { Text("Saved to \(debrief.jobNumber).").font(.callout) }
                case .discarded:
                    Section { Text("Scrapped. Nothing went on the record.").font(.callout) }
                }
            }
            .ogFormStyle()
            .navigationTitle(JobDebrief.blockTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
    }

    @ViewBuilder
    private var listening: some View {
        Section {
            ForEach(debrief.turns) { turn in
                Text(turn.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if debrief.turns.isEmpty {
                Text("Nothing said yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button { onFinish() } label: {
                Text("That's it — write it up")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                           alignment: .leading)
            }
            .disabled(debrief.turns.isEmpty)
        } header: {
            Text("What you've said")
        }
    }

    @ViewBuilder
    private func readBack(_ summary: DebriefSummary) -> some View {
        Section {
            ForEach(Array(summary.readBackLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("The summary")
        } footer: {
            Text("Items are your report of the visit, not verified work. Saving adds them to the job; it changes nothing that was already recorded.")
        }

        Section {
            Button { onSave() } label: {
                Text("Save to \(debrief.jobNumber)")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                           alignment: .leading)
            }
            Button(role: .destructive) { onDiscard() } label: {
                Text("Scrap it")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                           alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func failed(_ reason: String) -> some View {
        Section {
            Text(reason)
                .font(.callout)
                .foregroundStyle(OGTheme.warnLabel)
                .fixedSize(horizontal: false, vertical: true)
            Button { onRetry() } label: {
                Text("Try again")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                           alignment: .leading)
            }
            Button { onKeepRaw() } label: {
                Text("Keep what I said")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                           alignment: .leading)
            }
            .accessibilityHint("Saves the debrief word for word, labelled as not summarised.")
            Button(role: .destructive) { onDiscard() } label: {
                Text("Scrap it")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                           alignment: .leading)
            }
        } header: {
            Text("That didn't come back right")
        }
    }
}
