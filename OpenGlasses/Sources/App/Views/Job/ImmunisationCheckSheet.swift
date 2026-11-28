import SwiftUI
import UniformTypeIdentifiers

/// The check against the EMR on the Stock screen (Plan MY §8): pick the EMR's exported list, choose
/// once which columns hold the date, the vaccine and the lot, and see which counts differ.
///
/// Only while medical mode is on. The file is read where it is, in memory, and forgotten: it is
/// never copied into the app, and nothing from a column other than those three is read. The
/// result says which counts differ on which day, never which patient; finding the patient is done
/// in the EMR, by the people allowed to.
@MainActor
struct ImmunisationCheckSheet: View {
    @ObservedObject var store: VanStockStore
    var checker: ImmunisationCheckService = .shared

    @Environment(\.dismiss) private var dismiss

    @State private var picking = false
    /// Where the chosen file is. Its contents are read when needed and never kept.
    @State private var file: URL?
    @State private var format: ImmunisationListReader.Format?
    @State private var header: [String] = []
    @State private var mapping = ImmunisationColumnMapping(date: "", vaccine: "", lot: "")
    @State private var mappingConfirmed = false
    @State private var outcome: ImmunisationCheckService.Outcome?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if !checker.isAllowed {
                    Section {
                        Text(verbatim: ImmunisationCheckService.medicalModeRefusal)
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
                    Text("This is a stock record, not the immunisation record. The list is read on this phone and not kept; only the counts of each difference are.")
                }
            }
            .ogFormStyle()
            .navigationTitle("Check against the EMR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.types) { result in
                guard case .success(let url) = result else { return }
                choose(url)
            }
        }
    }

    static var types: [UTType] {
        [UTType(filenameExtension: "xlsx"), UTType.commaSeparatedText, UTType.plainText].compactMap { $0 }
    }

    // MARK: - The file

    private var fileSection: some View {
        Section {
            Button(file == nil ? "Choose the EMR's list…" : "Choose another list…") { picking = true }
            if let problem {
                Label {
                    Text(verbatim: problem)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
            }
        } footer: {
            Text("Export the immunisations given for a range of days from the EMR, as a spreadsheet (.xlsx) or a CSV file. Only the date, vaccine and lot columns are read.")
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
        switch Self.contents(of: url) {
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
            if let remembered = ImmunisationColumnMapping.stored(), remembered.fits(names) {
                mapping = remembered
                mappingConfirmed = true
                run()
            } else {
                mapping = ImmunisationColumnMapping(date: header.first ?? "", vaccine: header.first ?? "",
                                                    lot: header.first ?? "")
                mappingConfirmed = false
            }
        }
    }

    /// The file's bytes, read where the file is and never written anywhere. A file over the
    /// reader's size limit is refused before any of it is loaded. The billing check reads its
    /// export the same way (`BillingCheckSheet`).
    static func contents(of url: URL) -> Result<Data, ImmunisationListReader.Failure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > CSVReader.maximumFileBytes {
            return .failure(.tooLarge)
        }
        guard let data = try? Data(contentsOf: url, options: [.uncached]) else { return .failure(.unreadable) }
        return .success(data)
    }

    // MARK: - The columns

    private var mappingSection: some View {
        Section {
            Picker("Date given", selection: $mapping.date) {
                ForEach(header, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Picker("Vaccine or product code", selection: $mapping.vaccine) {
                ForEach(header, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Picker("Lot", selection: $mapping.lot) {
                ForEach(header, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Picker("Dates are written", selection: $mapping.dateOrder) {
                Text("Day first (24/11/2026)").tag(ImmunisationColumnMapping.DateOrder.dayMonthYear)
                Text("Month first (11/24/2026)").tag(ImmunisationColumnMapping.DateOrder.monthDayYear)
            }
            Button("Check") {
                mappingConfirmed = true
                run()
            }
            .disabled(Set([mapping.date, mapping.vaccine, mapping.lot]).count < 3)
        } header: {
            Text("Which columns to read")
        } footer: {
            Text("Chosen once and remembered: the column names only. Every other column is left unread.")
        }
    }

    private func run() {
        guard let file, let format else {
            problem = ImmunisationListReader.Failure.unreadable.sentence
            return
        }
        let data: Data
        switch Self.contents(of: file) {
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
    private func outcomeSections(_ outcome: ImmunisationCheckService.Outcome) -> some View {
        switch outcome {
        case .refused(let sentence), .failed(let sentence):
            Section {
                Text(verbatim: sentence)
            }
        case .done(let result, let skipped):
            let wording = ImmunisationFindingWording(items: store.log.items)
            Section {
                Text(verbatim: wording.summary(result))
                if skipped > 0 {
                    (skipped == 1 ? Text("1 row had no readable date or vaccine and was left out.")
                                  : Text("\(skipped) rows had no readable date or vaccine and were left out."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !result.unmatchedVaccines.isEmpty {
                Section {
                    ForEach(result.unmatchedVaccines, id: \.vaccine) { entry in
                        Menu {
                            ForEach(store.log.items) { item in
                                Button(item.name) {
                                    if checker.match(vaccine: entry.vaccine, to: item.id) { run() }
                                }
                            }
                        } label: {
                            LabeledContent {
                                entry.rows == 1 ? Text("1 row") : Text("\(entry.rows) rows")
                            } label: {
                                Text(verbatim: entry.vaccine)
                            }
                        }
                    }
                } header: {
                    Text("Vaccines to match to a line")
                } footer: {
                    Text("Tap a vaccine as the EMR names it and choose its line. It is remembered for the next check.")
                }
            }
            if !result.findings.isEmpty {
                Section {
                    ForEach(Array(result.findings.enumerated()), id: \.offset) { _, finding in
                        Text(verbatim: wording.sentence(finding))
                    }
                } header: {
                    Text("To look at in the EMR")
                } footer: {
                    Text("Fix a missing or wrong entry in the EMR itself. Nothing here is written to the EMR.")
                }
            }
        }
    }
}
