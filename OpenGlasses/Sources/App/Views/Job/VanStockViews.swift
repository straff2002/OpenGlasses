import SwiftUI
import UniformTypeIdentifiers
import VisionKit

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
    /// The business's own stock system, when one is connected (Plan MM P2): the screen pulls its
    /// figures when it opens (at most every 10 minutes) and on pull-to-refresh.
    var stockSystem: StockSystemService? = nil
    /// The clinic's own Microsoft 365 workbook (Plan NK P1), shown for a clinical list only.
    var clinicWorkbook: ClinicWorkbookService? = nil
    /// Open one line's page.
    let onOpen: (String) -> Void

    @State private var search = ""
    @State private var confirmingReset = false
    @State private var importing = false
    @State private var sharing: ShareItem?
    @State private var exportFailed = false
    @State private var namingPlace = false
    @State private var confirmingRestore = false
    @State private var scanning = false
    @State private var counting = false
    @State private var reporting = false
    @State private var checkingEMR = false
    @State private var workbookSettings = false

    private var rows: [VanStockRow] { VanStockRows.rows(store.log, query: search) }

    var body: some View {
        if let stockSystem {
            StockAuthorityReader(service: stockSystem) { systemHolds in
                if systemHolds { heldScreen(stockSystem) } else { phoneScreen }
            }
        } else {
            phoneScreen
        }
    }

    /// While the business's own system holds the count (Plan MM P3): its figures, read-only, the
    /// uses noted for it, and the phone's own list kept, read-only, as the previous list. Nothing
    /// here loads, counts, adjusts, imports or takes over: the system holds the count.
    private func heldScreen(_ stockSystem: StockSystemService) -> some View {
        List {
            StockSystemStatusSection(service: stockSystem)
            StockSystemHeldSections(service: stockSystem, search: search, kind: store.resolvedPlace.kind,
                                    job: FieldSessionService.shared.activeSession.map { ($0.id, $0.jobReference) })
            if !store.isUnreadable, !store.log.isEmpty {
                PreviousListSection(store: store)
            }
        }
        .ogFormStyle()
        .modifier(StockSystemPull(service: stockSystem))
        .searchable(text: $search, prompt: Text("Part number or description"))
        .navigationTitle(store.screenTitle)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    namingPlace = true
                } label: {
                    Label("Name and place…", systemImage: "pencil")
                }
                .disabled(store.isUnreadable)
            }
        }
        .sheet(isPresented: $namingPlace) {
            VanStockPlaceSheet(store: store, books: VanStockPlaceSheet.installedBooks())
        }
    }

    private var phoneScreen: some View {
        List {
            if let stockSystem {
                StockSystemStatusSection(service: stockSystem)
            }
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
            if store.resolvedClinical.clinical, !store.isUnreadable, let clinicWorkbook {
                ClinicWorkbookStockSection(service: clinicWorkbook) { workbookSettings = true }
            }
            if store.resolvedClinical.clinical, !store.isUnreadable {
                Section {
                    EmptyView()
                } footer: {
                    Text("This is a stock record, not the immunisation record. Nothing about a patient is kept here.")
                }
            }
        }
        .ogFormStyle()
        .modifier(StockSystemPull(service: stockSystem))
        .searchable(text: $search, prompt: Text("Part number or description"))
        .navigationTitle(store.screenTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Undo") { _ = service.undo(source: .typed) }
                    .disabled(!service.canUndo)
                    .accessibilityHint("Takes back the last entry, spoken or typed, or the last spreadsheet import.")
            }
            if DataScannerViewController.isSupported {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan a carton", systemImage: "barcode.viewfinder")
                    }
                    .disabled(store.isUnreadable)
                }
            }
            if store.resolvedClinical.clinical {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        counting = true
                    } label: {
                        Label("Count the stock…", systemImage: "checklist")
                    }
                    .disabled(store.isUnreadable || store.log.isEmpty)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        reporting = true
                    } label: {
                        Label("Stock report…", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(store.isUnreadable)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        checkingEMR = true
                    } label: {
                        Label("Check against the EMR…", systemImage: "checkmark.rectangle.stack")
                    }
                    .disabled(store.isUnreadable || store.log.isEmpty)
                }
                if clinicWorkbook != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            workbookSettings = true
                        } label: {
                            Label("Clinic's workbook…", systemImage: "tablecells")
                        }
                    }
                }
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
        .sheet(isPresented: $scanning) {
            StockScanSheet(store: store, service: service)
        }
        .sheet(isPresented: $counting) {
            StockCountSheet(store: store, service: service)
        }
        .sheet(isPresented: $reporting) {
            StockReportView(store: store, service: service)
        }
        .sheet(isPresented: $checkingEMR) {
            ImmunisationCheckSheet(store: store)
        }
        .sheet(isPresented: $workbookSettings) {
            if let clinicWorkbook { ClinicWorkbookSettingsView(service: clinicWorkbook) }
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

/// The phone's own list while a business's own system holds the count (Plan MM P3): kept as it
/// was, read-only and collapsed, and counting again once the connection is removed.
private struct PreviousListSection: View {
    @ObservedObject var store: VanStockStore
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(VanStockRows.rows(store.log)) { row in
                    VanStockRowLabel(row: row)
                        .accessibilityRemoveTraits(.isButton)
                }
            } label: {
                Text("Previous list")
            }
        } footer: {
            Text("The list kept on this phone before the stock system held the count. It isn't changed, and it counts again if the connection is removed.")
        }
    }
}

/// Where the connected system's figures stand (Plan MM P2): "From <system> at 09:10", and why the
/// last pull did not refresh them. Nothing while no system is connected. The figures themselves
/// join the screen with `van_stock` answering from the system.
private struct StockSystemStatusSection: View {
    @ObservedObject var service: StockSystemService

    var body: some View {
        if service.isRunning || service.snapshot != nil {
            if service.statusLine != nil || service.pullMessage != nil || service.pulling {
                Section {
                    if let line = service.statusLine { Text(line).font(.footnote) }
                    if service.pulling { Text("Reading the figures…").font(.footnote).foregroundStyle(.secondary) }
                    if let message = service.pullMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// The screen's pulls: on opening (the service keeps them at most every 10 minutes) and
/// pull-to-refresh, only while a system is connected.
private struct StockSystemPull: ViewModifier {
    let service: StockSystemService?

    func body(content: Content) -> some View {
        if let service, service.isRunning {
            content
                .task { await service.stockScreenOpened() }
                .refreshable { await service.refresh() }
        } else {
            content
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

    /// The part number, its category and where it lives, when the description is not already
    /// the number.
    private var detail: String? {
        let number = row.item.description.isEmpty ? nil : row.item.number
        let parts = [number, row.item.category, row.item.bin].compactMap { $0 }
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
    /// Why the unit picked was not taken: a figure on the line that it cannot hold.
    @State private var unitRefusal: VanStockLog.UnitChangeBlock?
    @Environment(\.locale) private var locale
    @State private var description = ""
    @State private var number = ""
    @State private var bin = ""
    @State private var category = ""
    /// A clinic's line shown by the week in reports and exports (Plan NJ §6).
    @State private var sensitive = false
    @State private var minimum = ""
    @State private var unit = VanStockUnit.each
    @State private var loaded = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private var item: VanStockItem? { store.log.item(id: itemID) }

    var body: some View {
        Group {
            if let item {
                let level = store.log.level(of: itemID)
                List {
                    levelSection(item, level)
                    if !store.log.lots(of: itemID).isEmpty {
                        lotsSection(item, level)
                    }
                    if StockExpiry.inStock(store.log.lots(of: itemID), levels: level.lots).isEmpty {
                        countSection(item, level)
                    }
                    detailsSection(item)
                    historySection
                    deleteSection
                }
                .ogFormStyle()
                .navigationTitle(item.description.isEmpty ? (item.number ?? "") : item.description)
                .onAppear { if !loaded { fill(from: item, level); loaded = true } }
                .confirmationDialog("Delete this line?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete line", role: .destructive) {
                        if service.deleteLine(itemID: itemID) { dismiss() }
                    }
                    Button("Keep it", role: .cancel) {}
                } message: {
                    Text("It comes off the list with its count, its lots and anything asked for. Undo on the Stock screen puts it back.")
                }
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

    /// The line's lots, oldest expiry first (Plan MY §1, §4). A line with stock in its lots is
    /// counted lot by lot, by scanning a carton and choosing Count.
    @ViewBuilder
    private func lotsSection(_ item: VanStockItem, _ level: VanStockLevel) -> some View {
        let today = StockDay(Date(), calendar: .current)
        Section {
            ForEach(StockExpiry.oldestFirst(store.log.lots(of: itemID))) { lot in
                let held = level.lots[lot.id]
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lot \(lot.code)")
                        if let expiry = lot.expiry {
                            if StockExpiry.isExpired(lot, today: today) {
                                Label("Expired \(StockScanText.day(expiry))", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if StockExpiry.expiresSoon(lot, today: today, calendar: .current) {
                                Label("Expires soon, \(StockScanText.day(expiry))", systemImage: "clock")
                                    .font(.caption)
                            } else {
                                Text("Expires \(StockScanText.day(expiry))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if held?.unreliable == true {
                            Label("Needs counting", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(verbatim: VanStockRow.figure(held?.onHand ?? .zero, unit: item.unit, locale: locale))
                        .font(.body.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Lots")
        } footer: {
            Text("Oldest expiry first. To count a lot, scan a carton from it and choose Count.")
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
            .onChange(of: unit) { _, _ in unitRefusal = nil }
            if let unitRefusal {
                Text(Self.message(unitRefusal, unit: item.unit, locale: locale))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            TextField("Minimum", text: $minimum)
                .keyboardType(unit.allowsFraction ? .decimalPad : .numberPad)
                .onChange(of: minimum) { _, _ in minimumRefusal = nil }
            if let minimumRefusal {
                refusalText(minimumRefusal, unit: unit)
            }
            TextField("Where it lives", text: $bin)
            // Only a line given a category has one to change: a clinic's imported vaccine list.
            if item.category != nil {
                TextField("Category", text: $category)
            }
            // Plan NJ §6: only a clinic's list has reports that small figures could point to a patient in.
            if store.resolvedClinical.clinical {
                Toggle("Sensitive: report by the week", isOn: $sensitive)
            }
            Button("Save details") { saveDetails() }
                .disabled(changes(to: item).isEmpty && minimumIsTaken)
        } header: {
            Text("Details")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The assistant warns at or below the minimum. Leave it empty for no warning until the last one is used.")
                if store.resolvedClinical.clinical {
                    Text("A sensitive line (rabies, travel vaccines, HPV, hepatitis B, or any the clinic chooses) appears in reports and exports by the week, never the day. This screen still shows its exact count.")
                }
            }
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

    /// Taking the line off the list, behind a confirmation. Not offered while a business's own
    /// system holds the count; on a clinic's list, held back once a dose was given or wasted.
    @ViewBuilder
    private var deleteSection: some View {
        let block = service.deletionBlock(itemID: itemID)
        if block != .systemHolds {
            Section {
                Button("Delete this line", role: .destructive) { confirmingDelete = true }
                    .disabled(block != nil)
            } footer: {
                if block == .clinicalRecord {
                    Text("Doses given or wasted from this line stay in the stock report, so it can't be deleted.")
                } else {
                    Text("Takes the line off the list. Undo on the Stock screen puts it back.")
                }
            }
        }
    }

    private func kindText(_ movement: VanStockMovement) -> Text {
        let figure = movement.quantity.formatted(locale: locale)
        switch movement.kind {
        case .loaded: return Text("Loaded \(figure)")
        case .used: return Text("Used \(figure)")
        case .removed: return Text("Removed \(figure)")
        case .wasted:
            let reason = StockScanText.wasteReasonName(movement.wasteReason ?? .other)
            return Text("Wasted \(figure) · \(reason)")
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
        category = item.category ?? ""
        sensitive = item.isSensitive
        minimum = item.minimum.map { VanStockEntry.text($0, locale: locale) } ?? ""
        minimumRefusal = nil
        unit = item.unit
        unitRefusal = nil
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

    /// Why the unit picked was not taken, with the figure in the phone's locale and the line's
    /// current unit: "On hand is 4,25 l, not a whole number. Count it before changing the unit."
    static func message(_ block: VanStockLog.UnitChangeBlock, unit: VanStockUnit, locale: Locale) -> LocalizedStringKey {
        switch block {
        case .onHand(let quantity):
            let figure = amount(quantity, unit: unit, locale: locale)
            return "On hand is \(figure), not a whole number. Count it before changing the unit."
        case .minimum(let quantity):
            let figure = amount(quantity, unit: unit, locale: locale)
            return "The minimum is \(figure), not a whole number. Change it before changing the unit."
        case .standard(let quantity):
            let figure = amount(quantity, unit: unit, locale: locale)
            return "The standard is \(figure), not a whole number. Change it before changing the unit."
        }
    }

    /// A figure as the unit-change message shows it: "4,25 l" in German, "4.25 l" in English.
    static func amount(_ quantity: StockQuantity, unit: VanStockUnit, locale: Locale) -> String {
        "\(quantity.formatted(locale: locale)) \(unit.rawValue)"
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
        let newCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if newCategory != (item.category ?? "") { changes.append(.category(newCategory.isEmpty ? nil : newCategory)) }
        if store.resolvedClinical.clinical, sensitive != item.isSensitive { changes.append(.sensitive(sensitive)) }
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
        // A minimum or a unit that is not taken changes nothing at all, not just itself.
        var refused = false
        if case .failure(let refusal) = VanStockEntry.minimum(minimum, unit: unit, locale: locale) {
            minimumRefusal = refusal
            refused = true
        }
        if unit != item.unit, let block = service.unitChangeBlock(itemID: itemID, to: unit) {
            unitRefusal = block
            refused = true
        }
        if refused { return }
        _ = service.edit(itemID: itemID, changes(to: item))
        if let saved = self.item { fill(from: saved, store.log.level(of: itemID)) }
    }
}
