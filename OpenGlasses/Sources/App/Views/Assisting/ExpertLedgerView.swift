import SwiftUI

/// Assisting › Your Time (Plan KM §7, P4): the expert's own ledger — the time replies they sent,
/// by organisation and month — exported one organisation at a time as CSV or PDF, so they can
/// invoice each company from their own record.
///
/// Minutes only: the expert's side never has an organisation's rate. One organisation is chosen
/// at a time, and nothing here shows two side by side or searches across them.
struct ExpertLedgerView: View {
    let service: AssistingService
    @ObservedObject private var ledgerStore: ExpertLedgerStore

    @State private var organisation: String?
    @State private var sharing: ShareItem?
    @State private var problem: String?

    private let calendar = Calendar.current

    init(service: AssistingService) {
        self.service = service
        _ledgerStore = ObservedObject(wrappedValue: service.ledger)
    }

    var body: some View {
        let ledger = ledgerStore.ledger
        Form {
            if ledger.organisations.isEmpty {
                Section {
                    Text("Your time appears here, by organisation and month, once you've sent a time reply.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Picker("Organisation", selection: selection(ledger)) {
                        ForEach(ledger.organisations) { organisation in
                            Text(organisation.name.isEmpty ? String(localized: "Sender not named") : organisation.name)
                                .tag(Optional(organisation.id))
                        }
                    }
                } footer: {
                    Text("One organisation at a time: each export holds only that organisation's jobs. Minutes only; your rate is agreed with each organisation and kept on their statement.")
                }
                if let key = organisation ?? ledger.organisations.first?.id {
                    ForEach(ledger.months(organisation: key, calendar: calendar)) { month in
                        monthSection(ledger, key: key, month: month)
                    }
                }
            }
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .ogFormStyle()
        .navigationTitle("Your Time")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
    }

    private func selection(_ ledger: ExpertLedger) -> Binding<String?> {
        Binding(get: { organisation ?? ledger.organisations.first?.id },
                set: { organisation = $0 })
    }

    @ViewBuilder
    private func monthSection(_ ledger: ExpertLedger, key: String, month: CalendarMonth) -> some View {
        let rows = ledger.rows(organisation: key, month: month, calendar: calendar)
        Section {
            ForEach(rows) { entry in
                LabeledContent(entry.jobReference.map { String(localized: "Job \($0)") } ?? String(localized: "Job"),
                               value: String(localized: "\(entry.minutes) min"))
            }
            LabeledContent("Total", value: String(localized: "\(ledger.totalMinutes(organisation: key, month: month, calendar: calendar)) min"))
            Button {
                export(key: key, month: month, pdf: false)
            } label: {
                Label("Export CSV", systemImage: "tablecells")
            }
            Button {
                export(key: key, month: month, pdf: true)
            } label: {
                Label("Export PDF", systemImage: "doc.richtext")
            }
        } header: {
            Text(month.title)
        }
    }

    private func export(key: String, month: CalendarMonth, pdf: Bool) {
        switch service.stageLedger(organisation: key, month: month, pdf: pdf, calendar: calendar) {
        case .failure(let refusal):
            problem = refusal.message
        case .success(let staged):
            problem = nil
            service.beginShare(staged)
            let item = ProtectedExportActivityItem(fileURL: staged.lease.fileURL, displayName: staged.lease.displayName)
            sharing = ShareItem(items: [item]) { completed in
                service.finishShare(staged, completed: completed)
            }
        }
    }
}
