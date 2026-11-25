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
        let lots = Dictionary(log.lots.map { ($0.id, $0.code) }) { first, _ in first }
        for movement in log.movements.reversed().prefix(2_000) where movement.kind != .reversed {
            history.append([
                .text(stamp(movement.at, calendar)),
                .text(names[movement.itemID] ?? ""),
                .text(Self.what(movement, lots: lots) + (reversed.contains(movement.id) ? " (taken back)" : "")),
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

    /// A figure as the workbook holds it: a number cell in units of the line, exactly
    /// (`<v>4.25</v>`; a whole figure is `<v>4</v>`, as every workbook has had). The workbook holds
    /// what a person reads, never thousandths, so it needs no scale marker.
    /// The History sheet's "What": the kind as it always was ("used", "loaded"), with a waste's
    /// reason and the lot a movement names (Plan MY): "wasted (cold_chain) · lot ZZ1001". A
    /// movement with neither reads exactly as before.
    static func what(_ movement: VanStockMovement, lots: [String: String]) -> String {
        var text = movement.kind.rawValue
        if movement.kind == .wasted, let reason = movement.wasteReason { text += " (\(reason.rawValue))" }
        if let lotID = movement.lotID, let code = lots[lotID] { text += " · lot \(code)" }
        return text
    }

    static func figure(_ quantity: StockQuantity) -> XLSX.Cell {
        .decimal(quantity)
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
            /// Short forms and brand names the sheet gave for it, kept as its codes.
            var otherNames: [String] = []
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
                /// A figure the line's unit cannot hold: negative, not a number, over a million,
                /// more than 3 decimal places, or part of one for `each` and `pack`. The column,
                /// what it held, and the unit it was read in.
                case notAQuantity(column: String, value: String, unit: VanStockUnit)
                case unknownUnit(String)
                case noPartNumberOrDescription
                /// The same line appears on an earlier row.
                case repeatsRow(Int)
            }

            let row: Int
            let reason: Reason
            /// What the row names, for a figure refused on it: "Engine oil".
            var name: String?
            var id: Int { row }

            init(row: Int, reason: Reason, name: String? = nil) {
                self.row = row
                self.reason = reason
                self.name = name
            }

            /// Why a figure was refused, read again from what the cell held in its unit.
            var quantityRefusal: StockQuantityRefusal? {
                guard case .notAQuantity(_, let value, let unit) = reason,
                      case .refused(let why) = VanStockSheet.quantity(value, unit: unit) else { return nil }
                return why
            }
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

    /// The header words a sheet somebody else wrote may use. A clinic's tariff (billing) code is
    /// the line's number, so the daily check against its records lines up with what it claims
    /// (Plan MY §8).
    static let headerSynonyms: [Column: Set<String>] = [
        .itemID: ["item id"],
        .partNumber: ["part", "part number", "part no", "part #", "item", "number", "sku",
                      "code", "item code", "product code", "tariff", "tariff code", "billing code", "fee code"],
        .description: ["description", "desc", "name", "item description"],
        .onHand: ["on hand", "qty", "quantity", "count", "stock"],
        .unit: ["unit", "units", "uom"],
        .standard: ["standard", "par", "stock to", "standard load"],
        .minimum: ["min", "minimum", "reorder point"],
        .bin: ["bin", "location", "shelf"],
    ]

    /// Headers whose cells are other names for a line: a short form ("Inf-IM") or brand names
    /// ("Fluviral, Fluzone®"). Read in only; a sheet may have several, and each name becomes one
    /// of the line's codes, which the daily check against the clinic's records matches its words
    /// against (Plan MY §8). Never written out: the workbook's own columns are `Column`.
    static let otherNamesHeaders: Set<String> = [
        "abbreviation", "abbrev", "short name", "also known as", "aka", "other names", "aliases",
        "brand", "brands", "brand name", "brand names", "trade name", "trade names",
    ]

    /// The most other names one row may give, and the longest one: a cell that holds more is
    /// not a list of names.
    static let otherNamesLimit = 12
    static let otherNameLengthLimit = 60
    private static let trademarkSigns: Set<Unicode.Scalar> = ["\u{00AE}", "\u{2122}", "\u{00A9}"]

    /// The names in an other-names cell: split at commas, semicolons and line breaks, with the
    /// trademark signs dropped ("Fluzone®" is "Fluzone"). A slash stays, as brand names use one
    /// ("Infanrix-IPV/Hib").
    static func otherNames(in cell: String) -> [String] {
        cell.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { name in
                var kept = String.UnicodeScalarView()
                kept.append(contentsOf: name.unicodeScalars.filter { !trademarkSigns.contains($0) })
                return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            .filter { !$0.isEmpty && $0.count <= otherNameLengthLimit }
    }

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
        /// Every name the row's other-names columns give, in order, each once.
        var otherNames: [String] = []

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
        guard let sheet, let (headerIndex, columns, otherNameColumns) = header(in: sheet.rows) else {
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

            // The unit first: it decides which figures the row may hold (Plan ML §4). A row with no
            // unit reads its figures to the finest step; they are held to the line's unit once it is
            // known (`stepRefusal`).
            var refusal: Proposal.Refusal.Reason?
            var unit: VanStockUnit?
            if let raw = cell(.unit), !raw.isEmpty {
                unit = VanStockUnit(spoken: raw)
                if unit == nil { refusal = .unknownUnit(raw) }
            }
            var numbers: [Column: StockQuantity?] = [:]
            if refusal == nil {
                let readIn = unit ?? Self.finestUnit
                for column in [Column.onHand, .minimum, .standard, .onOrder] {
                    guard let raw = cell(column) else { continue }
                    switch quantity(raw, unit: readIn) {
                    case .absent: numbers[column] = .some(nil)
                    case .value(let value): numbers[column] = .some(value)
                    // On order is worked out by the phone; whatever was typed over it is not a
                    // reason to leave the row out.
                    case .refused where column == .onOrder: numbers[column] = .some(nil)
                    case .refused:
                        if refusal == nil { refusal = .notAQuantity(column: column.rawValue, value: raw, unit: readIn) }
                    }
                }
            }
            if let refusal {
                read.refusals.append(.init(row: rowNumber, reason: refusal, name: Self.refusalName(described, normalised)))
                continue
            }
            var otherNames: [String] = []
            for index in otherNameColumns where index < cells.count {
                for name in Self.otherNames(in: cells[index]) where !otherNames.contains(name) {
                    otherNames.append(name)
                }
            }
            read.rows.append(Row(
                number: rowNumber, itemID: cell(.itemID).flatMap { $0.isEmpty ? nil : $0 },
                partNumber: normalised, description: described, unit: unit,
                onHandCell: numbers[.onHand], minimumCell: numbers[.minimum], standardCell: numbers[.standard],
                onOrder: numbers[.onOrder] ?? nil,
                needsCount: (cell(.needsCount) ?? "").lowercased() == "yes",
                standardSetByBase: setByOutsideWords.contains((cell(.standardSetBy) ?? "").lowercased()),
                binCell: cell(.bin), otherNames: Array(otherNames.prefix(otherNamesLimit))))
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
            // A row that gave no unit holds its figures to the line's own, or to each for a new line.
            if let refusal = stepRefusal(row, unit: row.unit ?? existing?.unit ?? .each) {
                proposal.refusals.append(refusal)
                continue
            }
            guard let item = existing else {
                guard row.partNumber != nil || row.description != nil else {
                    proposal.refusals.append(.init(row: row.number, reason: .noPartNumberOrDescription))
                    continue
                }
                proposal.newLines.append(.init(
                    row: row.number, number: row.partNumber, description: row.description ?? "",
                    unit: row.unit ?? .each, onHand: row.onHand, minimum: row.minimum,
                    standard: row.standard, bin: row.bin, otherNames: row.otherNames))
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
            // Names are only ever added: a sheet without one leaves the line's codes as they are.
            for name in row.otherNames where !item.codes.contains(name) { changes.append(.addCode(name)) }
            if !changes.isEmpty { proposal.edits.append(.init(itemID: item.id, name: item.name, changes: changes)) }
        }

        proposal.refusals.sort { $0.row < $1.row }
        if read.isOwn { proposal.missing = log.items.filter { seen[$0.id] == nil } }
        return .success(proposal)
    }

    /// Apply a proposal as one batch. `keepingPhoneFigure` names the lines, among those that moved
    /// since the export, where the technician chose the phone's figure over the sheet's.
    ///
    /// A row's own figures and its unit are applied in the order that lets them all stand: a line
    /// moved to a measured unit changes unit first, so 4.25 can then be kept; a line moved to
    /// `each` or `pack` takes the row's count, minimum and standard first, so the unit change
    /// finds whole figures and is not refused for the 4.25 the row is replacing.
    static func apply(_ proposal: Proposal, to log: inout VanStockLog, keepingPhoneFigure: Set<String> = [],
                      at: Date, batch: String, verify: (String) -> TaskPart,
                      makeID: () -> String = { UUID().uuidString }) {
        let counts = proposal.counts.filter { !($0.movedSinceExport && keepingPhoneFigure.contains($0.itemID)) }
        var countedEarly = Set<String>()
        func apply(_ change: VanStockLog.Change, to itemID: String) {
            log.edit(itemID: itemID, change, at: at, batch: batch, source: .sheet, id: makeID())
            if case .number(let number) = change {
                log.edit(itemID: itemID, .verified(number.map { verify($0).verified } ?? false),
                         at: at, batch: batch, source: .sheet, id: makeID())
            }
        }
        for edit in proposal.edits {
            let toWhole = edit.changes.contains { if case .unit(let unit) = $0 { return !unit.allowsFraction } else { return false } }
            guard toWhole else {
                edit.changes.forEach { apply($0, to: edit.itemID) }
                continue
            }
            let isUnit: (VanStockLog.Change) -> Bool = { if case .unit = $0 { return true } else { return false } }
            edit.changes.filter { !isUnit($0) }.forEach { apply($0, to: edit.itemID) }
            if let count = counts.first(where: { $0.itemID == edit.itemID }) {
                log.record(.counted, itemID: count.itemID, quantity: count.to, at: at, batch: batch, source: .sheet, id: makeID())
                countedEarly.insert(count.itemID)
            }
            edit.changes.filter(isUnit).forEach { apply($0, to: edit.itemID) }
        }
        for line in proposal.newLines {
            let checked = line.number.map(verify)
            let item = log.addItem(id: makeID(), number: line.number,
                                   description: line.description.isEmpty ? (checked?.partDescription ?? "") : line.description,
                                   unit: line.unit, minimum: line.minimum, standard: line.standard,
                                   standardSetBy: line.standard == nil ? nil : .van, bin: line.bin,
                                   codes: line.otherNames,
                                   verified: checked?.verified ?? false, batch: batch)
            if let onHand = line.onHand {
                log.record(.counted, itemID: item.id, quantity: onHand, at: at, batch: batch, source: .sheet, id: makeID())
            } else {
                // Nothing counted, so note the line's unit: the batch then has an entry an undo can find.
                log.appendNote(itemID: item.id, at: at, batch: batch, source: .sheet, id: makeID())
            }
        }
        for count in counts where !countedEarly.contains(count.itemID) {
            log.record(.counted, itemID: count.itemID, quantity: count.to, at: at, batch: batch, source: .sheet, id: makeID())
        }
    }

    // MARK: - Reading a sheet

    /// The header row, where each recognised column is, and the other-names columns. A header
    /// names a part or a description and at least one of the figures, or, for a list of what is
    /// kept with no figures yet (a clinic's vaccine list), both a part and a description: its
    /// levels come from the first count.
    private static func header(in rows: [[String]]) -> (Int, [Column: Int], [Int])? {
        for (offset, row) in rows.prefix(10).enumerated() {
            var found: [Column: Int] = [:]
            var otherNames: [Int] = []
            for (index, raw) in row.enumerated() {
                let word = headerWord(raw)
                guard !word.isEmpty else { continue }
                if otherNamesHeaders.contains(word) {
                    otherNames.append(index)
                    continue
                }
                guard let column = headerSynonyms.first(where: { $0.value.contains(word) })?.key
                        ?? Column.allCases.first(where: { $0.rawValue.lowercased() == word }),
                      found[column] == nil else { continue }
                found[column] = index
            }
            let namesALine = found[.partNumber] != nil || found[.description] != nil
            let hasAFigure = found[.onHand] != nil || found[.standard] != nil || found[.minimum] != nil
            let isACatalogue = found[.partNumber] != nil && found[.description] != nil
            if namesALine && (hasAFigure || isACatalogue) { return (offset, found, otherNames) }
        }
        return nil
    }

    /// A header cell as the synonyms are written: lower case, with a note in brackets dropped
    /// ("Brand Names (all formulations)" is "brand names") and punctuation trimmed from the ends.
    static func headerWord(_ raw: String) -> String {
        let beforeNote = raw.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        return beforeNote.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
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

    /// A figure cell, read.
    enum Figure: Equatable {
        case absent
        case value(StockQuantity)
        case refused(StockQuantityRefusal)
    }

    /// The unit a row that names none has its figures read in: any measured unit, the finest
    /// step. They are held to the line's own unit once the row is matched (`stepRefusal`).
    static let finestUnit = VanStockUnit.m

    /// "" is absent. Otherwise a figure in units of the line, exactly as `StockQuantity.parse`
    /// reads it: up to 3 decimal places for a measured unit and a whole number for `each` and
    /// `pack` ("4", "4.0" and "4.250" are fine). Two spellings come only from how a spreadsheet
    /// stores a number, and are read through `parse(number:unit:)`: an exponent (`4.25E-1`), and
    /// the binary noise a formula leaves (`4.2499999999999991` is 4.25), within a thousandth of a
    /// thousandth. "4.2513", "2.5" packs, a negative, words and over a million are refused.
    static func quantity(_ raw: String, unit: VanStockUnit) -> Figure {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .absent }
        var result = StockQuantity.parse(trimmed, unit: unit)
        if case .failure = result, isStoredNumber(trimmed), let stored = Double(trimmed) {
            result = StockQuantity.parse(number: stored, unit: unit)
        }
        switch result {
        case .success(let value): return .value(value)
        case .failure(let why): return .refused(why)
        }
    }

    /// A number as a spreadsheet stores it: digits, at most one point, and an optional exponent.
    /// Never a sign, a hexadecimal, "inf" or "nan", which `Double(_:)` would also take.
    private static func isStoredNumber(_ text: String) -> Bool {
        text.range(of: #"^(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil
    }

    /// What a refused row is called on the review: its description, else its part number.
    static func refusalName(_ description: String?, _ number: String?) -> String? {
        description ?? number
    }

    /// The first of a row's figures its line's unit cannot hold, as the row's refusal. On order
    /// is the phone's own figure and is never a reason.
    static func stepRefusal(_ row: Row, unit: VanStockUnit) -> Proposal.Refusal? {
        let figures: [(Column, StockQuantity?)] = [(.onHand, row.onHand), (.minimum, row.minimum), (.standard, row.standard)]
        for (column, value) in figures {
            guard let value, !value.fits(unit) else { continue }
            return .init(row: row.number,
                         reason: .notAQuantity(column: column.rawValue, value: value.decimalString, unit: unit),
                         name: refusalName(row.description, row.partNumber))
        }
        return nil
    }
}
