import SwiftUI

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
                    JobUpdatesSection(jobID: job.provenance?.identity?.jobID)
                    detailsSection(job)
                    JobNeedsSection(needs: job.needs)
                    actionsSection(job)
                    officeFlagsSection(job)
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
            if let contact = job.site.contact {
                row("Contact", contact)
                if job.origin == .connector {
                    let digits = contact.filter { $0.isNumber || $0 == "+" }
                    if !digits.isEmpty, let url = URL(string: "tel:" + digits) {
                        Link(destination: url) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "phone").accessibilityHidden(true)
                                Text("Call customer").fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.accessibilityIdentifier("workiz.callCustomer")
                    }
                }
            }
            if job.origin == .connector {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                    Text("Workiz").fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
            }
            if let scheduled = job.scheduledFor {
                row("Booked for", scheduled.formatted(date: .abbreviated, time: .shortened))
            }
            if let fault = job.faultReport {
                row("Fault report (\(fault.source.attribution))", fault.text)
            }
            if !job.equipment.isEmpty {
                row("Equipment", job.equipment.map(\.summary).joined(separator: "\n"))
            }
            // The documented site system the brief matched the job to (Plan HV §5).
            if let site = SiteSystemContract.pageLines(job.siteSystem) {
                row("Site system: \(site.title)", site.units)
            }
            if let notes = job.notes { row("Notes", notes) }
            // Only the ones the file merely named. One it named by digest has its own row below.
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

    /// The office's maintenance flags, above the brief and before it has been asked for: the
    /// brief's own copy when there is one, otherwise worded straight from the job (Plan HU §4).
    @ViewBuilder
    private func officeFlagsSection(_ job: UpcomingJob) -> some View {
        let flags = job.brief?.flags ?? OfficeBriefText.flagItems(job.officeHistory, equipment: job.equipment)
        if !flags.isEmpty {
            Section {
                ForEach(Array(flags.enumerated()), id: \.offset) { _, item in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).font(.callout)
                            Text(item.citation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: item.severity == .warning ? OfficeFlagMark.symbol : "flag")
                            .foregroundStyle(item.severity == .warning ? OGTheme.warnLabel : Color.secondary)
                            .accessibilityLabel(item.severity == .warning ? "Warning" : "For information")
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Flagged by the office")
            } footer: {
                Text("The office's flags, with its evidence. Not a diagnosis, and never on the work order.")
            }
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
                        if item.isOfficeWarning {
                            // A site requirement the office marked as a warning.
                            Label(item.text, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(OGTheme.warnLabel)
                        } else {
                            Text(item.text).font(.callout)
                        }
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

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
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
            Task { await appState.speechService.speak(handoff.spoken, source: .job) }
        }
    }

    private func start(_ job: UpcomingJob) {
        do {
            let session = try flow.startUpcomingJob(id: job.id)
            // The started line, then the office's warnings — said this once (Plan HU P3).
            let spoken = flow.startLines(for: job).joined(separator: " ")
            Task { await appState.speechService.speak(spoken, source: .job) }
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
