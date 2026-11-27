import SwiftUI

/// "Record experience" on the phone (Plan IM P1): the five-prompt card, one button, and the
/// recordings kept on this phone.
///
/// Reached from the Jobs list (with or without a job open) and from Field Assist settings. The
/// technician only talks: the card is a prompt, not a form, and nothing here asks them to check a
/// draft (decision 1). With a job open, a recording files on that job for the team, as "note this
/// for the team" does; without one it is kept here, its audio for 30 days.
struct ExperienceRecorderView: View {
    @ObservedObject var recorder: ExperienceRecorder
    @ObservedObject var store: ExperienceRecordingStore
    /// The open job's number, or "Open job", when one is open.
    let openJob: String?
    /// On a reviewer's device, the vault's models with no crew experience yet (Plan IM P4). Read
    /// when the page opens; nil everywhere else.
    @State private var coverage: ExperienceCoverage?

    var body: some View {
        List {
            promptCard
            recordSection
            if let coverage, let summary = ExperienceCoverageCopy.summary(coverage) { coverageSection(coverage, summary) }
            if !store.recordings.isEmpty { recordingsSection }
        }
        .ogFormStyle()
        .navigationTitle("Record experience")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.sweepExpiredAudio()
            coverage = ExperienceCoverage.current()
        }
    }

    // MARK: - What's missing (a reviewer's device)

    /// A count and a list, nothing more: nothing is assigned, sent or badged from here.
    private func coverageSection(_ coverage: ExperienceCoverage, _ summary: String) -> some View {
        Section {
            Text(summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !coverage.missing.isEmpty {
                DisclosureGroup(ExperienceCoverageCopy.missingListTitle) {
                    ForEach(Array(coverage.missingNames.enumerated()), id: \.offset) { _, name in
                        Text(verbatim: name).font(.callout)
                    }
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
            }
        } header: {
            Text(ExperienceCoverageCopy.sectionTitle)
        }
    }

    // MARK: - The card

    private var promptCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(ExperienceRecorderCopy.cardTitle).font(.headline)
                ForEach(Array(ExperienceRecorderCopy.prompts.enumerated()), id: \.offset) { index, prompt in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(index + 1).")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(prompt)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(ExperienceRecorderCopy.standingLine)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(ExperienceRecorderCopy.cardHowTo)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Record and stop

    @ViewBuilder
    private var recordSection: some View {
        let verdict = recorder.verdict
        Section {
            if case .unavailable(let reason) = verdict {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task {
                    if recorder.phase.isBusy { await recorder.finish() }
                    else { await recorder.start(from: .phone) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: recorder.phase.isBusy ? "stop.circle.fill" : "mic.fill")
                        .accessibilityHidden(true)
                    Text(recorder.phase.isBusy ? "Stop recording" : "Record experience")
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.ogProminent)
            .disabled(!verdict.isAvailable && !recorder.phase.isBusy)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityHint(recorder.phase.isBusy
                               ? "Ends this recording and keeps what was said."
                               : "Records one case. Say \u{201C}that's one, next case\u{201D} to start the next.")

            statusLine
            if !recorder.heardSoFar.isEmpty {
                Text(recorder.heardSoFar)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Heard so far")
                    .accessibilityValue(recorder.heardSoFar)
            }
            if let outcome = recorder.lastOutcome, !recorder.phase.isBusy {
                Text(outcome.spoken)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if let openJob {
                Text("\(openJob) is open, so a recording is filed on that job for your team, the way \u{201C}note this for the team\u{201D} is. Transcribed on this phone; its audio isn't kept.")
            } else {
                Text("Transcribed on this phone and kept here for your team to review. The audio stays on this phone and is deleted after 30 days. Nothing is sent from this screen.")
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch recorder.phase {
        case .idle:
            EmptyView()
        case .preparing:
            Text("Getting ready…").font(.callout).foregroundStyle(.secondary)
        case .recording(let number, _, _):
            let clock = ExperienceRecorderRules.clock(recorder.elapsed)
            let cap = ExperienceRecorderRules.clock(ExperienceRecorderRules.recordingCap)
            Text("Recording case \(number) · \(clock) of \(cap)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tint)
        case .saving:
            Text("Saving…").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Kept on this phone

    private var recordingsSection: some View {
        Section {
            ForEach(store.newestFirst) { recording in
                NavigationLink {
                    ExperienceRecordingDetailView(store: store, recordingId: recording.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.body)
                        Text(verbatim: recording.formattedDuration + " · " + recording.status.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                }
            }
            .onDelete { offsets in
                let list = store.newestFirst
                for index in offsets where list.indices.contains(index) { store.delete(id: list[index].id) }
            }
        } header: {
            Text("On this phone")
        }
    }
}

/// One kept recording: its transcript, where its audio is, and Delete.
struct ExperienceRecordingDetailView: View {
    @ObservedObject var store: ExperienceRecordingStore
    let recordingId: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        List {
            if let recording = store.recording(id: recordingId) {
                Section {
                    Text(recording.transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(verbatim: recording.createdAt.formatted(date: .abbreviated, time: .shortened)
                         + " · " + recording.formattedDuration)
                } footer: {
                    Text(ExperienceRecorderCopy.audioLine(recording, hasAudio: store.hasAudio(recording.id)))
                }
                Section {
                    LabeledContent("Status", value: recording.status.label)
                }
                Section {
                    Button("Delete recording", role: .destructive) { confirmingDelete = true }
                        .frame(minHeight: OGMetrics.minTouchTarget)
                }
            } else {
                Text("This recording is no longer on this phone.")
                    .foregroundStyle(.secondary)
            }
        }
        .ogFormStyle()
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this recording?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(id: recordingId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its transcript and audio are removed from this phone. This can't be undone.")
        }
    }
}
