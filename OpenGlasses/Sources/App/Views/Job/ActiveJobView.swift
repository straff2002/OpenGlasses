import SwiftUI

/// The Job tab with a job open (Plan FO P2).
///
/// Top to bottom, in the order a technician needs them: anything the app is waiting on an answer
/// for, then what the job is filed under, then the clock, then the machine, then the work, then the
/// three things you do with a job — open its conversation, hear it back, finish it.
///
/// The two questions are **cards, not alerts**. A modal that steals focus is the wrong shape for a
/// question the technician may want to leave sitting while they finish tightening something, and
/// the wording is the same sentence P1 speaks out loud so a half-heard question can be finished by
/// eye.
struct ActiveJobView: View {
    let job: JobTabModel.Active
    let model: JobTabModel
    @Binding var typedReference: String
    @Binding var leaveThread: JobTabModel.ThreadQuestionCard?
    let unitQuestion: JobTabModel.QuestionCard?
    /// The job's photos and what is currently ticked (Plan FO P2a). Nil only if the job went away
    /// between the state being read and this being drawn.
    let evidence: EvidenceReviewModel?
    @Binding var evidenceSelection: EvidenceSelection
    let onAnswerUnit: (JobTabModel.QuestionCard.Action) -> Void
    let onPauseResume: () -> Void
    let onAddPhoto: (JobMediaItem.Origin, Data) -> Void
    /// The clip recorder, so the record row can show its own countdown (Plan FO P2b).
    let clips: JobClipRecorder
    let onRecordClip: () -> Void
    let onStopClip: () -> Void
    let onSharePhotos: () -> Void
    let onOpenPrivacySettings: () -> Void
    let onOpenConversation: () -> Void
    let onReadBack: () -> Void
    let onClose: () -> Void

    @Environment(\.appAccent) private var accent
    @FocusState private var referenceFocused: Bool
    @State private var expandedTaskId: String?

    var body: some View {
        List {
            if let unitQuestion { questionCard(unitQuestion) }
            if let leaveThread { threadQuestionCard(leaveThread) }
            jobNumberSection
            timeSection
            unitSection
            workSection
            // The job's evidence, with the face-blur state stated in plain words beside it. What
            // of it goes out is decided at close, in `JobEvidenceReviewView`; what this section is
            // for is knowing, mid-job, that the pictures and clips are landing somewhere.
            if let evidence {
                JobPhotosSection(review: evidence, selection: evidenceSelection,
                                 onAdd: onAddPhoto,
                                 onOpenSettings: onOpenPrivacySettings,
                                 clips: clips,
                                 onRecordClip: onRecordClip,
                                 onStopClip: onStopClip,
                                 onShare: onSharePhotos)
            }
            actionsSection
        }
        .ogFormStyle()
    }

    // MARK: - The questions

    private func questionCard(_ card: JobTabModel.QuestionCard) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(card.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(card.actions) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        onAnswerUnit(action)
                    } label: {
                        Text(action.title)
                            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                                   alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label(card.title, systemImage: "questionmark.circle")
                .foregroundStyle(accent)
        } footer: {
            Text("Answer by tapping, or just say it — \u{201C}same job\u{201D}, \u{201C}that one's finished\u{201D}, \u{201C}not sure\u{201D}.")
        }
    }

    private func threadQuestionCard(_ card: JobTabModel.ThreadQuestionCard) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(card.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                choice(card.keepTitle) { leaveThread = nil }
                choice(card.leaveTitle) {
                    model.confirmLeaveThread()
                    leaveThread = nil
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("Keep this in the job?", systemImage: "questionmark.circle")
                .foregroundStyle(accent)
        }
    }

    // MARK: - What the job is filed under

    private var jobNumberSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.intake.headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = job.intake.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(job.intake.spoken)

            TextField(text: $typedReference) {
                Text(job.intake.fieldPrompt)
            }
            .focused($referenceFocused)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit(recordTypedReference)
            .accessibilityLabel("Job number")
            .accessibilityHint("Type the number and press Done. It is recorded exactly as you type it.")

            if !typedReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                choice("Record job number") { recordTypedReference() }
            }

            if job.intake.offersDecline {
                choice("There's no job number") { model.declineJobReference() }
                    .accessibilityHint("Records that this job has no number. The report still goes out and you won't be asked again.")
            }
        } header: {
            Text("Job number")
        } footer: {
            Text("Recorded exactly as given — never guessed from a work order or tidied up.")
        }
    }

    private func recordTypedReference() {
        model.supplyJobReference(typedReference)
        typedReference = ""
        referenceFocused = false
    }

    // MARK: - The clock

    private var timeSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.elapsedLine)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(job.pauseFootnote)
                        .font(.caption)
                        .foregroundStyle(job.isPaused ? OGTheme.warnLabel : Color.secondary)
                }
                Spacer(minLength: 12)
                Button(job.pauseButtonTitle, action: onPauseResume)
                    .buttonStyle(.ogProminentCompact)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)

            Text(job.startedLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Time on the job")
        }
        // The value, not a live region: VoiceOver reads it when the row is focused rather than
        // announcing a new number in the middle of whatever else is being said.
        .accessibilityValue(job.elapsedSpoken)
    }

    // MARK: - The machine

    private var unitSection: some View {
        Section {
            HStack {
                Text(job.unitLine)
                    .font(.headline)
                    .foregroundStyle(job.currentUnit == nil ? Color.secondary : Color.primary)
                Spacer(minLength: 8)
                if job.currentUnit != nil {
                    Text("Now")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            if job.visitedUnits.count > 1 {
                ForEach(job.visitedUnits.dropFirst(), id: \.self) { unit in
                    Text(unit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(job.visitedUnits.count > 1 ? "Units on this job" : "Unit")
        } footer: {
            if job.visitedUnits.count > 1 {
                Text("One job can cover several machines. Work is kept apart per machine in the record.")
            }
        }
    }

    // MARK: - The work

    @ViewBuilder
    private var workSection: some View {
        let tasks = TaskSectionModel(host: FieldSessionService.shared)
        let rows = tasks.rows
        Section {
            if rows.isEmpty {
                Text(tasks.emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(rows) { row in
                    Button {
                        expandedTaskId = (expandedTaskId == row.id) ? nil : row.id
                    } label: {
                        TaskRowView(row: row, expanded: expandedTaskId == row.id)
                    }
                }
            }
            if let unsent = tasks.unsentLine {
                Text(unsent)
                    .font(.caption)
                    .foregroundStyle(OGTheme.warnLabel)
            }
        } header: {
            Text(rows.isEmpty ? "Work" : "Work — \(tasks.headline)")
        }
    }

    // MARK: - The three things you do with a job

    private var actionsSection: some View {
        Section {
            choice("Open conversation", action: onOpenConversation)
                .disabled(!job.hasConversation)
                .accessibilityHint(job.hasConversation
                                   ? "Opens the Chat tab on this job's conversation."
                                   : "Nothing has been said on this job yet.")

            choice("Start a separate chat") {
                leaveThread = model.leaveThreadQuestion()
            }
            .disabled(!job.hasConversation)
            .accessibilityHint("Asks first. The job keeps its conversation either way.")

            choice("Read back the job", action: onReadBack)
                .disabled(!job.hasRecord)

            Button("Close job", role: .destructive, action: onClose)
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                .accessibilityHint(job.photoCount > 0
                                   ? "Asks which photos and clips go with the report, then stops the clock and finishes the record."
                                   : "Stops the clock, finishes the record, and takes you to it so you can send it.")
        } header: {
            Text("This job")
        }
    }

    /// One tappable line in a section.
    ///
    /// Deliberately not `.ogQuiet`: that style centres its label, paints it in the secondary
    /// label colour and swallows a destructive role, which turned four distinct actions — one of
    /// which ends the job — into four identical grey centred strings. A plain `Form` button is
    /// leading-aligned, tinted, and keeps its role, which is what these are.
    private func choice(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        }
    }

    /// The same row for copy the model already owns — the question cards' answers, whose exact
    /// wording is asserted in `JobTabModelTests`. Disfavored so an authored literal at a call site
    /// still reaches the string catalog, the way the design kit's own pairs do.
    @_disfavoredOverload
    private func choice<S: StringProtocol>(_ title: S, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        }
    }
}

/// One task on the job, collapsed to a title and a status until it is tapped.
struct TaskRowView: View {
    let row: TaskSectionModel.Row
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // `.secondary` on a `.secondary`-tinted capsule measured 3.2:1 against the row
                // background in light appearance — below WCAG AA's 4.5:1 for 11-point text, and
                // this chip is the only thing on the row that says whether the work is done. The
                // primary label on a slightly stronger fill reads as the same quiet chip and
                // measures 15:1 light / 11:1 dark. Nothing here is tinted with the accent: a
                // status is not an AI affordance.
                Text(row.statusLabel)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.22)))
                    .foregroundStyle(Color.primary)
            }
            if let evidence = row.evidence {
                Text(evidence).font(.caption).foregroundStyle(Color.secondary)
            }
            if expanded {
                if row.isOperatorAdded {
                    Text("Added by the technician").font(.caption).foregroundStyle(Color.secondary)
                }
                if let why = row.why {
                    Text("Why: \(why)").font(.caption).foregroundStyle(Color.secondary)
                }
                if let procedure = row.procedureLine {
                    Text(procedure).font(.caption).foregroundStyle(Color.secondary)
                }
                ForEach(row.parts, id: \.self) { part in
                    Text("Part: \(part)").font(.caption).foregroundStyle(Color.secondary)
                }
                if let note = row.completionNote {
                    Text("Note: \(note)").font(.caption).foregroundStyle(Color.secondary)
                }
                if let citation = row.citation {
                    Text("Cited \(citation)").font(.caption).foregroundStyle(Color.secondary)
                }
                if let safety = row.safetyNote {
                    Text(safety).font(.caption).foregroundStyle(OGTheme.warnLabel)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title). \(row.statusLabel).")
        .accessibilityHint("Double-tap for why it was recommended and what was recorded against it.")
    }
}
