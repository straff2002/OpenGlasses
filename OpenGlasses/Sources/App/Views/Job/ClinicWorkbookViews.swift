import SwiftUI

/// The clinic's shared count on a clinical list's Stock screen (Plan NK P1): the workbook's figure
/// beside the phone's own, a "differs" line, Send to the clinic's workbook, and when rows last went.
/// It never changes either figure.
struct ClinicWorkbookStockSection: View {
    @ObservedObject var service: ClinicWorkbookService
    let onSetUp: () -> Void

    @Environment(\.locale) private var locale
    @State private var sending = false
    @State private var queuedNow: Int?

    /// The screen reads the workbook on opening at most every ten minutes.
    static let readInterval: TimeInterval = 600

    var body: some View {
        Section {
            if service.gate.allows {
                connected
            } else {
                if let sentence = service.gate.sentence {
                    Text(verbatim: sentence).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Set up the clinic's workbook…", action: onSetUp)
            }
        } header: {
            Text("Clinic's workbook")
        } footer: {
            if service.gate.allows {
                Text("The clinic's count is the rows every phone has added, read back from the workbook. Rows are sent at the end of the daily check, when you send them, and on the first launch of a day.")
            }
        }
        .task {
            guard service.gate.allows else { return }
            if service.lastReadAt.map({ Date().timeIntervalSince($0) > Self.readInterval }) ?? true {
                await service.refresh()
            }
        }
    }

    @ViewBuilder
    private var connected: some View {
        if let name = service.record?.workbookName {
            LabeledContent("Workbook") { Text(verbatim: name) }
        }
        if let sent = service.record?.lastSentAt {
            LabeledContent("Last sent") { Text(sent, style: .relative) }
        } else {
            LabeledContent("Last sent") { Text("Not yet") }
        }
        if service.rowsQueued > 0 {
            Text("\(service.rowsQueued) rows waiting to go").font(.footnote).foregroundStyle(.secondary)
        }
        if let comparison = service.comparison {
            if comparison.lines.isEmpty {
                Text("Nothing in the workbook yet.").font(.footnote).foregroundStyle(.secondary)
            } else if comparison.differing == 0 {
                Label("The clinic's count matches this phone's.", systemImage: "checkmark.circle")
                    .font(.footnote)
            }
            ForEach(comparison.lines) { line in
                ClinicWorkbookLineRow(line: line, locale: locale)
            }
            if service.skippedRows > 0 {
                Text("\(service.skippedRows) rows in the workbook couldn't be read and were left out.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if let problem = service.problem {
            Text(verbatim: problem).font(.footnote).foregroundStyle(OGTheme.errorLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button {
            sending = true
            Task {
                queuedNow = await service.send(.onDemand)
                sending = false
            }
        } label: {
            Label("Send to the clinic's workbook", systemImage: "arrow.up.doc")
        }
        .disabled(sending || service.busy)
        if let queuedNow {
            (queuedNow == 0 ? Text("Nothing new to send.") : Text("\(queuedNow) rows queued for the workbook."))
                .font(.footnote).foregroundStyle(.secondary)
        }
        Button("Workbook settings…", action: onSetUp)
    }
}

/// One line: the phone's figure, the workbook's, and how they differ, with any lot that differs.
private struct ClinicWorkbookLineRow: View {
    let line: ClinicalStockComparison.Line
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: line.name).font(.body)
            Text("Here \(figure(line.own)) · Workbook \(figure(line.shared))")
                .font(.footnote).foregroundStyle(.secondary)
            if let sentence = ClinicalStockComparison.sentence(line.verdict) {
                Text(verbatim: sentence).font(.footnote).foregroundStyle(.orange)
            }
            ForEach(line.lots) { lot in
                if let sentence = ClinicalStockComparison.sentence(lot.verdict), lot.verdict != .notShared {
                    Text("Lot \(lot.code): \(sentence)").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func figure(_ quantity: StockQuantity?) -> String {
        quantity.map { $0.formatted(locale: locale) } ?? "–"
    }
}

/// Connecting a clinical list to the clinic's workbook (Plan NK P1): sign in to the clinic's
/// Microsoft 365, paste the workbook's sharing link, and the app makes its two tables if they are
/// missing. Says who has to consent, and what they will see.
struct ClinicWorkbookSettingsView: View {
    @ObservedObject var service: ClinicWorkbookService
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var clientID = ""
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                if service.gate == .notClinical {
                    Section {
                        Text(verbatim: ClinicStockRouteGate.notClinical.sentence ?? "")
                    }
                } else {
                    signInSection
                    if service.record != nil { workbookSection }
                    if let problem = service.problem {
                        Section {
                            Text(verbatim: problem).foregroundStyle(OGTheme.errorLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    clientSection
                }
            }
            .ogFormStyle()
            .navigationTitle("Clinic's workbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { clientID = service.clinicClientID }
            .confirmationDialog("Sign out of the clinic's Microsoft 365?", isPresented: $confirmingSignOut,
                                titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { service.signOut() }
                Button("Stay signed in", role: .cancel) {}
            } message: {
                Text("Rows waiting to go are sent with the next send after you sign in again. Nothing in the workbook changes.")
            }
        }
    }

    private var signInSection: some View {
        Section {
            if let record = service.record {
                if let account = record.account {
                    LabeledContent("Signed in as") { Text(verbatim: account) }
                } else {
                    Text("Signed in")
                }
                if let notice = service.notice?.sentence {
                    Label { Text(verbatim: notice) } icon: { Image(systemName: "globe") }
                        .font(.footnote)
                }
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
            } else if service.client == .notSetUp {
                Text(verbatim: ClinicStockRouteGate.notSetUp.sentence ?? "")
            } else {
                Button("Sign in to Microsoft 365") { Task { await service.signIn() } }
                    .disabled(service.busy)
            }
        } header: {
            Text("Microsoft 365")
        } footer: {
            Text("Your clinic's Microsoft 365 administrator approves the app once. They'll see that it asks to sign you in, read your profile and your organisation's country, and read and write files you can open. The app itself reads and adds to only the one workbook you choose. Your sign-in stays on this phone, and nothing passes through us.")
        }
    }

    private var workbookSection: some View {
        Section {
            if let name = service.record?.workbookName {
                LabeledContent("Workbook") { Text(verbatim: name) }
            }
            TextField("Paste the workbook's sharing link", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button(service.record?.workbook == nil ? LocalizedStringKey("Use this workbook")
                                                   : LocalizedStringKey("Use this workbook instead")) {
                Task { if await service.choose(link: link) { link = "" } }
            }
            .disabled(service.busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Workbook")
        } footer: {
            Text("Create a workbook in the clinic's Microsoft 365, choose Share in Excel and copy the link. The app adds two tables if they are missing: Movements, one row per day, line, lot and kind, and Counts. They hold no staff, no times and nothing about a patient.")
        }
    }

    private var clientSection: some View {
        Section {
            TextField("Client ID", text: $clientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            Button("Save client ID") { service.setClinicClientID(clientID) }
                .disabled(clientID == service.clinicClientID)
        } header: {
            Text("The clinic's own app registration")
        } footer: {
            Text("Only for a clinic that registered its own app in Microsoft 365. Leave it empty to use the app's own. The redirect address to register is \(EntraOAuth.redirectURI).")
        }
    }
}
