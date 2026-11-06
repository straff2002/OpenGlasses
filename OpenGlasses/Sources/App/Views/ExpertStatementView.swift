import SwiftUI

/// Settings › Field Assist › Experts › Statements (Plan KM §6, P4): each expert's month, one row
/// per job, with the rate and the amount for a contracted expert and a total, exported as CSV or
/// PDF for the organisation's records.
///
/// **The device owner's, and only on a phone with no profile** (decision 6): this is the one place
/// a rate and an amount appear. Under a profile the office keeps statements, and the technician's
/// phone shows minutes only. The amount is a figure: the app never takes or sends a payment.
struct ExpertStatementView: View {
    @ObservedObject private var sessions = FieldSessionService.shared
    private let list = ExpertListStore.shared
    private let calendar = Calendar.current

    @State private var expertId: String?
    @State private var sharing: ShareItem?
    @State private var problem: String?

    private var jobs: [FieldSession] {
        (sessions.activeSession.map { [$0] } ?? []) + sessions.history
    }

    var body: some View {
        let experts = ExpertStatement.experts(in: jobs)
        Form {
            if experts.isEmpty {
                Section {
                    Text("Statements appear once an expert's time is on a job: their time reply, or a call to them this phone saw.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Picker("Expert", selection: selection(experts)) {
                        ForEach(experts, id: \.id) { expert in
                            Text(CoachingCredit.text(name: expert.name, kind: expert.kind)).tag(Optional(expert.id))
                        }
                    }
                } footer: {
                    Text("One row per job: the expert's time reply, checked against the call this phone saw, with any difference shown and never settled. A contracted expert's amount is figured at the rate on your list now. The app never takes or sends a payment.")
                }
                if let id = expertId ?? experts.first?.id, let expert = experts.first(where: { $0.id == id }) {
                    ForEach(ExpertStatement.months(expertId: id, sessions: jobs, calendar: calendar)) { month in
                        monthSection(statement(expert, month: month))
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
        .navigationTitle("Statements")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
    }

    private func selection(_ experts: [ExpertSnapshot]) -> Binding<String?> {
        Binding(get: { expertId ?? experts.first?.id }, set: { expertId = $0 })
    }

    private func statement(_ expert: ExpertSnapshot, month: CalendarMonth) -> ExpertStatement {
        let name = Config.organizationDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExpertStatement.build(expert: expert, listed: list.organizationExperts.first { $0.id == expert.id },
                                     month: month, sessions: jobs, organisation: name.isEmpty ? nil : name,
                                     calendar: calendar, preparedAt: Date())
    }

    @ViewBuilder
    private func monthSection(_ statement: ExpertStatement) -> some View {
        let document = statement.document(calendar: calendar)
        Section {
            ForEach(Array(document.rows.enumerated()), id: \.offset) { _, row in
                Text(document.rowLine(row))
                    .font(.footnote)
            }
            if let total = document.total {
                Text(document.rowLine(total))
                    .font(.footnote.weight(.semibold))
            }
            Button {
                export(statement, format: .csv)
            } label: {
                Label("Export CSV", systemImage: "tablecells")
            }
            Button {
                export(statement, format: .pdf)
            } label: {
                Label("Export PDF", systemImage: "doc.richtext")
            }
        } header: {
            Text(statement.month.title)
        }
    }

    private func export(_ statement: ExpertStatement, format: ExpertStatementExport.Format) {
        do {
            let lease = try ExpertStatementExport.stage(statement, format: format, calendar: calendar)
            problem = nil
            let coordinator = StagedExportCoordinator.fieldSession
            coordinator.beginShare(lease)
            let item = ProtectedExportActivityItem(fileURL: lease.fileURL, displayName: lease.displayName)
            sharing = ShareItem(items: [item]) { completed in
                coordinator.finishShare(lease, outcome: completed ? .completed : .cancelled)
            }
        } catch {
            problem = String(localized: "The statement couldn't be written on this phone. Try again.")
        }
    }
}
