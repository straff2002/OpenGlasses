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
    /// What the page opens on: a case, or "Tell me about this site" (Plan IM P4).
    @State private var selectedKind: ExperienceRecording.Kind
    /// On a reviewer's device, the vault's models with no crew experience yet (Plan IM P4). Read
    /// when the page opens; nil everywhere else.
    @State private var coverage: ExperienceCoverage?

    init(recorder: ExperienceRecorder, store: ExperienceRecordingStore, openJob: String?,
         initialKind: ExperienceRecording.Kind = .experience) {
        self.recorder = recorder
        self.store = store
        self.openJob = openJob
        _selectedKind = State(initialValue: initialKind)
    }

    /// The kind shown and started: the one recording now, else the one picked.
    private var kind: ExperienceRecording.Kind {
        ExperienceRecordingEntry.kind(selected: selectedKind, recorderBusy: recorder.phase.isBusy,
                                      recording: recorder.kind)
    }

    var body: some View {
        List {
            kindPicker
            promptCard
            recordSection
            if let coverage, let summary = ExperienceCoverageCopy.summary(coverage) { coverageSection(coverage, summary) }
            if !store.recordings.isEmpty { recordingsSection }
        }
        .ogFormStyle()
        .navigationTitle(Text(ExperienceRecordingEntry.startTitle(kind)))
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

    // MARK: - The kind

    /// A case or a site. Fixed while a recording runs.
    private var kindPicker: some View {
        Section {
            Picker("What you're recording", selection: Binding(get: { kind }, set: { selectedKind = $0 })) {
                Text("A case").tag(ExperienceRecording.Kind.experience)
                Text("A site").tag(ExperienceRecording.Kind.site)
            }
            .pickerStyle(.segmented)
            .disabled(recorder.phase.isBusy)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - The card

    private var promptCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(kind == .site ? ExperienceRecorderCopy.siteTitle : ExperienceRecorderCopy.cardTitle).font(.headline)
                ForEach(Array((kind == .site ? ExperienceRecorderCopy.sitePrompts : ExperienceRecorderCopy.prompts).enumerated()),
                        id: \.offset) { index, prompt in
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
                    else { await recorder.start(from: .phone, kind: kind) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: recorder.phase.isBusy ? "stop.circle.fill" : "mic.fill")
                        .accessibilityHidden(true)
                    Text(recorder.phase.isBusy ? String(localized: "Stop recording") : ExperienceRecordingEntry.startTitle(kind))
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.ogProminent)
            .disabled(!verdict.isAvailable && !recorder.phase.isBusy)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityHint(recorder.phase.isBusy
                               ? Text("Ends this recording and keeps what was said.")
                               : Text(ExperienceRecorderCopy.recordHint))

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
            if let openJob, ExperienceRecordingEntry.filesOnOpenJob(kind: kind, jobOpen: true) {
                Text("\(openJob) is open, so a recording is filed on that job for your team, the way \u{201C}note this for the team\u{201D} is. Transcribed on this phone; its audio isn't kept.")
            } else if kind == .site {
                Text("Transcribed on this phone and kept here, never filed on a job: a site recording drafts a site document, not a team learning. The audio stays on this phone and is deleted after 30 days. Nothing is sent from this screen.")
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
            Group {
                if kind == .site { Text("Recording the site · \(clock) of \(cap)") }
                else { Text("Recording case \(number) · \(clock) of \(cap)") }
            }
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
                        Text(verbatim: ExperienceRecordingEntry.rowCaption(recording))
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

/// One kept recording: its transcript, where its audio is, and Delete. A site recording is
/// labelled as one and, on a reviewer's phone, offers "Draft site document" (Plan IM P4).
struct ExperienceRecordingDetailView: View {
    @ObservedObject var store: ExperienceRecordingStore
    let recordingId: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @StateObject private var siteDraft: SiteDraftReviewModel

    @MainActor
    init(store: ExperienceRecordingStore, recordingId: String) {
        self.store = store
        self.recordingId = recordingId
        _siteDraft = StateObject(wrappedValue: SiteDraftReviewModel.live())
    }

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
                    if recording.kind == .site {
                        LabeledContent("Kind", value: ExperienceRecorderCopy.siteTitle)
                    }
                    LabeledContent("Status", value: recording.status.label)
                }
                SiteDraftSection(recording: recording, model: siteDraft,
                                 offer: SiteDraftOffer.current(for: recording.kind))
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
        .navigationTitle(Text(ExperienceRecordingEntry.detailTitle(store.recording(id: recordingId)?.kind ?? .experience)))
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


/// "Draft site document" and its result (Plan IM P4). Read-only: the document as validated, its
/// file to share, or the drafter's reasons for drafting nothing. Nothing is saved into a vault.
struct SiteDraftSection: View {
    let recording: ExperienceRecording
    @ObservedObject var model: SiteDraftReviewModel
    let offer: SiteDraftOffer

    var body: some View {
        switch offer {
        case .none:
            EmptyView()
        case .reviewerOnly:
            Section {
                Text(SiteDraftOffer.reviewerOnlyLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Site document")
            }
        case .available:
            draftSection
            if case .drafted(let draft) = model.state { summary(SiteDraftSummary(draft.document), draft: draft) }
        }
    }

    @ViewBuilder
    private var draftSection: some View {
        Section {
            Button {
                Task { await model.draft(recording) }
            } label: {
                HStack(spacing: 8) {
                    Text(model.state == .idle ? "Draft site document" : "Draft again")
                    if model.state == .drafting {
                        Spacer()
                        ProgressView()
                    }
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
            }
            .disabled(model.state == .drafting)
            if case .refused(let message, let reasons) = model.state {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    Text(verbatim: reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Site document")
        } footer: {
            Text("Drafted from this recording's transcript by your assistant's provider, and checked against the vault it was recorded in. Nothing is saved.")
        }
    }

    @ViewBuilder
    private func summary(_ summary: SiteDraftSummary, draft: SiteRecordingDraft) -> some View {
        Section {
            LabeledContent("Site", value: summary.name)
            if let location = summary.location { LabeledContent("Where", value: location) }
            if let notes = summary.notes {
                Text(verbatim: notes).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Drafted site document")
        }
        Section {
            ForEach(Array(summary.units.enumerated()), id: \.offset) { _, unit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: unit.label ?? unit.model).font(.body)
                    Text(verbatim: [unit.model, unit.serial].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !unit.isCovered {
                        Text("Not in the vault").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            // Not "Units", which is the units of measurement in Navigation's settings.
            Text("Units on site")
        }
        if !summary.details.isEmpty {
            Section {
                ForEach(Array(summary.details.enumerated()), id: \.offset) { _, detail in
                    Text(verbatim: detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("How it fits together")
            }
        }
        Section {
            if let shareURL = model.shareURL {
                ShareLink(item: shareURL) {
                    Label("Share site document", systemImage: "square.and.arrow.up")
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
                Text(verbatim: SiteDraftReviewModel.shareFileName(draft))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text(SiteDraftReviewModel.shareUnavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(SiteDraftReviewModel.shareFooter)
        }
    }
}
