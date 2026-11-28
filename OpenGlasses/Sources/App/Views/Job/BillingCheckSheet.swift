import SwiftUI
import UniformTypeIdentifiers

/// The check against the billing export on the Stock screen (Plan NJ §4, MY Decision 13): pick the
/// EMR's billing export, choose which columns hold the date and the tariff (and the lot, when it
/// has one), and see which doses given here were not billed and which claims have no dose here.
///
/// Built like the check against the EMR (`ImmunisationCheckSheet`) and gated the same way: only
/// while medical mode is on, because the export holds patient details. The file is read where it
/// is, in memory, and forgotten; only the mapped columns are read, and unlike the EMR check
/// nothing is remembered, not the column names and not a summary (`BillingCheckService`). A tariff
/// several lines carry is reported as billed under a shared code and never assigned to one.
@MainActor
struct BillingCheckSheet: View {
    @ObservedObject var store: VanStockStore
    var checker: BillingCheckService = .shared

    @Environment(\.dismiss) private var dismiss

    @State private var picking = false
    /// Where the chosen file is. Its contents are read when needed and never kept.
    @State private var file: URL?
    @State private var format: ImmunisationListReader.Format?
    @State private var header: [String] = []
    @State private var mapping = BillingColumnMapping(date: "", tariff: "", lot: nil)
    @State private var mappingConfirmed = false
    @State private var outcome: BillingCheckService.Outcome?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if !checker.isAllowed {
                    Section {
                        Text(verbatim: BillingCheckService.medicalModeRefusal)
                    }
                } else {
                    fileSection
                    if file != nil, !header.isEmpty, !mappingConfirmed {
                        mappingSection
                    }
                    if let outcome {
                        outcomeSections(outcome)
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("This is a stock record, not the billing record. The export is read on this phone and not kept.")
                }
            }
            .ogFormStyle()
            .navigationTitle("Check against billing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: ImmunisationCheckSheet.types) { result in
                guard case .success(let url) = result else { return }
                choose(url)
            }
        }
    }

    // MARK: - The file

    private var fileSection: some View {
        Section {
            Button(file == nil ? "Choose the billing export…" : "Choose another export…") { picking = true }
            if let problem {
                Label {
                    Text(verbatim: problem)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
            }
        } footer: {
            Text("Export the claims billed for a range of days from the EMR, as a spreadsheet (.xlsx) or a CSV file. Only the date, tariff and lot columns are read.")
        }
    }

    private func choose(_ url: URL) {
        problem = nil
        outcome = nil
        guard let format = ImmunisationListReader.Format(fileName: url.lastPathComponent) else {
            problem = ImmunisationListReader.Failure.unreadable.sentence
            return
        }
        let data: Data
        switch ImmunisationCheckSheet.contents(of: url) {
        case .success(let read): data = read
        case .failure(let failure):
            problem = failure.sentence
            return
        }
        switch checker.header(data, format: format) {
        case .failure(let refusal):
            problem = refusal.sentence
        case .success(let names):
            file = url
            self.format = format
            header = names.filter { !$0.isEmpty }
            // Nothing is remembered from one check to the next, so the columns are chosen each time.
            mapping = BillingColumnMapping(date: header.first ?? "", tariff: header.first ?? "", lot: nil)
            mappingConfirmed = false
        }
    }

    // MARK: - The columns

    private var mappingSection: some View {
        Section {
            Picker("Date billed", selection: $mapping.date) {
                ForEach(header, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Picker("Tariff", selection: $mapping.tariff) {
                ForEach(header, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Picker("Lot", selection: $mapping.lot) {
                Text("No lot column").tag(String?.none)
                ForEach(header, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
            }
            Picker("Dates are written", selection: $mapping.dateOrder) {
                Text("Day first (24/11/2026)").tag(ImmunisationColumnMapping.DateOrder.dayMonthYear)
                Text("Month first (11/24/2026)").tag(ImmunisationColumnMapping.DateOrder.monthDayYear)
            }
            Button("Check") {
                mappingConfirmed = true
                run()
            }
            .disabled(!mapping.isChoosable)
        } header: {
            Text("Which columns to read")
        } footer: {
            Text("Every other column is left unread. Without a lot column, doses are compared by day and line.")
        }
    }

    private func run() {
        guard let file, let format else {
            problem = ImmunisationListReader.Failure.unreadable.sentence
            return
        }
        let data: Data
        switch ImmunisationCheckSheet.contents(of: file) {
        case .success(let read): data = read
        case .failure(let failure):
            problem = failure.sentence
            return
        }
        outcome = checker.check(data, format: format, mapping: mapping)
        if case .failed = outcome { mappingConfirmed = false }
    }

    // MARK: - The result

    @ViewBuilder
    private func outcomeSections(_ outcome: BillingCheckService.Outcome) -> some View {
        switch outcome {
        case .refused(let sentence), .failed(let sentence):
            Section {
                Text(verbatim: sentence)
            }
        case .done(let result, let skipped):
            let wording = BillingFindingWording(items: store.log.items)
            Section {
                Text(verbatim: wording.summary(result))
                if skipped > 0 {
                    (skipped == 1 ? Text("1 row had no readable date or tariff and was left out.")
                                  : Text("\(skipped) rows had no readable date or tariff and were left out."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !result.sharedCodes.isEmpty {
                Section {
                    ForEach(result.sharedCodes, id: \.tariff) { shared in
                        Text(verbatim: wording.sentence(shared))
                    }
                } header: {
                    Text("Billed under a shared code")
                } footer: {
                    Text("A tariff that more than one line carries is never counted against one of them. Staff decide which line each claim was.")
                }
            }
            if !result.reconciliation.unmatchedVaccines.isEmpty {
                Section {
                    ForEach(result.reconciliation.unmatchedVaccines, id: \.vaccine) { entry in
                        LabeledContent {
                            entry.rows == 1 ? Text("1 row") : Text("\(entry.rows) rows")
                        } label: {
                            Text(verbatim: entry.vaccine)
                        }
                    }
                } header: {
                    Text("Tariffs on no line")
                } footer: {
                    Text("A tariff finds its line by the line's number. Give the line that number on its page, then check again.")
                }
            }
            if !result.reconciliation.findings.isEmpty {
                Section {
                    ForEach(Array(result.reconciliation.findings.enumerated()), id: \.offset) { _, finding in
                        Text(verbatim: wording.sentence(finding))
                    }
                } header: {
                    Text("To look at in the EMR")
                } footer: {
                    Text("Fix a missed or wrong claim in the EMR itself. Nothing here is written to the EMR.")
                }
            }
        }
    }
}
