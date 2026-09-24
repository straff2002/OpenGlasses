import SwiftUI

/// The Upcoming section of the Job tab (Plan FO §7, P3c): jobs ahead, soonest first, and a way to
/// add one by typing. A job that arrived as a file says whether it was signed.
struct UpcomingJobsSection: View {
    let rows: [UpcomingJobsModel.Row]
    let onOpen: (String) -> Void
    let onAdd: () -> Void

    var body: some View {
        Section {
            ForEach(rows) { row in
                Button { onOpen(row.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                        if let provenance = row.provenance {
                            Label(provenance, systemImage: row.isSigned ? "checkmark.seal" : "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(row.isSigned ? Color.secondary : OGTheme.warnLabel)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.spoken)
                .accessibilityHint("Opens the job's brief, directions and Start.")
                .accessibilityAddTraits(.isButton)
            }
            Button(action: onAdd) {
                Label("Add an upcoming job", systemImage: "plus")
            }
        } header: {
            Text("Upcoming")
        } footer: {
            if rows.isEmpty {
                Text("Jobs you haven't started yet. Add one here, say \u{201C}next job: 1007, no heat, Smith Street\u{201D}, or open a job file the office emailed you.")
            }
        }
    }
}

/// One job ahead: what is known, the brief, directions, and Start (Plan FO §7).
struct UpcomingJobView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: UpcomingJobStore
    @ObservedObject var flow: GuidedJobFlow
    let jobId: String
    /// Whether a job is already open, which is the one thing that stops this one starting.
    let jobOpen: Bool
    let vaultName: String
    let vaultUnlocked: Bool
    /// Called with the session once the job has started.
    let onStarted: (FieldSession) -> Void

    @State private var problem: String?
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private var job: UpcomingJob? { store.job(id: jobId) }

    var body: some View {
        Group {
            if let job {
                List {
                    detailsSection(job)
                    actionsSection(job)
                    if let brief = job.brief {
                        ForEach(brief.sections, id: \.kind) { section in
                            briefSection(section)
                        }
                    }
                    Section {
                        Button("Remove from upcoming jobs", role: .destructive) { confirmingDelete = true }
                    }
                }
                .ogFormStyle()
                .navigationTitle(job.title)
            } else {
                Text("This job is no longer on the list.")
                    .foregroundStyle(.secondary)
                    .navigationTitle("Upcoming job")
            }
        }
        .confirmationDialog("Remove this job?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.remove(id: jobId)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        }
        .alert("That didn't work", isPresented: Binding(get: { problem != nil },
                                                        set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func detailsSection(_ job: UpcomingJob) -> some View {
        Section {
            row("Job number", job.jobReference ?? JobTabModel.noJobNumber)
            if let customer = job.site.customer { row("Customer", customer) }
            if let address = job.site.address { row("Address", address) }
            if let contact = job.site.contact { row("Contact", contact) }
            if let scheduled = job.scheduledFor {
                row("Booked for", scheduled.formatted(date: .abbreviated, time: .shortened))
            }
            if let fault = job.faultReport {
                row("Fault report (\(fault.source.attribution))", fault.text)
            }
            if !job.equipment.isEmpty {
                row("Equipment", job.equipment.map(\.summary).joined(separator: "\n"))
            }
            if let notes = job.notes { row("Notes", notes) }
            if !job.attachments.isEmpty {
                row("Attachments (not included)", job.attachments.joined(separator: "\n"))
            }
            if let line = UpcomingJobsModel.provenanceLine(job.provenance) {
                row("From", line)
            }
        } header: {
            Text("The job")
        } footer: {
            Text("Anything nobody gave stays empty. This job hasn't started and counts no time.")
        }
    }

    @ViewBuilder
    private func actionsSection(_ job: UpcomingJob) -> some View {
        let blocked = UpcomingJobsModel.startBlockedReason(jobOpen: jobOpen, vaultUnlocked: vaultUnlocked,
                                                           vaultName: vaultName)
        Section {
            Button {
                Task { await flow.briefAloud(jobId: job.id) }
            } label: {
                Label(job.brief == nil ? "Brief me" : "Brief me again", systemImage: "text.bubble")
            }
            .accessibilityHint("Reads the brief aloud and shows it below.")

            Button {
                directions(to: job)
            } label: {
                Label("Directions", systemImage: "car")
            }
            .disabled(job.destination == nil)
            .accessibilityHint(job.destination == nil
                               ? "Unavailable: this job has no address."
                               : "Opens \(Config.preferredMapsApp.label) with directions to the site.")

            Button {
                start(job)
            } label: {
                Text("Start this job")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.ogProminent)
            .disabled(blocked != nil)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if let blocked {
                Text(blocked)
                    .font(.caption)
                    .foregroundStyle(OGTheme.warnLabel)
            }
        } footer: {
            Text("Start on site. The job number, site and fault report go with it; the equipment is recognised there, as on any job.")
        }
    }

    private func briefSection(_ section: JobBrief.Section) -> some View {
        Section {
            if section.isEmpty {
                Text(section.kind.emptyLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text).font(.callout)
                        Text(item.citation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text(section.kind.title)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func directions(to job: UpcomingJob) {
        guard let destination = job.destination,
              let handoff = MapsLauncher.plan(destination: destination) else { return }
        MapsLauncher.open(handoff)
        if handoff.unavailable != nil {
            Task { await appState.speechService.speak(handoff.spoken) }
        }
    }

    private func start(_ job: UpcomingJob) {
        do {
            let session = try flow.startUpcomingJob(id: job.id)
            Task { await appState.speechService.speak(GuidedJobFlow.startedLine(for: job)) }
            onStarted(session)
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Typing a job ahead in (Plan FO §7). Every field optional; nothing is filled in for you.
struct AddUpcomingJobView: View {
    let onSave: (UpcomingJob) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var reference = ""
    @State private var customer = ""
    @State private var address = ""
    @State private var contact = ""
    @State private var fault = ""
    @State private var model = ""
    @State private var serial = ""
    @State private var notes = ""
    @State private var hasTime = false
    @State private var scheduled = Date()

    private var draft: UpcomingJob {
        UpcomingJob(
            jobReference: reference,
            site: JobSite(customer: customer, address: address, contact: contact),
            faultReport: JobSite.cleaned(fault).map { FaultReport(text: $0, source: .typed) },
            equipment: [KnownEquipment(model: model, serial: serial)],
            scheduledFor: hasTime ? scheduled : nil,
            notes: notes,
            origin: .typed)
    }

    private var canSave: Bool {
        draft.jobReference != nil || !draft.site.isEmpty || draft.faultReport != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Job number", text: $reference)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Customer", text: $customer)
                    TextField("Address", text: $address, axis: .vertical)
                    TextField("Contact", text: $contact)
                } header: {
                    Text("Job and site")
                }
                Section {
                    TextField("What was reported, in their words", text: $fault, axis: .vertical)
                } header: {
                    Text("Fault report")
                }
                Section {
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Serial", text: $serial)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Equipment, if known")
                }
                Section {
                    Toggle("Booked for a time", isOn: $hasTime)
                    if hasTime {
                        DatePicker("Booked for", selection: $scheduled)
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                } footer: {
                    Text("Leave anything you don't know empty. The brief says what's missing rather than guessing.")
                }
            }
            .ogFormStyle()
            .navigationTitle("Upcoming job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
