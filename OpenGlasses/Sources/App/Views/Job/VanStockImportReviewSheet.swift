import SwiftUI

/// A workbook, read and not yet applied (Plan IH §6).
///
/// Everything the import would do is on this sheet before anything is written: counts, new lines,
/// changed details, lines the sheet no longer has, and rows that were refused. One button applies
/// all of it as a single batch, so one Undo on the Van Stock screen takes it back. Its sentences
/// name no place (Plan MK §3); only the takeover choice follows the place.
struct VanStockImportReviewSheet: View {
    @ObservedObject var service: VanStockImportService
    /// Called after the import was applied.
    let onApplied: () -> Void

    /// Lines that moved on the phone after the workbook was written, where the technician chose
    /// to keep the phone's figure. The sheet's figure is the default.
    @State private var keepingPhoneFigure: Set<String> = []
    /// How the workbook is being applied. Nil until the review appears, then the suggested way.
    @State private var chosenMode: VanStockImportService.Mode?
    /// Lines whose standard this truck set itself, where the technician chose base's figure.
    @State private var takingBaseFigure: Set<String> = []

    private var mode: VanStockImportService.Mode { chosenMode ?? service.suggestedMode }

    @Environment(\.locale) private var locale

    /// A figure in the locale's form: "4,25" in German.
    private func figure(_ quantity: StockQuantity) -> String { quantity.formatted(locale: locale) }

    /// The place a takeover would leave this phone's list in: the profile's, or else the
    /// workbook's, or else the list's own (Plan MK §2).
    private var takeoverKind: StockPlace.Kind {
        StockPlaceSetting.current(list: service.takeover?.van?.place ?? VanStockStore.shared.van?.place).kind
    }

    var body: some View {
        NavigationStack {
            Group {
                switch service.stage {
                case .idle:
                    EmptyView()
                case .refused(let refusal):
                    refusedView(refusal)
                case .reviewing(let proposal, let fileName):
                    reviewList(proposal, fileName: fileName)
                }
            }
            .navigationTitle("Spreadsheet import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { service.dismiss() }
                }
                if case .reviewing(let proposal, _) = service.stage {
                    ToolbarItem(placement: .confirmationAction) {
                        switch mode {
                        case .corrections:
                            Button("Apply") {
                                if service.apply(keepingPhoneFigure: keepingPhoneFigure) { onApplied() }
                            }
                            .disabled(proposal.changesNothing)
                        case .takeover:
                            Button("Take over") {
                                if service.applyTakeover() { onApplied() }
                            }
                        case .baseline:
                            Button("Apply") {
                                if service.applyBaseline(takingBaseFigure: takingBaseFigure) { onApplied() }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Refused

    private func refusedView(_ refusal: VanStockImportService.Refusal) -> some View {
        List {
            Section {
                Label {
                    refusalText(refusal)
                } icon: {
                    Image(systemName: refusal == .nothingToChange ? "checkmark.circle" : "exclamationmark.triangle")
                }
            } footer: {
                Text("Nothing on the list was changed.")
            }
        }
        .ogFormStyle()
    }

    private func refusalText(_ refusal: VanStockImportService.Refusal) -> Text {
        switch refusal {
        case .fieldAssistOff:
            return Text("Field Assist is off, so there is no stock list to import into.")
        case .switchedOffByOrganisation:
            return Text("Your organisation has switched the stock list off on this phone.")
        case .listUnreadable:
            return Text("The list on this phone can't be read. Start it again from the Stock screen first.")
        case .fileUnreadable:
            return Text("That file couldn't be read.")
        case .workbook(.notAWorkbook):
            return Text("That isn't a spreadsheet this can read. Save it as an Excel workbook (.xlsx) with no password.")
        case .workbook(.tooLarge):
            return Text("That spreadsheet is too large to import.")
        case .workbook(.macros):
            return Text("That spreadsheet contains macros, so it wasn't opened. Save it as an ordinary workbook (.xlsx).")
        case .workbook(.tooManyRows):
            return Text("That spreadsheet has more than 5,000 rows.")
        case .noRecognisableHeader:
            return Text("That spreadsheet has no header row this recognises. It needs Part number or Description, and On hand. A list with no quantities yet needs both Part number and Description.")
        case .nothingToChange:
            return Text("That spreadsheet matches the list already. There is nothing to import.")
        case .heldBySystem(let system):
            return Text(verbatim: VanStockImportService.Refusal.heldBySystemSentence(system))
        }
    }

    // MARK: - Review

    @ViewBuilder
    private func reviewList(_ proposal: VanStockSheet.Proposal, fileName: String) -> some View {
        List {
            if service.takeover != nil || service.baseline != nil {
                Section {
                    Picker("Use this spreadsheet as", selection: Binding(get: { mode }, set: { chosenMode = $0 })) {
                        if service.takeover != nil {
                            Text(StockPlaceScreenText.takeOver(takeoverKind)).tag(VanStockImportService.Mode.takeover)
                        }
                        Text("Corrections to my list").tag(VanStockImportService.Mode.corrections)
                        if service.baseline != nil { Text("Standards from the office").tag(VanStockImportService.Mode.baseline) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Use this spreadsheet as")
                }
            }
            switch mode {
            case .takeover:
                if let takeover = service.takeover { takeoverSections(takeover, fileName: fileName) }
            case .baseline:
                if let baseline = service.baseline { baselineSections(baseline, fileName: fileName) }
            case .corrections:
                correctionSections(proposal, fileName: fileName)
            }
        }
        .ogFormStyle()
    }

    // MARK: - Taking a van over

    @ViewBuilder
    private func takeoverSections(_ takeover: VanStockHandover.Takeover, fileName: String) -> some View {
        Section {
            Text(takeover.van?.name.isEmpty == false ? takeover.van?.name ?? "" : fileName)
                .font(.headline)
            if let exportedAt = takeover.exportedAt {
                LabeledContent("As it was left") { Text(exportedAt.formatted(date: .abbreviated, time: .shortened)) }
            }
            LabeledContent("Lines") { Text("\(takeover.lineCount)") }
            LabeledContent("To top up") { Text("\(takeover.shortfalls)") }
            if takeover.needCounting > 0 {
                LabeledContent("Need counting") { Text("\(takeover.needCounting)") }
            }
            if service.takeoverIsStale {
                Label("This is older than the last entry on this phone for the same list.",
                      systemImage: "exclamationmark.triangle")
            }
        } footer: {
            Text("The spreadsheet becomes this phone's list. The list that is here now is kept once, under Previous list on the Stock screen, and is never merged in.")
        }
        refusalsSection(takeover.refusals)
    }

    // MARK: - Base's baseline

    @ViewBuilder
    private func baselineSections(_ changes: [VanStockHandover.BaselineChange], fileName: String) -> some View {
        Section {
            Text(fileName)
                .font(.headline)
            Text("\(changes.count) standards would change. No counts are touched.")
                .foregroundStyle(.secondary)
        }
        let own = changes.filter { if case .keptOwn = $0.kind { return true } else { return false } }
        if !own.isEmpty {
            Section {
                ForEach(own) { change in
                    if let id = change.itemID, case .keptOwn(let current) = change.kind {
                        Toggle(isOn: Binding(
                            get: { takingBaseFigure.contains(id) },
                            set: { take in
                                if take { takingBaseFigure.insert(id) } else { takingBaseFigure.remove(id) }
                            })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.name)
                                Text("This list's own figure is \(figure(current)). The spreadsheet says \(figure(change.standard)).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Set by this list")
            } footer: {
                Text("This list's own figure is kept unless you switch a line on to take the spreadsheet's.")
            }
        }
        let plain = changes.filter { if case .keptOwn = $0.kind { return false } else { return true } }
        if !plain.isEmpty {
            Section {
                ForEach(plain) { change in
                    LabeledContent(change.name) {
                        if change.kind == .newLine {
                            Text("New, \(figure(change.standard))")
                        } else {
                            Text(verbatim: figure(change.standard))
                        }
                    }
                }
            } header: {
                Text("Standards")
            }
        }
    }

    // MARK: - Corrections

    @ViewBuilder
    private func correctionSections(_ proposal: VanStockSheet.Proposal, fileName: String) -> some View {
            Section {
                Text(fileName)
                    .font(.headline)
                Text("\(proposal.counts.count) counts, \(proposal.newLines.count) new lines, \(proposal.edits.count) lines with changed details.")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Nothing is changed until you tap Apply. Undo on the Stock screen takes the whole import back.")
            }

            let conflicts = proposal.counts.filter(\.movedSinceExport)
            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts) { count in
                        Toggle(isOn: Binding(
                            get: { keepingPhoneFigure.contains(count.itemID) },
                            set: { keep in
                                if keep { keepingPhoneFigure.insert(count.itemID) } else { keepingPhoneFigure.remove(count.itemID) }
                            })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(count.name)
                                Text("Spreadsheet says \(figure(count.to)). The phone says \(figure(count.from ?? .zero)).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Changed on the phone since the spreadsheet was made")
                } footer: {
                    Text("The spreadsheet's figure is used unless you switch a line on to keep the phone's.")
                }
            }

            let plain = proposal.counts.filter { !$0.movedSinceExport }
            if !plain.isEmpty {
                Section {
                    ForEach(plain) { count in
                        LabeledContent(count.name) {
                            if let from = count.from {
                                Text(verbatim: "\(figure(from)) → \(figure(count.to))")
                            } else {
                                Text(verbatim: figure(count.to))
                            }
                        }
                    }
                } header: {
                    Text("Counts")
                }
            }

            if !proposal.newLines.isEmpty {
                Section {
                    ForEach(proposal.newLines) { line in
                        LabeledContent(line.description.isEmpty ? (line.number ?? "") : line.description) {
                            if let onHand = line.onHand {
                                Text(verbatim: figure(onHand))
                            } else {
                                Text("Not counted")
                            }
                        }
                    }
                } header: {
                    Text("New lines")
                }
            }

            if !proposal.edits.isEmpty {
                Section {
                    ForEach(proposal.edits) { edit in
                        LabeledContent(edit.name) { Text("\(edit.changes.count) changes") }
                    }
                } header: {
                    Text("Changed details")
                }
            }

            if !proposal.missing.isEmpty {
                Section {
                    ForEach(proposal.missing) { item in Text(item.name) }
                } header: {
                    Text("Not in the spreadsheet")
                } footer: {
                    Text("These stay exactly as they are. To clear a line, set its count to zero.")
                }
            }

            refusalsSection(proposal.refusals)
    }

    @ViewBuilder
    private func refusalsSection(_ refusals: [VanStockSheet.Proposal.Refusal]) -> some View {
        if !refusals.isEmpty {
            Section {
                ForEach(refusals) { refusal in
                    LabeledContent {
                        if let name = refusal.name {
                            Text(verbatim: "\(name): ") + reasonText(refusal)
                        } else {
                            reasonText(refusal)
                        }
                    } label: {
                        Text("Row \(refusal.row)")
                    }
                }
            } header: {
                Text("Rows left out")
            } footer: {
                Text("Fix these in the spreadsheet and import it again, or change the lines here.")
            }
        }
    }

    private func reasonText(_ refusal: VanStockSheet.Proposal.Refusal) -> Text {
        switch refusal.reason {
        case .notAQuantity(let column, let value, let unit):
            // "On hand 4.2513 has more than 3 decimal places", "On hand 2.5 is not a whole number of packs".
            switch refusal.quantityRefusal {
            case .tooManyDecimals, .notWhole:
                switch unit {
                case .pack: return Text("\(column) \(value) is not a whole number of packs")
                case .each: return Text("\(column) \(value) is not a whole number")
                case .m, .ft, .kg, .lb, .l: return Text("\(column) \(value) has more than 3 decimal places")
                }
            case .negative: return Text("\(column) \(value) is below zero")
            case .tooLarge: return Text("\(column) \(value) is more than a million")
            case .notANumber, nil: return Text("\(column) “\(value)” isn't a number")
            }
        case .unknownUnit(let unit):
            return Text("“\(unit)” isn't a unit the list keeps")
        case .noPartNumberOrDescription:
            return Text("No part number or description")
        case .repeatsRow(let row):
            return Text("Repeats row \(row)")
        }
    }
}
