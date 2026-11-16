import SwiftUI

/// The page "Add new job" opens when no job is open (Plan HC; the empty state of Plan FO P2's tab):
/// which vault the job would use, the site it is at (Plan MD), one large Start job button with an
/// optional number, and a way to schedule a job for later instead.
///
/// It is the open job's page with no job in it (`JobRoute.currentJob`): starting a job here turns
/// this page into that job in place, exactly as the tab always behaved.
struct NewJobView: View {
    let empty: JobTabModel.NoJob
    @Binding var typedReference: String
    /// The site chosen for the job, or nil (Plan MD §1). Optional: no site starts a job exactly as
    /// before.
    @Binding var sitePick: NewJobSitePick?
    /// What the site picker offers, built by `NewJobSiteChoices`.
    let siteChoices: [NewJobSiteChoice]
    /// The vault's documented sites alone, for giving today's job one.
    let documentedSites: [NewJobSiteChoice]
    let onStart: () -> Void
    /// Add a job ahead — one not being started now.
    let onSchedule: () -> Void

    @FocusState private var referenceFocused: Bool
    @State private var choosingSite = false
    @State private var choosingDocument = false

    var body: some View {
        List {
            vaultSection
            siteSection
            startSection
            scheduleSection
        }
        .ogFormStyle()
        .sheet(isPresented: $choosingSite) {
            NewJobSitePicker(choices: siteChoices, title: "Choose a site", offersNewSite: true,
                             onChoose: choose, onNewSite: { site in
                                 if let pick = NewJobSitePick.newSite(site) { replacePick(with: pick) }
                             })
        }
        .sheet(isPresented: $choosingDocument) {
            NewJobSitePicker(choices: documentedSites, title: "Documented site", offersNewSite: false,
                             onChoose: { document in sitePick?.attach(document) }, onNewSite: nil)
        }
    }

    // MARK: - The vault a job would run against

    private var vaultSection: some View {
        Section {
            // The default vault is chosen in one place — Field Assist settings — and this links
            // there rather than growing a second picker that could disagree with it.
            NavigationLink {
                FieldAssistSettingsView()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vault in use")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                        Text(empty.vaultName)
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                    }
                    Spacer()
                    Text("Change")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                .padding(.vertical, 2)
            }
            .accessibilityLabel("Vault in use, \(empty.vaultName)")
            .accessibilityHint("Opens Field Assist settings, where the default vault is chosen.")
        } footer: {
            Text("The manuals and procedures a new job is grounded in. A job keeps the vault it started on until you finish it.")
        }
    }

    // MARK: - The site (Plan MD)

    private var siteSection: some View {
        Section {
            Button { choosingSite = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Site")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                        Text(sitePick?.rowLabel ?? String(localized: "None chosen"))
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(sitePick == nil ? "Choose" : "Change")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sitePick.map { String(localized: "Site, \($0.rowLabel)") }
                                ?? String(localized: "Site, none chosen"))
            .accessibilityHint("Opens today's jobs, the vault's documented sites and recent sites to choose from.")

            if let pick = sitePick, pick.canAttachDocument, !documentedSites.isEmpty {
                Button { choosingDocument = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Documented site")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                            Text(pick.siteLabel ?? String(localized: "None"))
                                .foregroundStyle(Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(pick.siteDocumentId == nil ? "Choose" : "Change")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(minHeight: OGMetrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Documented site, \(pick.siteLabel ?? String(localized: "none"))"))
                .accessibilityHint("Chooses which of the vault's documented sites this job is at, so its units come with it.")
            }

            if let pick = sitePick, pick.canRememberClient {
                Toggle(isOn: Binding(get: { sitePick?.remembersClient ?? false },
                                     set: { sitePick?.remembersClient = $0 })) {
                    Text("Remember this site for this Workiz client")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
                .accessibilityHint("Their next Workiz jobs start at \(pick.siteLabel ?? "this site") without choosing it again. Kept on this phone only.")
            }

            if sitePick != nil {
                Button {
                    replacePick(with: nil)
                } label: {
                    Text("No site")
                        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                }
                .accessibilityHint("Clears the site. The job starts without one, as it always has.")
            }
        } footer: {
            Text(siteFooter)
        }
    }

    private var siteFooter: String {
        if sitePick?.canRememberClient == true {
            return String(localized: "This phone remembers the site for the client's next jobs. Nothing is sent to Workiz, and you can forget it in Workiz settings.")
        }
        return String(localized: "Optional. A documented site brings its units, so the assistant knows the machines there before you name one.")
    }

    /// A row chosen in the picker. Today's job brings its number into the field.
    private func choose(_ choice: NewJobSiteChoice) {
        replacePick(with: NewJobSitePick(choice))
    }

    private func replacePick(with pick: NewJobSitePick?) {
        // A number that came with the previous job goes with it; one typed by hand stays.
        if let previous = sitePick, previous.kind == .scheduledJob,
           JobIntakeState.cleaned(typedReference) == previous.jobReference {
            typedReference = ""
        }
        if let pick, pick.kind == .scheduledJob, let number = pick.jobReference { typedReference = number }
        sitePick = pick
    }

    // MARK: - Starting one

    private var startSection: some View {
        Section {
            TextField(text: $typedReference) {
                Text("Job number (optional)")
            }
            .focused($referenceFocused)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { referenceFocused = false }
            .accessibilityLabel("Job number")
            .accessibilityHint("Optional. Leave it empty and you'll be asked for it out loud once the job starts.")

            Button(action: onStart) {
                Text("Start job")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.ogProminent)
            .disabled(!empty.canStart)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityHint(startHint)

            if let reason = empty.startBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(OGTheme.warnLabel)
            }
        } header: {
            Text("Start now")
        } footer: {
            Text("You can also just say it — \u{201C}start a job\u{201D} — and the number will be asked for and read back to you.")
        }
    }

    private var startHint: String {
        switch (sitePick?.rowLabel, typedReference.isEmpty) {
        case (nil, true):
            return String(localized: "Starts a job on \(empty.vaultName). You'll be asked for the job number.")
        case (nil, false):
            return String(localized: "Starts a job on \(empty.vaultName), filed under \(typedReference).")
        case (let site?, true):
            return String(localized: "Starts a job on \(empty.vaultName) at \(site). You'll be asked for the job number.")
        case (let site?, false):
            return String(localized: "Starts a job on \(empty.vaultName) at \(site), filed under \(typedReference).")
        }
    }

    // MARK: - Or later

    private var scheduleSection: some View {
        Section {
            Button(action: onSchedule) {
                Label(OpenJobPrompt.scheduleTitle, systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
            .accessibilityHint("Adds a job you haven't started yet to Scheduled, with its site and booking.")
        } header: {
            Text("Later")
        } footer: {
            Text("You can also say \u{201C}next job: 1007, no heat, Smith Street\u{201D}, or open a job file the office emailed you.")
        }
    }
}

// MARK: - The site picker (Plan MD §2)

/// One searchable list: today's jobs, the vault's documented sites, recent sites, and a new site
/// typed in. Choosing a row closes it.
struct NewJobSitePicker: View {
    let choices: [NewJobSiteChoice]
    let title: LocalizedStringKey
    let offersNewSite: Bool
    let onChoose: (NewJobSiteChoice) -> Void
    let onNewSite: ((JobSite) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let shown = NewJobSiteChoices.filter(choices, query: query)
            List {
                section(shown, .scheduledJob, header: "Today's jobs")
                section(shown, .documentedSite, header: "Documented sites")
                section(shown, .recentSite, header: "Recent sites")
                if shown.isEmpty {
                    Section {
                        Text(query.isEmpty ? String(localized: "Nothing to choose from yet.")
                                           : String(localized: "No site matches \u{201C}\(query)\u{201D}."))
                            .foregroundStyle(Color.secondary)
                    }
                }
                if offersNewSite, let onNewSite {
                    Section {
                        NavigationLink {
                            NewJobNewSiteForm { site in
                                onNewSite(site)
                                dismiss()
                            }
                        } label: {
                            Label("A new site", systemImage: "plus")
                                .frame(minHeight: OGMetrics.minTouchTarget)
                        }
                        .accessibilityHint("Type the customer and address for a site this phone hasn't been to.")
                    }
                }
            }
            .ogFormStyle()
            .searchable(text: $query, prompt: Text("Customer, address or site"))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ shown: [NewJobSiteChoice], _ source: NewJobSiteChoice.Source,
                         header: LocalizedStringKey) -> some View {
        let rows = shown.filter { $0.source == source }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { choice in
                    Button {
                        onChoose(choice)
                        dismiss()
                    } label: {
                        row(choice)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(Self.hint(choice))
                }
            } header: {
                Text(header)
            }
        }
    }

    private func row(_ choice: NewJobSiteChoice) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = choice.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let time = choice.scheduledFor {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        .contentShape(Rectangle())
    }

    private static func hint(_ choice: NewJobSiteChoice) -> String {
        switch choice.source {
        case .scheduledJob:
            return String(localized: "Start job then starts this scheduled job, with its number, site and notes.")
        case .documentedSite:
            return String(localized: "The job starts at this site, and the assistant is told its units.")
        case .recentSite:
            return String(localized: "The job is filed under this customer and address.")
        }
    }
}

/// A site this phone has not been to: the same customer, address and contact fields as
/// scheduling a job for later. Every field optional; nothing is filled in.
struct NewJobNewSiteForm: View {
    let onUse: (JobSite) -> Void

    @State private var customer = ""
    @State private var address = ""
    @State private var contact = ""

    private var site: JobSite { JobSite(customer: customer, address: address, contact: contact) }

    var body: some View {
        Form {
            Section {
                TextField("Customer", text: $customer)
                TextField("Address", text: $address, axis: .vertical)
                TextField("Contact", text: $contact)
            } footer: {
                Text("Kept as you type it. The job's report and its history use it.")
            }
        }
        .ogFormStyle()
        .navigationTitle("A new site")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Use") { onUse(site) }
                    .disabled(site.isEmpty)
            }
        }
    }
}
