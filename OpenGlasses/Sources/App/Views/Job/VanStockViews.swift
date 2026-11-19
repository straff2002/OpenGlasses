import SwiftUI
import UniformTypeIdentifiers

/// What is on the van, on the phone (Plan IH §5), or in the store or wherever the list is kept
/// (Plan MK).
///
/// The ordinary way to fix one wrong figure: a searchable list, and a page per line where the
/// count is set by hand. Every state shown here is also spoken by `van_stock`; the list and the
/// voice read the same log through the same service, so they cannot disagree. Its sentences name
/// no place; the title, the takeover and the empty list's hint follow the place in force
/// (`VanStockStore.resolvedPlace`, Plan MK §3).
struct VanStockView: View {
    @ObservedObject var store: VanStockStore
    var service: VanStockService = .shared
    /// Open one line's page.
    let onOpen: (String) -> Void

    @State private var search = ""
    @State private var confirmingReset = false
    @State private var importing = false
    @State private var sharing: ShareItem?
    @State private var exportFailed = false
    @State private var namingPlace = false
    @State private var confirmingRestore = false

    private var rows: [VanStockRow] { VanStockRows.rows(store.log, query: search) }

    var body: some View {
        List {
            if store.isUnreadable {
                unreadableSection
            } else if store.log.isEmpty {
                emptySection
            } else {
                Section {
                    ForEach(rows) { row in
                        Button { onOpen(row.id) } label: { VanStockRowLabel(row: row) }
                            .buttonStyle(.plain)
                    }
                    if rows.isEmpty {
                        Text("Nothing on the list matches that.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Tap a line to set its count or change its details. Anything said to the assistant shows here too.")
                }
            }
        }
        .ogFormStyle()
        .searchable(text: $search, prompt: Text("Part number or description"))
        .navigationTitle(store.screenTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Undo") { _ = service.undo(source: .typed) }
                    .disabled(!service.canUndo)
                    .accessibilityHint("Takes back the last entry, spoken or typed, or the last spreadsheet import.")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    importing = true
                } label: {
                    Label("Import a spreadsheet…", systemImage: "square.and.arrow.down")
                }
                .disabled(store.isUnreadable)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(action: export) {
                    Label("Export as a spreadsheet…", systemImage: "square.and.arrow.up")
                }
                .disabled(store.isUnreadable || store.log.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    if !VanStockHandoverService.shared.stage() { exportFailed = true }
                } label: {
                    Label("Send the stock list…", systemImage: "paperplane")
                }
                .disabled(store.isUnreadable || store.log.isEmpty || Config.hipaaMode)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    namingPlace = true
                } label: {
                    Label("Name and place…", systemImage: "pencil")
                }
                .disabled(store.isUnreadable)
            }
            if store.hasPrevious {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        confirmingRestore = true
                    } label: {
                        Label("Previous list…", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        }
        .sheet(isPresented: $namingPlace) {
            VanStockPlaceSheet(store: store, books: VanStockPlaceSheet.installedBooks())
        }
        .confirmationDialog("Go back to the list from before the last takeover?",
                            isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Go back to it", role: .destructive) { _ = store.restorePrevious() }
            Button("Keep this one", role: .cancel) {}
        } message: {
            Text("The list that is here now is replaced by the one it replaced.")
        }
        // The review is raised by the app, wherever the file came from; this only picks one.
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: VanStockSheet.fileExtension) ?? .data]) { result in
            guard case .success(let url) = result else { return }
            Task { @MainActor in VanStockImportService.shared.open(url) }
        }
        .sheet(item: $sharing) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
        .alert("The spreadsheet couldn't be made", isPresented: $exportFailed) {
            Button("OK") {}
        }
        .confirmationDialog("Start the list again?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Start again", role: .destructive) { store.removeAll() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The list on this phone can't be read. Starting again clears it.")
        }
    }

    /// Write the workbook to a temporary file, share it, and remove the file when the share is
    /// done — sent, saved or cancelled alike.
    private func export() {
        guard let url = service.exportFile() else {
            exportFailed = true
            return
        }
        sharing = ShareItem(items: [url]) { _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private var emptySection: some View {
        Section {
            Text("Nothing on the list yet.")
                .font(.headline)
            Text(StockPlaceScreenText.emptyHint(store.resolvedPlace.kind))
                .foregroundStyle(.secondary)
            Button("Import a spreadsheet…") { importing = true }
        }
    }

    private var unreadableSection: some View {
        Section {
            Label("The list on this phone can't be read.", systemImage: "exclamationmark.triangle")
            Button("Start the list again", role: .destructive) { confirmingReset = true }
        } footer: {
            Text("Nothing has been changed. The assistant won't guess any figures.")
        }
    }
}

/// One line in the list: what it is, how many, and what needs attention.
private struct VanStockRowLabel: View {
    let row: VanStockRow
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.description.isEmpty ? (row.item.number ?? "") : row.item.description)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                marks
            }
            Spacer(minLength: 12)
            if let quantity = row.quantity(locale: locale) {
                Text(quantity)
                    .font(.title3.monospacedDigit())
            } else {
                Text("Not counted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: OGMetrics.minTouchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// The part number and where it lives, when the description is not already the number.
    private var detail: String? {
        let number = row.item.description.isEmpty ? nil : row.item.number
        let parts = [number, row.item.bin].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var marks: some View {
        if row.level.unreliable {
            Label("Needs counting", systemImage: "exclamationmark.triangle")
                .font(.caption)
        } else if row.isLow {
            Label("Low", systemImage: "arrow.down.circle")
                .font(.caption)
        }
        if row.level.onOrder > .zero {
            Label("\(VanStockRow.figure(row.level.onOrder, unit: row.item.unit, locale: locale)) asked for", systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let notFound = row.notFoundLabel {
            Label(notFound, systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One line of the list: its level and how it is known, a count set by hand, its details, and its
/// history (Plan IH §5).
struct VanStockItemView: View {
    @ObservedObject var store: VanStockStore
    let itemID: String
    var service: VanStockService = .shared

    /// The count in whole units, for a line in `each` or `pack`.
    @State private var count = 0
    /// The count as typed, for a line in a measured unit.
    @State private var countText = ""
    /// Why the typed count or minimum was not taken. Nothing is saved while one is shown.
    @State private var countRefusal: StockQuantityRefusal?
    @State private var minimumRefusal: StockQuantityRefusal?
    @Environment(\.locale) private var locale
    @State private var description = ""
    @State private var number = ""
    @State private var bin = ""
    @State private var minimum = ""
    @State private var unit = VanStockUnit.each
    @State private var loaded = false

    private var item: VanStockItem? { store.log.item(id: itemID) }

    var body: some View {
        Group {
            if let item {
                let level = store.log.level(of: itemID)
                List {
                    levelSection(item, level)
                    countSection(item, level)
                    detailsSection(item)
                    historySection
                }
                .ogFormStyle()
                .navigationTitle(item.description.isEmpty ? (item.number ?? "") : item.description)
                .onAppear { if !loaded { fill(from: item, level); loaded = true } }
            } else {
                Text("This line is no longer on the list.")
                    .foregroundStyle(.secondary)
                    .navigationTitle(store.screenTitle)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func levelSection(_ item: VanStockItem, _ level: VanStockLevel) -> some View {
        Section {
            if level.unreliable {
                Label("This count can't be trusted: a use was recorded when the list showed none. Count them and set the figure below.",
                      systemImage: "exclamationmark.triangle")
            }
            if let asOf = level.asOf {
                LabeledContent("On hand") {
                    Text(verbatim: VanStockRow.figure(level.onHand, unit: item.unit, locale: locale))
                }
                LabeledContent("How it's known") {
                    if level.handedOver {
                        Text("Handed over")
                    } else if level.provenance == .counted {
                        Text("Counted")
                    } else {
                        Text("Worked out from loads and uses")
                    }
                }
                LabeledContent("Last changed") {
                    Text(asOf.formatted(date: .abbreviated, time: .shortened))
                }
            } else {
                Text("Nothing has been recorded for this line yet.")
                    .foregroundStyle(.secondary)
            }
            if level.onOrder > .zero {
                LabeledContent("Asked for, not yet loaded") {
                    Text(verbatim: VanStockRow.figure(level.onOrder, unit: item.unit, locale: locale))
                }
            }
        }
    }

    @ViewBuilder
    private func countSection(_ item: VanStockItem, _ level: VanStockLevel) -> some View {
        Section {
            if item.unit.allowsFraction {
                // A measured unit: typed to the thousandth, with a stepper that moves one whole unit.
                HStack {
                    TextField("Amount", text: $countText)
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                        .onChange(of: countText) { _, _ in countRefusal = nil }
                    Text(verbatim: item.unit.rawValue)
                        .foregroundStyle(.secondary)
                    Stepper("Count",
                            onIncrement: { step(item, level, by: 1) },
                            onDecrement: { step(item, level, by: -1) })
                        .labelsHidden()
                }
                if let countRefusal {
                    refusalText(countRefusal, unit: item.unit)
                }
            } else {
                Stepper(value: $count, in: 0...9_999) {
                    LabeledContent("Count") { Text("\(count)").monospacedDigit() }
                }
            }
            Button("Save count") { saveCount(item) }
                .disabled(level.isRecorded && !level.unreliable && level.provenance == .counted
                          && typedCount(item) == level.onHand)
        } header: {
            Text("Set the count")
        } footer: {
            Text("Saving records a count, so the figure is marked as counted from now.")
        }
    }

    @ViewBuilder
    private func detailsSection(_ item: VanStockItem) -> some View {
        Section {
            TextField("Description", text: $description)
            TextField("Part number", text: $number)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Picker("Counted in", selection: $unit) {
                ForEach(VanStockUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            TextField("Minimum", text: $minimum)
                .keyboardType(unit.allowsFraction ? .decimalPad : .numberPad)
                .onChange(of: minimum) { _, _ in minimumRefusal = nil }
            if let minimumRefusal {
                refusalText(minimumRefusal, unit: unit)
            }
            TextField("Where it lives", text: $bin)
            Button("Save details") { saveDetails() }
                .disabled(changes(to: item).isEmpty && minimumIsTaken)
        } header: {
            Text("Details")
        } footer: {
            Text("The assistant warns at or below the minimum. Leave it empty for no warning until the last one is used.")
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let history = VanStockRows.history(store.log, itemID: itemID)
        if !history.isEmpty {
            Section {
                ForEach(history) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            kindText(entry.movement)
                                .strikethrough(entry.takenBack)
                            if entry.takenBack {
                                Text("Taken back")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let job = entry.movement.jobReference {
                                Text("Job \(job)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        Text(entry.movement.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("History")
            }
        }
    }

    private func kindText(_ movement: VanStockMovement) -> Text {
        let figure = movement.quantity.formatted(locale: locale)
        switch movement.kind {
        case .loaded: return Text("Loaded \(figure)")
        case .used: return Text("Used \(figure)")
        case .removed: return Text("Removed \(figure)")
        case .counted: return Text("Counted \(figure)")
        case .ordered: return Text("Asked for \(figure)")
        case .opening: return Text("Carried forward \(figure)")
        case .edited, .reversed: return Text("Details changed")
        }
    }

    // MARK: - Editing

    private func fill(from item: VanStockItem, _ level: VanStockLevel) {
        count = VanStockEntry.wholeCount(level.onHand) ?? 0
        countText = level.isRecorded ? VanStockEntry.text(level.onHand, locale: locale) : ""
        countRefusal = nil
        description = item.description
        number = item.number ?? ""
        bin = item.bin ?? ""
        minimum = item.minimum.map { VanStockEntry.text($0, locale: locale) } ?? ""
        minimumRefusal = nil
        unit = item.unit
    }

    // MARK: - The count

    /// The count the page holds, read in the line's unit. Nil while a typed figure is refused.
    private func typedCount(_ item: VanStockItem) -> StockQuantity? {
        guard item.unit.allowsFraction else { return StockQuantity(whole: count) }
        return try? VanStockEntry.read(countText, unit: item.unit, locale: locale).get()
    }

    private func step(_ item: VanStockItem, _ level: VanStockLevel, by units: Int) {
        countText = VanStockEntry.stepped(countText, by: units, unit: item.unit, locale: locale, fallback: level.onHand)
    }

    /// Records the count, or shows why the typed figure was not taken and records nothing.
    private func saveCount(_ item: VanStockItem) {
        guard item.unit.allowsFraction else {
            _ = service.setCount(itemID: itemID, to: StockQuantity(whole: count))
            return
        }
        switch VanStockEntry.read(countText, unit: item.unit, locale: locale) {
        case .success(let quantity):
            countRefusal = nil
            if service.setCount(itemID: itemID, to: quantity) {
                countText = VanStockEntry.text(quantity, locale: locale)
            }
        case .failure(let refusal):
            countRefusal = refusal
        }
    }

    /// A short line under a field that was not taken.
    private func refusalText(_ refusal: StockQuantityRefusal, unit: VanStockUnit) -> some View {
        Text(Self.message(refusal, unit: unit))
            .font(.caption)
            .foregroundStyle(.red)
    }

    /// Why a typed figure was not taken, in a few words.
    static func message(_ refusal: StockQuantityRefusal, unit: VanStockUnit) -> LocalizedStringKey {
        switch refusal {
        case .notANumber: return "Not a number."
        case .negative: return "Can't be below zero."
        case .tooLarge: return "No more than a million."
        case .tooManyDecimals, .notWhole:
            switch unit {
            case .pack: return "Packs are counted whole."
            case .each: return "Whole numbers only."
            case .m, .ft, .kg, .lb, .l: return "Up to 3 decimal places."
            }
        }
    }

    /// What the fields would change, in the order they are applied.
    private func changes(to item: VanStockItem) -> [VanStockLog.Change] {
        var changes: [VanStockLog.Change] = []
        let newDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if newDescription != item.description { changes.append(.description(newDescription)) }
        let newNumber = VaultPartsIndex.normalise(number)
        if newNumber != (item.number ?? "") { changes.append(.number(newNumber.isEmpty ? nil : newNumber)) }
        if unit != item.unit { changes.append(.unit(unit)) }
        // Read in the unit chosen above, which is applied first; a figure it cannot hold is no change.
        if case .success(let newMinimum) = VanStockEntry.minimum(minimum, unit: unit, locale: locale),
           newMinimum != item.minimum {
            changes.append(.minimum(newMinimum))
        }
        let newBin = bin.trimmingCharacters(in: .whitespacesAndNewlines)
        if newBin != (item.bin ?? "") { changes.append(.bin(newBin.isEmpty ? nil : newBin)) }
        return changes
    }

    /// Whether the typed minimum can be kept in the chosen unit. One that cannot still lets Save
    /// details be tapped, so it can say why.
    private var minimumIsTaken: Bool {
        if case .success = VanStockEntry.minimum(minimum, unit: unit, locale: locale) { return true }
        return false
    }

    private func saveDetails() {
        guard let item else { return }
        // A minimum that is not taken changes nothing at all, not just the minimum.
        if case .failure(let refusal) = VanStockEntry.minimum(minimum, unit: unit, locale: locale) {
            minimumRefusal = refusal
            return
        }
        _ = service.edit(itemID: itemID, changes(to: item))
        if let saved = self.item { fill(from: saved, store.log.level(of: itemID)) }
    }
}
