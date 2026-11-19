import Foundation

/// The van's stock as a spreadsheet, out and back (Plan IH §6).
///
/// The log is the store and the workbook is a view of it. Out: every line with its level, and the
/// history beside it. Back: an edited workbook becomes a *proposal* — counts, new lines, changed
/// details — that the technician sees before one tap applies it as a single batch, so one undo
/// takes the whole import back. A sheet this app did not write is read by its headers.
enum VanStockSheet {

    /// The van's stock sheet, and every older workbook's. A list kept elsewhere names its sheet
    /// for its place (Plan MK §3): see `stockSheetName(_:)`.
    static let stockSheetName = "Van stock"
    /// Excel refuses a sheet name longer than this.
    static let sheetNameLimit = 31
    static let historySheetName = "History"
    /// The hidden sheet that says when the workbook was written.
    static let metaSheetName = "Avenkin"
    static let exportedAtKey = "exported_at"
    static let vanIDKey = "van_id"
    static let vanNameKey = "van_name"
    /// Where the list is kept (Plan MK §2), as the kind's raw value. Written only when the list has
    /// a place; an older build looks rows up by key and ignores it.
    static let placeKey = "place"
    static let fileExtension = "xlsx"

    /// Whether a file handed to the app is a workbook this can try to read.
    static func isWorkbook(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    /// The stock sheet's columns, in order.
    enum Column: String, CaseIterable {
        case partNumber = "Part number"
        case description = "Description"
        case unit = "Unit"
        case onHand = "On hand"
        case standard = "Standard"
        case standardSetBy = "Standard set by"
        case toTopUp = "To top up"
        case minimum = "Minimum"
        case onOrder = "On order"
        case needsCount = "Needs a count"
        case bin = "Bin"
        case lastChanged = "Last changed"
        case itemID = "Item ID"

        var layout: XLSX.Column {
            switch self {
            case .partNumber: return XLSX.Column(width: 20, isText: true)
            case .description: return XLSX.Column(width: 38)
            case .bin: return XLSX.Column(width: 18, isText: true)
            case .lastChanged: return XLSX.Column(width: 18, isText: true)
            case .standardSetBy: return XLSX.Column(width: 16)
            case .itemID: return XLSX.Column(width: 38, isText: true, isHidden: true)
            case .unit, .onHand, .standard, .toTopUp, .minimum, .onOrder, .needsCount:
                return XLSX.Column(width: 12)
            }
        }
    }

    // MARK: - The place

    /// The stock sheet's name for a place: "Van stock", "Store stock", "Stock" (Plan MK §3).
    /// Workbook text, English like the rest of the workbook, and never longer than Excel allows.
    static func stockSheetName(_ kind: StockPlace.Kind) -> String {
        String(StockPlaceWording(kind).title.prefix(sheetNameLimit))
    }

    /// Every name a stock sheet has been written under, so a workbook is read whatever kind of
    /// place wrote it.
    static let stockSheetNames: Set<String> = Set(StockPlace.Kind.allCases.map(stockSheetName))

    /// The place a workbook for this list is written for: the organisation's profile over the
    /// list's own choice, over van (Plan MK §2).
    static func kind(for van: VanIdentity?) -> StockPlace.Kind {
        StockPlaceSetting.current(list: van?.place).kind
    }

    /// What the Standard set by column says for who set a line's standard. A vehicle keeps
    /// "Base" and "This truck"; premises say "Office" and "This store", "This warehouse" or "This
    /// list" (Plan MK §3). The reader takes "Base" and "Office" alike as set from outside.
    static func standardSetByText(_ setBy: VanStockItem.StandardOrigin, kind: StockPlace.Kind) -> String {
        switch (setBy, kind) {
        case (.base, .van), (.base, .truck): return "Base"
        case (.base, _): return "Office"
        case (.van, .van), (.van, .truck): return "This truck"
        case (.van, .store): return "This store"
        case (.van, .warehouse): return "This warehouse"
        case (.van, .stock): return "This list"
        }
    }

    /// The words in the Standard set by column that mean the standard came from outside the
    /// list: a vehicle's base or premises' office, in any case.
    static let setByOutsideWords: Set<String> = ["base", "office"]

    // MARK: - Out

    /// "Van stock 2026-10-14.xlsx", or "Store stock 2026-10-14.xlsx" for a store (Plan MK §3).
    /// With no kind given, the profile's place or van, because there is no list to ask.
    static func fileName(exportedAt: Date, calendar: Calendar = .current, kind: StockPlace.Kind? = nil) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: exportedAt)
        let title = StockPlaceWording(kind ?? Self.kind(for: nil)).title
        return String(format: "%@ %04d-%02d-%02d.xlsx", title, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The workbook. With no kind given, the place in force for `van` (`kind(for:)`).
    static func data(_ log: VanStockLog, van: VanIdentity? = nil, exportedAt: Date,
                     calendar: Calendar = .current, kind: StockPlace.Kind? = nil) -> Data {
        XLSXWriter.data(for: workbook(log, van: van, exportedAt: exportedAt, calendar: calendar, kind: kind),
                        modified: exportedAt)
    }

    static func workbook(_ log: VanStockLog, van: VanIdentity? = nil, exportedAt: Date,
                         calendar: Calendar = .current, kind: StockPlace.Kind? = nil) -> XLSX.Workbook {
        let kind = kind ?? Self.kind(for: van)
        let rows = VanStockRows.rows(log)
        var stock: [[XLSX.Cell]] = [Column.allCases.map { .text($0.rawValue) }]
        for row in rows {
            let item = row.item
            let level = row.level
            stock.append(Column.allCases.map { column -> XLSX.Cell in
                switch column {
                case .partNumber: return item.number.map(XLSX.Cell.text) ?? .empty
                case .description: return .text(item.description)
                case .unit: return .text(item.unit.rawValue)
                // An unknown is never a number: a line nothing was recorded against is left blank.
                case .onHand: return level.isRecorded ? figure(level.onHand) : .empty
                case .standard: return item.standard.map(figure) ?? .empty
                case .standardSetBy:
                    guard item.standard != nil, let setBy = item.standardSetBy else { return .empty }
                    return .text(standardSetByText(setBy, kind: kind))
                case .toTopUp: return item.standard.map { figure(max($0 - level.onHand, .zero)) } ?? .empty
                case .minimum: return item.minimum.map(figure) ?? .empty
                case .onOrder: return level.onOrder > .zero ? figure(level.onOrder) : .empty
                case .needsCount: return level.unreliable ? .text("Yes") : .empty
                case .bin: return item.bin.map(XLSX.Cell.text) ?? .empty
                case .lastChanged: return level.asOf.map { .text(stamp($0, calendar)) } ?? .empty
                case .itemID: return .text(item.id)
                }
            })
        }

        let names = Dictionary(log.items.map { ($0.id, $0.name) }) { first, _ in first }
        var history: [[XLSX.Cell]] = [["When", "Line", "What", "Quantity", "Job", "How"].map { .text($0) }]
        let reversed = Set(log.movements.compactMap { $0.kind == .reversed ? $0.reverses : nil })
        for movement in log.movements.reversed().prefix(2_000) where movement.kind != .reversed {
            history.append([
                .text(stamp(movement.at, calendar)),
                .text(names[movement.itemID] ?? ""),
                .text(movement.kind.rawValue + (reversed.contains(movement.id) ? " (taken back)" : "")),
                movement.changesLevel || movement.kind == .ordered ? figure(movement.quantity) : .empty,
                movement.jobReference.map(XLSX.Cell.text) ?? .empty,
                .text(movement.source.rawValue),
            ])
        }

        var meta: [[XLSX.Cell]] = [
            [.text("key"), .text("value")],
            [.text("format"), .text("1")],
            [.text(exportedAtKey), .text(ISO8601DateFormatter().string(from: exportedAt))],
        ]
        if let van {
            meta.append([.text(vanIDKey), .text(van.id)])
            meta.append([.text(vanNameKey), .text(van.name)])
            // The vault the list checks numbers against stays on this phone (Plan MK §4).
            if let place = van.place { meta.append([.text(placeKey), .text(place.rawValue)]) }
        }

        return XLSX.Workbook(sheets: [
            XLSX.Sheet(name: stockSheetName(kind), columns: Column.allCases.map(\.layout), rows: stock),
            XLSX.Sheet(name: historySheetName,
                       columns: [XLSX.Column(width: 18, isText: true), XLSX.Column(width: 38), XLSX.Column(width: 22),
                                 XLSX.Column(width: 10), XLSX.Column(width: 16, isText: true), XLSX.Column(width: 10)],
                       rows: history),
            XLSX.Sheet(name: metaSheetName,
                       columns: [XLSX.Column(width: 16, isText: true), XLSX.Column(width: 28, isText: true)],
                       rows: meta, isHidden: true),
        ])
    }

    /// A figure as the workbook holds it: whole units, as every workbook has. The ledger keeps
    /// thousandths; until the workbook takes decimals, a figure that is part of a unit is written
    /// as its text ("4.25") so it is never cut to a whole number.
    static func figure(_ quantity: StockQuantity) -> XLSX.Cell {
        quantity.isWhole ? .number(quantity.scaled / StockQuantity.perUnit) : .text(quantity.decimalString)
    }

    /// "2026-10-14 10:40", in the calendar's own time zone.
    private static func stamp(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: - Back

    /// What an edited workbook would change. Nothing here has been applied.
    struct Proposal: Equatable {

        struct Count: Equatable, Identifiable {
            let itemID: String
            let name: String
            /// What the phone shows now. Nil for a line nothing was recorded against.
            let from: StockQuantity?
            let to: StockQuantity
            /// The line also moved on the phone after the workbook was written, so there are two
            /// figures and the technician chooses. The sheet's is the default.
            let movedSinceExport: Bool
            var id: String { itemID }
        }

        struct NewLine: Equatable, Identifiable {
            let row: Int
            let number: String?
            let description: String
            let unit: VanStockUnit
            let onHand: StockQuantity?
            let minimum: StockQuantity?
            let standard: StockQuantity?
            let bin: String?
            var id: Int { row }
        }

        struct Edit: Equatable, Identifiable {
            let itemID: String
            let name: String
            let changes: [VanStockLog.Change]
            var id: String { itemID }
        }

        struct Refusal: Equatable, Identifiable {
            enum Reason: Equatable {
                /// A figure that is negative, fractional or not a number: the column and what it held.
                case notAWholeNumber(column: String, value: String)
                case unknownUnit(String)
                case noPartNumberOrDescription
                /// The same line appears on an earlier row.
                case repeatsRow(Int)
            }

            let row: Int
            let reason: Reason
            var id: Int { row }
        }

        var counts: [Count] = []
        var newLines: [NewLine] = []
        var edits: [Edit] = []
        /// Lines on the phone that the sheet no longer has. Listed, and left exactly as they are:
        /// sorting, filtering and an accidental delete must not zero the van.
        var missing: [VanStockItem] = []
        var refusals: [Refusal] = []

        /// Whether applying it would change anything.
        var changesNothing: Bool { counts.isEmpty && newLines.isEmpty && edits.isEmpty }
    }

    enum Failure: Error, Equatable {
        case workbook(XLSXReader.Failure)
        /// No row of the sheet names a part and a quantity in words this recognises.
        case noRecognisableHeader
    }

    /// The header words a sheet somebody else wrote may use.
    static let headerSynonyms: [Column: Set<String>] = [
        .itemID: ["item id"],
        .partNumber: ["part", "part number", "part no", "part #", "item", "number", "sku"],
        .description: ["description", "desc", "name", "item description"],
        .onHand: ["on hand", "qty", "quantity", "count", "stock"],
        .unit: ["unit", "units", "uom"],
        .standard: ["standard", "par", "stock to", "standard load"],
        .minimum: ["min", "minimum", "reorder point"],
        .bin: ["bin", "location", "shelf"],
    ]

    static func proposal(from data: Data, log: VanStockLog) -> Result<Proposal, Failure> {
        switch XLSXReader.read(data) {
        case .failure(let failure): return .failure(.workbook(failure))
        case .success(let sheets): return proposal(from: sheets, log: log)
        }
    }

    /// One row of a stock sheet, read and checked, before anybody decides what it means.
    struct Row: Equatable {
        /// The row's number in the sheet, as a spreadsheet shows it.
        let number: Int
        let itemID: String?
        /// Normalised. Nil when the row gives none.
        let partNumber: String?
        let description: String?
        let unit: VanStockUnit?
        /// For each figure: nil when the sheet has no such column, `.some(nil)` when the cell is
        /// empty, and the value otherwise.
        let onHandCell: StockQuantity??
        let minimumCell: StockQuantity??
        let standardCell: StockQuantity??
        let onOrder: StockQuantity?
        let needsCount: Bool
        let standardSetByBase: Bool
        /// Nil when the sheet has no such column; empty when the cell is.
        let binCell: String?

        var onHand: StockQuantity? { onHandCell ?? nil }
        var minimum: StockQuantity? { minimumCell ?? nil }
        var standard: StockQuantity? { standardCell ?? nil }
        var bin: String? { binCell.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// A stock sheet, read.
    struct Read: Equatable {
        var rows: [Row] = []
        var refusals: [Proposal.Refusal] = []
        /// A sheet this app wrote names its lines; an empty cell in it means "cleared".
        var isOwn = false
        var exportedAt: Date?
        var van: VanIdentity?
    }

    /// Read the stock sheet of a workbook into rows. Nothing is compared with the phone here.
    static func rows(from sheets: [XLSXReader.Sheet]) -> Result<Read, Failure> {
        // By any place's name, so a store's workbook reads as a van's does; otherwise the first
        // sheet that is not the meta sheet, as a workbook somebody else wrote is (Plan MK §3).
        let sheet = sheets.first { stockSheetNames.contains($0.name) }
            ?? sheets.first { !$0.isHidden && $0.name != metaSheetName }
        guard let sheet, let (headerIndex, columns) = header(in: sheet.rows) else {
            return .failure(.noRecognisableHeader)
        }
        var read = Read()
        read.isOwn = columns[.itemID] != nil
        let meta = sheets.first { $0.name == metaSheetName }?.rows ?? []
        func value(_ key: String) -> String? {
            meta.first { $0.first == key }.flatMap { $0.count > 1 && !$0[1].isEmpty ? $0[1] : nil }
        }
        read.exportedAt = value(exportedAtKey).flatMap { ISO8601DateFormatter().date(from: $0) }
        if let id = value(vanIDKey) {
            // A kind from a newer build reads as van; a workbook with no place row has none.
            read.van = VanIdentity(id: id, name: value(vanNameKey) ?? "",
                                   place: value(placeKey).map { StockPlace.Kind(lenient: $0) })
        }

        for (offset, cells) in sheet.rows.enumerated() where offset > headerIndex {
            let rowNumber = offset + 1
            func cell(_ column: Column) -> String? {
                guard let index = columns[column] else { return nil }
                return index < cells.count ? cells[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            guard cells.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }

            // Words where a part number goes are a description, as they are when spoken.
            var number = cell(.partNumber).flatMap { $0.isEmpty ? nil : $0 }
            var described = cell(.description).flatMap { $0.isEmpty ? nil : $0 }
            if let candidate = number, described == nil, columns[.description] == nil,
               candidate.contains(where: \.isWhitespace) || !candidate.contains(where: \.isNumber) {
                described = candidate
                number = nil
            }
            let normalised = number.map(VaultPartsIndex.normalise).flatMap { $0.isEmpty ? nil : $0 }

            var numbers: [Column: StockQuantity?] = [:]
            var refusal: Proposal.Refusal.Reason?
            for column in [Column.onHand, .minimum, .standard, .onOrder] {
                guard let raw = cell(column) else { continue }
                switch wholeNumber(raw) {
                case .absent: numbers[column] = .some(nil)
                case .value(let value): numbers[column] = .some(value)
                // On order is worked out by the phone; whatever was typed over it is not a reason
                // to leave the row out.
                case .invalid where column == .onOrder: numbers[column] = .some(nil)
                case .invalid: refusal = .notAWholeNumber(column: column.rawValue, value: raw)
                }
            }
            var unit: VanStockUnit?
            if let raw = cell(.unit), !raw.isEmpty {
                unit = VanStockUnit(spoken: raw)
                if unit == nil { refusal = .unknownUnit(raw) }
            }
            if let refusal {
                read.refusals.append(.init(row: rowNumber, reason: refusal))
                continue
            }
            read.rows.append(Row(
                number: rowNumber, itemID: cell(.itemID).flatMap { $0.isEmpty ? nil : $0 },
                partNumber: normalised, description: described, unit: unit,
                onHandCell: numbers[.onHand], minimumCell: numbers[.minimum], standardCell: numbers[.standard],
                onOrder: numbers[.onOrder] ?? nil,
                needsCount: (cell(.needsCount) ?? "").lowercased() == "yes",
                standardSetByBase: setByOutsideWords.contains((cell(.standardSetBy) ?? "").lowercased()),
                binCell: cell(.bin)))
        }
        return .success(read)
    }

    static func proposal(from sheets: [XLSXReader.Sheet], log: VanStockLog) -> Result<Proposal, Failure> {
        let read: Read
        switch rows(from: sheets) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): read = value
        }
        let levels = log.levels
        var proposal = Proposal(refusals: read.refusals)
        var seen: [String: Int] = [:]

        for row in read.rows {
            let existing = match(id: row.itemID, number: row.partNumber, description: row.description, in: log)
            guard let item = existing else {
                guard row.partNumber != nil || row.description != nil else {
                    proposal.refusals.append(.init(row: row.number, reason: .noPartNumberOrDescription))
                    continue
                }
                proposal.newLines.append(.init(
                    row: row.number, number: row.partNumber, description: row.description ?? "",
                    unit: row.unit ?? .each, onHand: row.onHand, minimum: row.minimum,
                    standard: row.standard, bin: row.bin))
                continue
            }
            if let earlier = seen[item.id] {
                proposal.refusals.append(.init(row: row.number, reason: .repeatsRow(earlier)))
                continue
            }
            seen[item.id] = row.number

            let level = levels[item.id] ?? VanStockLevel(itemID: item.id)
            if let onHand = row.onHand, !(level.isRecorded && !level.unreliable && level.onHand == onHand) {
                // The export's stamp is to the second, so a movement in that same second is not "after".
                let moved = read.exportedAt.map { exported in
                    level.asOf.map { $0 >= exported.addingTimeInterval(1) } ?? false
                } ?? false
                proposal.counts.append(.init(itemID: item.id, name: item.name,
                                             from: level.isRecorded ? level.onHand : nil, to: onHand,
                                             movedSinceExport: moved))
            }

            var changes: [VanStockLog.Change] = []
            if let described = row.description, described != item.description { changes.append(.description(described)) }
            if let number = row.partNumber, number != item.number { changes.append(.number(number)) }
            if let unit = row.unit, unit != item.unit { changes.append(.unit(unit)) }
            if case .some(let minimum) = row.minimumCell, minimum != item.minimum, minimum != nil || read.isOwn {
                changes.append(.minimum(minimum))
            }
            if case .some(let standard) = row.standardCell, standard != item.standard, standard != nil || read.isOwn {
                changes.append(.standard(standard, setBy: .van))
            }
            if let bin = row.binCell, bin != (item.bin ?? ""), !bin.isEmpty || read.isOwn {
                changes.append(.bin(bin.isEmpty ? nil : bin))
            }
            if !changes.isEmpty { proposal.edits.append(.init(itemID: item.id, name: item.name, changes: changes)) }
        }

        proposal.refusals.sort { $0.row < $1.row }
        if read.isOwn { proposal.missing = log.items.filter { seen[$0.id] == nil } }
        return .success(proposal)
    }

    /// Apply a proposal as one batch. `keepingPhoneFigure` names the lines, among those that moved
    /// since the export, where the technician chose the phone's figure over the sheet's.
    static func apply(_ proposal: Proposal, to log: inout VanStockLog, keepingPhoneFigure: Set<String> = [],
                      at: Date, batch: String, verify: (String) -> TaskPart,
                      makeID: () -> String = { UUID().uuidString }) {
        for edit in proposal.edits {
            for change in edit.changes {
                log.edit(itemID: edit.itemID, change, at: at, batch: batch, source: .sheet, id: makeID())
                if case .number(let number) = change {
                    log.edit(itemID: edit.itemID, .verified(number.map { verify($0).verified } ?? false),
                             at: at, batch: batch, source: .sheet, id: makeID())
                }
            }
        }
        for line in proposal.newLines {
            let checked = line.number.map(verify)
            let item = log.addItem(id: makeID(), number: line.number,
                                   description: line.description.isEmpty ? (checked?.partDescription ?? "") : line.description,
                                   unit: line.unit, minimum: line.minimum, standard: line.standard,
                                   standardSetBy: line.standard == nil ? nil : .van, bin: line.bin,
                                   verified: checked?.verified ?? false, batch: batch)
            if let onHand = line.onHand {
                log.record(.counted, itemID: item.id, quantity: onHand, at: at, batch: batch, source: .sheet, id: makeID())
            } else {
                // Nothing counted, so note the line's unit: the batch then has an entry an undo can find.
                log.appendNote(itemID: item.id, at: at, batch: batch, source: .sheet, id: makeID())
            }
        }
        for count in proposal.counts where !(count.movedSinceExport && keepingPhoneFigure.contains(count.itemID)) {
            log.record(.counted, itemID: count.itemID, quantity: count.to, at: at, batch: batch, source: .sheet, id: makeID())
        }
    }

    // MARK: - Reading a sheet

    /// The header row and where each recognised column is. A header names a part or a
    /// description, and at least one of the figures.
    private static func header(in rows: [[String]]) -> (Int, [Column: Int])? {
        for (offset, row) in rows.prefix(10).enumerated() {
            var found: [Column: Int] = [:]
            for (index, raw) in row.enumerated() {
                let word = raw.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                guard !word.isEmpty,
                      let column = headerSynonyms.first(where: { $0.value.contains(word) })?.key
                        ?? Column.allCases.first(where: { $0.rawValue.lowercased() == word }),
                      found[column] == nil else { continue }
                found[column] = index
            }
            let namesALine = found[.partNumber] != nil || found[.description] != nil
            let hasAFigure = found[.onHand] != nil || found[.standard] != nil || found[.minimum] != nil
            if namesALine && hasAFigure { return (offset, found) }
        }
        return nil
    }

    static func match(id: String?, number: String?, description: String?, in log: VanStockLog) -> VanStockItem? {
        if let id, !id.isEmpty, let item = log.item(id: id) { return item }
        if let number {
            let sameNumber = log.items.filter { $0.number == number }
            if sameNumber.count == 1 { return sameNumber[0] }
            if sameNumber.count > 1 { return nil }
        }
        guard let description else { return nil }
        let sameWords = log.items.filter {
            $0.description.caseInsensitiveCompare(description) == .orderedSame
                && (number == nil || $0.number == nil || $0.number == number)
        }
        return sameWords.count == 1 ? sameWords[0] : nil
    }

    private enum Whole {
        case absent
        case value(StockQuantity)
        case invalid
    }

    /// "" is absent; "4" and "4.0" are 4; anything negative, fractional, not a number or more than
    /// a million is invalid. The workbook holds whole units; the figure comes back in thousandths.
    private static func wholeNumber(_ raw: String) -> Whole {
        guard !raw.isEmpty else { return .absent }
        if let value = Int(raw) {
            return (0...StockQuantity.maximumUnits).contains(value) ? .value(StockQuantity(whole: value)) : .invalid
        }
        if let value = Double(raw), value >= 0, value == value.rounded(), value < 1_000_000 {
            return .value(StockQuantity(whole: Int(value)))
        }
        return .invalid
    }
}
