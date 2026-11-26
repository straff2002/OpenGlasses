import Foundation

// Plan NF — the crew experience sheet: a company's own fixes, kept in a spreadsheet and answered
// beside the manuals. The contract is `Contracts/crew-experience.md`; the golden fixtures are
// `Contracts/fixtures/crew-experience-v1/`, read by this package's tests and the app's.
//
// The sheet is the way in, never what is searched. The portal converts an uploaded `.xlsx` to CSV in
// the browser; this file reads that one strict CSV dialect, holds every row to the template's rules
// (each refusal by name, with its sheet row number), and turns the rows that pass into learning
// entries (`Contracts/team-learning.md` §5, origin `recollection`). The phone receives entries, never
// a spreadsheet. Plan NG P0b: the same set also carries learnings an administrator approved in the
// portal (origin `spoken`, with their candidate and jobs), and FP's merge rule (`CrewExperienceMerge`).
//
// **Foundation only, self-contained with `VaultStarter.swift`** (whose `Model`, `Output`,
// `normalised` and manifest it reuses). It refers to nothing else in this package, so the app can
// compile it into its own target the way it compiles `VaultDrafts.swift` (Plan NF §9), and the
// service compiles it on Linux. Deterministic: the same bytes give the same rows; the one random
// thing, a new row's id, comes from the caller's `newID`.

// MARK: - The sheet

public enum CrewExperienceSheet {

    // MARK: Identifiers and words

    /// The set's `kind`. **A wire identifier, not a product name: never change it.**
    public static let setKind = "avenkin.crew-experience-set"
    public static let setVersion = 1
    /// The seal's domain (contract §6). The set is sealed with the company secret the way a manual
    /// is, under this domain of its own, so neither file opens as the other.
    public static let sealDomain = "openglasses.crew-experience-set.v1"
    /// Every sheet entry's `origin` (team-learning amendment): known before a recorded job confirmed it.
    public static let origin = "recollection"
    /// The `origin` of a learning a technician filed on a job and an administrator approved in the
    /// portal (Plan NG P0b; team-learning §12.5). It carries its `candidateID` and the jobs it was
    /// filed on, and is cited as a team learning, not as crew experience.
    public static let spokenOrigin = "spoken"
    /// What every crew-experience citation begins with (team-learning §7.1 amendment).
    public static let citationPrefix = "Crew experience · "
    /// What a `spoken` entry's citation begins with: team-learning §7.1's own prefix, the phone's
    /// `TeamLearningCitation.prefix`.
    public static let teamLearningCitationPrefix = "Team learning · "
    /// The sentence an answer that rests on crew experience alone opens with.
    public static let leadIn = "From your company's experience (not the manufacturer's manual):"
    /// The `how_sure` wordings the template offers. Any other words up to the limit are accepted.
    public static let howSureChoices = ["fixed it every time", "fixed it most times", "fixed it once"]

    /// `Crew experience · <model, or equipment type, or topic> · <YYYY-MM-DD UTC> · approved by <role>`.
    public static func citationName(subject: String, approvedAt: Int64, role: String) -> String {
        citationPrefix + "\(subject) · \(utcDate(approvedAt)) · approved by \(role)"
    }

    /// `Team learning · <subject> · <YYYY-MM-DD UTC> · approved by <role>`: a `spoken` entry's (§7.1).
    public static func teamLearningCitationName(subject: String, approvedAt: Int64, role: String) -> String {
        teamLearningCitationPrefix + "\(subject) · \(utcDate(approvedAt)) · approved by \(role)"
    }

    /// `YYYY-MM-DD` in UTC for Unix seconds, by arithmetic: no calendar, no locale, no zone.
    public static func utcDate(_ seconds: Int64) -> String {
        // Days since 1970-01-01, then the civil date (Howard Hinnant's algorithm).
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func pad(_ value: Int64, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    // MARK: Limits (decision 13)

    public enum Limits {
        /// Rows in one sheet, and entries in one set: the learning set's cap.
        public static let rows = 5_000
        /// One uploaded CSV, and one encoded set.
        public static let bytes = 2 * 1_048_576
        /// The approver's role, as the citation carries it (team-learning §5).
        public static let role = 80
    }

    // MARK: Columns (§2 of the contract)

    /// The template's columns, by their fixed English keys.
    public enum Column: String, CaseIterable, Codable, Sendable {
        case id
        case brand
        case model
        case equipmentType = "equipment_type"
        case faultCode = "fault_code"
        case symptom
        case checked
        case fix
        case notes
        case howSure = "how_sure"
        case addedBy = "added_by"
        case date

        /// The most a cell may hold, in Unicode scalars, after redaction.
        public var limit: Int {
            switch self {
            case .id: return 32
            case .brand, .model, .equipmentType: return 80
            case .faultCode: return 40
            case .symptom, .checked, .fix: return 500
            case .notes: return 2_000
            case .howSure, .addedBy: return 120
            case .date: return 40
            }
        }

        /// Only `notes` (the entry's `finding`) keeps a line break; elsewhere it becomes a space.
        public var keepsLineBreaks: Bool { self == .notes }

        /// The free-text columns the redaction pass reads. The others are identity (brand, model,
        /// type, code), the author's own name (never published) or machine values.
        public var isRedacted: Bool { [.symptom, .checked, .fix, .notes, .howSure].contains(self) }

        /// How the preview names the column.
        public var spoken: String {
            switch self {
            case .id: return "id"
            case .brand: return "brand"
            case .model: return "model"
            case .equipmentType: return "equipment type"
            case .faultCode: return "fault code"
            case .symptom: return "symptom"
            case .checked: return "list of checks"
            case .fix: return "fix"
            case .notes: return "notes"
            case .howSure: return "how sure"
            case .addedBy: return "added by"
            case .date: return "date"
            }
        }

        /// A header cell as written, made comparable: trimmed, lowercased, spaces and hyphens as
        /// underscores (so "Fault code" and "fault-code" read as `fault_code`).
        static func key(_ header: String) -> String {
            header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).joined(separator: "_")
        }
    }

    // MARK: The vault a sheet is for

    /// What the parser needs to know about the one vault a sheet belongs to (decision 10).
    public struct Vault: Codable, Equatable, Sendable {
        public let vaultId: String
        /// Every spelling of every model the vault knows, as its model index has them (headings of
        /// the core and of `crew-models.md`). A row's model is matched to these and stored as the
        /// vault's own spelling.
        public let modelSpellings: [String]
        /// The vault's closed list of equipment types. Empty: no row may name one alone.
        public let equipmentTypes: [String]
        /// The ids in the set currently published for the vault. When given, a row's `id` must be
        /// one of them; nil skips the check (a first upload).
        public let currentEntryIDs: [String]?

        public init(vaultId: String, modelSpellings: [String], equipmentTypes: [String] = [],
                    currentEntryIDs: [String]? = nil) {
            self.vaultId = vaultId
            self.modelSpellings = modelSpellings
            self.equipmentTypes = equipmentTypes
            self.currentEntryIDs = currentEntryIDs
        }
    }

    // MARK: Refusals

    /// Why a whole sheet is refused: nothing in it is read.
    public enum SheetRefusal: Error, Equatable, Sendable {
        /// Not UTF-8.
        case notUTF8
        /// Over `Limits.bytes`.
        case tooLarge(bytes: Int)
        /// No header row.
        case noHeader
        /// A required column is missing (`symptom`, `fix`).
        case missingColumn(String)
        /// Neither `model` nor `equipment_type` is a column.
        case noSubjectColumn
        /// A template column is named twice.
        case duplicateColumn(String)
        /// A quoted cell runs to the end of the file. `row` is where it started.
        case unterminatedQuote(row: Int)
        /// A quote inside an unquoted cell, or text after a closing quote.
        case strayQuote(row: Int)
        /// More than `Limits.rows` rows below the header.
        case tooManyRows(count: Int)

        /// The stable name the fixtures and the portal key on.
        public var name: String {
            switch self {
            case .notUTF8: return "notUTF8"
            case .tooLarge: return "tooLarge"
            case .noHeader: return "noHeader"
            case .missingColumn: return "missingColumn"
            case .noSubjectColumn: return "noSubjectColumn"
            case .duplicateColumn: return "duplicateColumn"
            case .unterminatedQuote: return "unterminatedQuote"
            case .strayQuote: return "strayQuote"
            case .tooManyRows: return "tooManyRows"
            }
        }

        /// The preview's words.
        public var message: String {
            switch self {
            case .notUTF8: return "The file is not UTF-8 text. Save it as \"CSV UTF-8\" and upload it again."
            case .tooLarge(let bytes): return "The file is \(bytes) bytes; a sheet may be at most \(Limits.bytes)."
            case .noHeader: return "The file is empty: the first row must be the column names."
            case .missingColumn(let name): return "There is no \(name) column."
            case .noSubjectColumn: return "There is no model column and no equipment_type column; a sheet needs at least one."
            case .duplicateColumn(let name): return "The \(name) column appears twice."
            case .unterminatedQuote(let row): return "Row \(row): a quoted cell is never closed."
            case .strayQuote(let row): return "Row \(row): a quote mark sits inside a cell that is not quoted."
            case .tooManyRows(let count): return "The sheet has \(count) rows; at most \(Limits.rows)."
            }
        }
    }

    /// Why one row cannot be published. The row is shown with its number and every reason.
    public enum Problem: Equatable, Sendable {
        /// No model and no equipment type.
        case noSubject
        /// The model is not one the vault knows. `nearest` is the vault's closest spelling, if any
        /// is close; the administrator fixes the spelling or adds it as a model the company services.
        case unknownModel(nearest: String?)
        /// The equipment type is not on the vault's list.
        case unknownEquipmentType
        case missingSymptom
        case missingFix
        /// Over the column's limit. For `symptom`, `count` includes the fault code put in front.
        case tooLong(Column, count: Int, limit: Int)
        /// A control character (other than a tab or line break) or a bidirectional override.
        case controlCharacter(Column)
        /// The id is not 32 lowercase hexadecimal characters.
        case badId
        /// Another row above has the same id.
        case duplicateId
        /// The id is not in the set currently published for the vault.
        case unknownId
        /// `how_sure` is a number; it is said in words ("fixed it most times").
        case howSureIsANumber
        /// The date is not `YYYY-MM-DD`.
        case badDate
        /// The row has cells beyond the last column.
        case extraCells

        /// The stable name the fixtures and the portal key on.
        public var name: String {
            switch self {
            case .noSubject: return "noSubject"
            case .unknownModel: return "unknownModel"
            case .unknownEquipmentType: return "unknownEquipmentType"
            case .missingSymptom: return "missingSymptom"
            case .missingFix: return "missingFix"
            case .tooLong: return "tooLong"
            case .controlCharacter: return "controlCharacter"
            case .badId: return "badId"
            case .duplicateId: return "duplicateId"
            case .unknownId: return "unknownId"
            case .howSureIsANumber: return "howSureIsANumber"
            case .badDate: return "badDate"
            case .extraCells: return "extraCells"
            }
        }

        /// The column the problem is in, when it is in one.
        public var column: Column? {
            switch self {
            case .unknownModel: return .model
            case .unknownEquipmentType: return .equipmentType
            case .missingSymptom: return .symptom
            case .missingFix: return .fix
            case .tooLong(let column, _, _), .controlCharacter(let column): return column
            case .badId, .duplicateId, .unknownId: return .id
            case .howSureIsANumber: return .howSure
            case .badDate: return .date
            case .noSubject, .extraCells: return nil
            }
        }

        /// The preview's words, after "Row <n>: ".
        public var message: String {
            switch self {
            case .noSubject: return "no model and no equipment type."
            case .unknownModel(let nearest):
                if let nearest { return "this vault has no model by that spelling. Did you mean \(nearest)?" }
                return "this vault has no model by that spelling. Fix it, or add it as a model you service."
            case .unknownEquipmentType: return "the equipment type is not one of this vault's."
            case .missingSymptom: return "no symptom."
            case .missingFix: return "no fix."
            case .tooLong(let column, let count, let limit):
                if column == .symptom {
                    return "the symptom is \(count) characters with the fault code in front; at most \(limit)."
                }
                return "the \(column.spoken) is \(count) characters; at most \(limit)."
            case .controlCharacter(let column): return "the \(column.spoken) holds a character that can't be published."
            case .badId: return "the id has been changed; leave it as it was downloaded, or empty for a new row."
            case .duplicateId: return "another row has the same id."
            case .unknownId: return "the id is not one of this vault's published rows; empty it to add the row as new."
            case .howSureIsANumber: return "say how sure in words, for example \"fixed it most times\"."
            case .badDate: return "the date must be written YYYY-MM-DD."
            case .extraCells: return "there are cells beyond the last column."
            }
        }
    }

    /// A redaction the pass made in one cell: the pattern names, never the text they matched.
    public struct Redaction: Codable, Equatable, Sendable {
        public let column: Column
        public let patterns: [String]
    }

    // MARK: Rows

    public enum Status: String, Codable, Sendable {
        /// Publishable as written.
        case ready
        /// Has at least one problem: never published.
        case toFix = "to_fix"
        /// Publishable, but the redaction pass changed it: marked in the preview, never silent.
        case changedByRedaction = "changed_by_redaction"
    }

    /// One row as the preview shows it and as `entries(from:approvedBy:)` reads it. Values are the
    /// cleaned, redacted text; nil when the cell was empty.
    public struct Row: Equatable, Sendable {
        /// The sheet's own row number: the header is row 1.
        public let number: Int
        public let id: String?
        public let brand: String?
        /// The vault's own spelling of the row's model.
        public let modelToken: String?
        /// The vault's own spelling of the row's equipment type.
        public let equipmentType: String?
        public let faultCode: String?
        /// As the entry carries it: the fault code in front when the symptom does not already say it.
        public let symptom: String?
        public let checked: String?
        public let fix: String?
        /// The notes, or "<fault code>: <fix>" when there are none.
        public let finding: String?
        public let howSure: String?
        public let addedBy: String?
        /// `YYYY-MM-DD`, shown to the reviewer only.
        public let date: String?
        public let problems: [Problem]
        public let redactions: [Redaction]

        public var status: Status {
            if !problems.isEmpty { return .toFix }
            return redactions.isEmpty ? .ready : .changedByRedaction
        }

        /// Ready or changed by redaction: what publishing approves.
        public var isPublishable: Bool { problems.isEmpty }
    }

    /// A sheet read whole.
    public struct Parsed: Equatable, Sendable {
        public let vaultId: String
        /// Every non-blank row below the header, in sheet order.
        public let rows: [Row]
        /// Header cells that are not template columns, as written, in sheet order. Ignored, and named.
        public let ignoredColumns: [String]

        public var ready: [Row] { rows.filter { $0.status == .ready } }
        public var toFix: [Row] { rows.filter { $0.status == .toFix } }
        public var changedByRedaction: [Row] { rows.filter { $0.status == .changedByRedaction } }
    }

    // MARK: - Parsing

    /// Read a sheet for `vault`. Throws `SheetRefusal` when the file itself cannot be read; every
    /// problem with a row is on that row.
    public static func parse(csv data: Data, vault: Vault) throws -> Parsed {
        guard data.count <= Limits.bytes else { throw SheetRefusal.tooLarge(bytes: data.count) }
        guard var text = String(data: data, encoding: .utf8) else { throw SheetRefusal.notUTF8 }
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        let records = try CSV.records(in: text)
        guard let header = records.first, header.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SheetRefusal.noHeader
        }

        var columns: [Int: Column] = [:]
        var ignored: [String] = []
        var seen = Set<Column>()
        for (index, cell) in header.enumerated() {
            let key = Column.key(cell)
            if let column = Column(rawValue: key) {
                guard seen.insert(column).inserted else { throw SheetRefusal.duplicateColumn(column.rawValue) }
                columns[index] = column
            } else if !key.isEmpty {
                ignored.append(cell.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        for required in [Column.symptom, .fix] where !seen.contains(required) {
            throw SheetRefusal.missingColumn(required.rawValue)
        }
        guard seen.contains(.model) || seen.contains(.equipmentType) else { throw SheetRefusal.noSubjectColumn }

        let body = records.dropFirst()
        let nonBlank = body.filter { !isBlank($0) }
        guard nonBlank.count <= Limits.rows else { throw SheetRefusal.tooManyRows(count: nonBlank.count) }

        let spellings = vault.modelSpellings
        let known = Set(vault.currentEntryIDs ?? [])
        var idsAbove = Set<String>()
        var rows: [Row] = []
        for (offset, record) in body.enumerated() where !isBlank(record) {
            let number = offset + 2
            var problems: [Problem] = []
            var redactions: [Redaction] = []
            var values: [Column: String] = [:]
            // Cells refused for a control character: present, so not also reported as missing.
            var refused = Set<Column>()

            for (index, cell) in record.enumerated() {
                guard let column = columns[index] else { continue }
                guard let plain = CrewText.normalise(cell, keepsLineBreaks: column.keepsLineBreaks) else {
                    problems.append(.controlCharacter(column))
                    refused.insert(column)
                    continue
                }
                guard !plain.isEmpty else { continue }
                var value = plain
                if column.isRedacted {
                    let (redacted, hits) = CrewExperienceRedaction.redact(plain)
                    if !hits.isEmpty { redactions.append(Redaction(column: column, patterns: hits)); value = redacted }
                }
                values[column] = value
            }
            if record.count > header.count,
               record[header.count...].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                problems.append(.extraCells)
            }

            // Lengths, in column order, on what would be stored.
            for column in Column.allCases where column != .symptom {
                if let value = values[column], CrewText.length(value) > column.limit {
                    problems.append(.tooLong(column, count: CrewText.length(value), limit: column.limit))
                }
            }

            // The id.
            var id: String?
            if let raw = values[.id] {
                if !isEntryID(raw) {
                    problems.append(.badId)
                } else if !idsAbove.insert(raw).inserted {
                    problems.append(.duplicateId)
                } else if vault.currentEntryIDs != nil, !known.contains(raw) {
                    problems.append(.unknownId)
                }
                id = raw
            }

            // The subject.
            var modelToken: String?
            if let raw = values[.model] {
                if let spelling = vaultSpelling(of: raw, among: spellings) {
                    modelToken = spelling
                } else {
                    problems.append(.unknownModel(nearest: nearestSpelling(to: raw, among: spellings)))
                }
            }
            var equipmentType: String?
            if let raw = values[.equipmentType] {
                let wanted = collapsed(raw).lowercased()
                if let match = vault.equipmentTypes.first(where: { collapsed($0).lowercased() == wanted }) {
                    equipmentType = match
                } else {
                    problems.append(.unknownEquipmentType)
                }
            }
            func present(_ column: Column) -> Bool { values[column] != nil || refused.contains(column) }
            if !present(.model) && !present(.equipmentType) { problems.append(.noSubject) }

            // What was seen and done.
            let faultCode = values[.faultCode]
            var symptom: String?
            if let raw = values[.symptom] {
                let composed = composedSymptom(raw, faultCode: faultCode)
                if CrewText.length(composed) > Column.symptom.limit {
                    problems.append(.tooLong(.symptom, count: CrewText.length(composed), limit: Column.symptom.limit))
                }
                symptom = composed
            } else if !present(.symptom) {
                problems.append(.missingSymptom)
            }
            if !present(.fix) { problems.append(.missingFix) }
            let finding = values[.notes] ?? values[.fix].map { fix in faultCode.map { "\($0): \(fix)" } ?? fix }

            if let howSure = values[.howSure], isNumber(howSure) { problems.append(.howSureIsANumber) }
            var date: String?
            if let raw = values[.date] {
                if let day = isoDay(raw) { date = day } else { problems.append(.badDate) }
            }

            rows.append(Row(number: number, id: id, brand: values[.brand], modelToken: modelToken,
                            equipmentType: equipmentType, faultCode: faultCode, symptom: symptom,
                            checked: values[.checked], fix: values[.fix], finding: finding,
                            howSure: values[.howSure], addedBy: values[.addedBy], date: date,
                            problems: problems, redactions: redactions))
        }
        return Parsed(vaultId: vault.vaultId, rows: rows, ignoredColumns: ignored)
    }

    static func isBlank(_ record: [String]) -> Bool {
        record.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The symptom as the entry carries it: "<code>: <symptom>" unless it already names the code,
    /// so a search for the code finds the case (§2).
    static func composedSymptom(_ symptom: String, faultCode: String?) -> String {
        guard let code = faultCode, symptom.range(of: code, options: .caseInsensitive) == nil else { return symptom }
        return "\(code): \(symptom)"
    }

    /// A model spelling as the matcher compares it: uppercased, without hyphens or spaces.
    static func spellingKey(_ text: String) -> String {
        String(text.uppercased().unicodeScalars.filter { $0 != "-" && !CharacterSet.whitespaces.contains($0) }
            .map(Character.init))
    }

    /// The vault's own spelling of `raw`, or nil when it knows none.
    static func vaultSpelling(of raw: String, among spellings: [String]) -> String? {
        let key = spellingKey(raw)
        guard !key.isEmpty else { return nil }
        return spellings.first { spellingKey($0) == key }
    }

    /// The vault's closest spelling, when one is a small edit away: at most two changes, or a
    /// quarter of the spelling's length if that is more. Ties go to the vault's first spelling.
    static func nearestSpelling(to raw: String, among spellings: [String]) -> String? {
        let key = Array(spellingKey(raw))
        guard !key.isEmpty else { return nil }
        var best: (spelling: String, distance: Int)?
        for spelling in spellings {
            let candidate = Array(spellingKey(spelling))
            let distance = editDistance(key, candidate)
            let allowed = max(2, candidate.count / 4)
            guard distance <= allowed else { continue }
            if best == nil || distance < best!.distance { best = (spelling, distance) }
        }
        return best?.spelling
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 32 lowercase hexadecimal characters (team-learning §5 `entryID`).
    public static func isEntryID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// A `how_sure` that is a number, a fraction or a percentage rather than words.
    static func isNumber(_ text: String) -> Bool {
        text.contains(where: \.isNumber)
            && text.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) || " .,%/+-".unicodeScalars.contains($0) }
    }

    /// `YYYY-MM-DD` of a real day, alone or at the front of an ISO 8601 date and time (what a
    /// spreadsheet's date cell converts to). Nil for anything else.
    static func isoDay(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 10 else { return nil }
        let day = String(String.UnicodeScalarView(scalars[0..<10]))
        if scalars.count > 10, scalars[10] != "T", scalars[10] != " " { return nil }
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
              (1...12).contains(month) else { return nil }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...lengths[month - 1]).contains(dayOfMonth) ? day : nil
    }

    // MARK: - Entries

    /// Who publishes: the administrator's portal role (the citation's) and name (matched against
    /// `added_by` for `authorIsApprover`), and when.
    public struct Approval: Codable, Equatable, Sendable {
        public let role: String
        public let name: String?
        /// Unix UTC seconds.
        public let approvedAt: Int64

        public init(role: String, name: String?, approvedAt: Int64) {
            self.role = role
            self.name = name
            self.approvedAt = approvedAt
        }
    }

    /// A new entry id: a UUID's 128 bits as 32 lowercase hex characters.
    public static func mintID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The entries publishing the sheet makes: one per publishable row, in sheet order. A row
    /// without an id gets a new one from `newID`. A row whose id is in `current` and whose content
    /// is unchanged keeps that entry exactly, approval and all, so re-publishing an unedited sheet
    /// changes nothing and `diff` reports it as unchanged.
    public static func entries(from parsed: Parsed, approvedBy approval: Approval,
                               current: [CrewExperienceSet.Entry] = [],
                               newID: () -> String = mintID) -> [CrewExperienceSet.Entry] {
        let held = Dictionary(current.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        let role = String(String.UnicodeScalarView(CrewText.normalise(approval.role, keepsLineBreaks: false).map {
            Array($0.unicodeScalars.prefix(Limits.role))
        } ?? []))
        let approver = approval.name.map { collapsed($0).lowercased() }
        return parsed.rows.filter(\.isPublishable).compactMap { row in
            guard let symptom = row.symptom, let fix = row.fix, let finding = row.finding else { return nil }
            let subject: CrewExperienceSet.Subject
            if let token = row.modelToken {
                subject = .model(modelToken: token, manufacturer: row.brand, equipmentType: row.equipmentType)
            } else if let type = row.equipmentType {
                subject = .symptom(equipmentType: type, phrase: row.faultCode.map { code in
                    symptom.hasPrefix("\(code): ") ? String(symptom.dropFirst(code.count + 2)) : symptom
                } ?? symptom)
            } else {
                return nil
            }
            let author = row.addedBy.map { collapsed($0).lowercased() }
            let id = row.id ?? newID()
            // A row that is a published entry, edited, stays that entry: a learning approved in the
            // portal (origin `spoken`) keeps its origin, its candidate and the jobs it was filed on,
            // and a recollection a job confirmed keeps that job (Plan NG P0b).
            let previous = held[id]
            let made = CrewExperienceSet.Entry(
                entryID: id, subject: subject, vaultIDs: [parsed.vaultId],
                finding: finding, symptom: symptom, fix: fix, faultCode: row.faultCode,
                tried: row.checked, outcome: row.howSure,
                approvedAt: approval.approvedAt, approvedByRole: role,
                authorIsApprover: author != nil && author == approver,
                origin: previous?.origin ?? CrewExperienceSheet.origin,
                candidateID: previous?.candidateID, sourceJobIDs: previous?.sourceJobIDs,
                confirmedJobCount: previous?.confirmedJobCount)
            if let previous, previous.sameContent(as: made) { return previous }
            return made
        }
    }

    /// The sheet a set downloads as (**Download current sheet**): the template's columns with every
    /// entry's id, one row per entry, CRLF line ends. Uploaded again unedited, every row keeps its
    /// entry exactly. `added_by` and `date` are the reviewer's only and are not kept in an entry, so
    /// they come back empty; `notes` is the entry's finding.
    public static func csv(entries: [CrewExperienceSet.Entry]) -> String {
        let header = [Column.id, .brand, .model, .equipmentType, .faultCode, .symptom, .checked, .fix, .notes,
                      .howSure, .addedBy, .date].map(\.rawValue)
        var lines = [header.joined(separator: ",")]
        for entry in entries {
            let brand: String?, model: String?, type: String?
            switch entry.subject {
            case .model(let token, let manufacturer, let equipmentType): brand = manufacturer; model = token; type = equipmentType
            case .symptom(let equipmentType, _): brand = nil; model = nil; type = equipmentType
            }
            let cells: [String?] = [entry.entryID, brand, model, type, entry.faultCode, entry.symptom, entry.tried,
                                    entry.fix, entry.finding, entry.outcome, nil, nil]
            lines.append(cells.map { CSV.cell($0 ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The preview as data: what the portal shows and what the golden fixtures pin.
    public struct Report: Codable, Equatable, Sendable {
        public struct Problem: Codable, Equatable, Sendable {
            public let name: String
            public let column: Column?
            public let count: Int?
            public let limit: Int?
            public let nearest: String?
            /// "Row <n>: <words>".
            public let message: String
        }

        public struct Row: Codable, Equatable, Sendable {
            public let number: Int
            public let status: Status
            public let id: String?
            public let modelToken: String?
            public let equipmentType: String?
            public let problems: [Problem]
            public let redactions: [Redaction]
        }

        public let ignoredColumns: [String]
        public let ready: Int
        public let toFix: Int
        public let changedByRedaction: Int
        public let rows: [Row]
    }

    public static func report(_ parsed: Parsed) -> Report {
        Report(ignoredColumns: parsed.ignoredColumns, ready: parsed.ready.count, toFix: parsed.toFix.count,
               changedByRedaction: parsed.changedByRedaction.count,
               rows: parsed.rows.map { row in
                   Report.Row(number: row.number, status: row.status, id: row.id, modelToken: row.modelToken,
                              equipmentType: row.equipmentType,
                              problems: row.problems.map { problem in
                                  var count: Int?, limit: Int?, nearest: String?
                                  if case .tooLong(_, let c, let l) = problem { count = c; limit = l }
                                  if case .unknownModel(let n) = problem { nearest = n }
                                  return Report.Problem(name: problem.name, column: problem.column, count: count,
                                                        limit: limit, nearest: nearest,
                                                        message: "Row \(row.number): \(problem.message)")
                              },
                              redactions: row.redactions)
               })
    }

    /// What publishing `next` would change against the set now published.
    public struct Diff: Codable, Equatable, Sendable {
        /// Entry ids, in `next` order.
        public let new: [String]
        public let changed: [String]
        /// In `current` order.
        public let removed: [String]
        public let unchanged: [String]

        /// "6 new, 1 changed, 0 removed".
        public var summary: String { "\(new.count) new, \(changed.count) changed, \(removed.count) removed" }
    }

    public static func diff(current: [CrewExperienceSet.Entry], next: [CrewExperienceSet.Entry]) -> Diff {
        let held = Dictionary(current.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        let nextIds = Set(next.map(\.entryID))
        var new: [String] = [], changed: [String] = [], unchanged: [String] = []
        for entry in next {
            guard let previous = held[entry.entryID] else { new.append(entry.entryID); continue }
            if previous == entry { unchanged.append(entry.entryID) } else { changed.append(entry.entryID) }
        }
        return Diff(new: new, changed: changed, removed: current.map(\.entryID).filter { !nextIds.contains($0) },
                    unchanged: unchanged)
    }
}

// MARK: - The set (contract §5)

/// The file a phone receives for one vault: the team-learning contract's learning set (§5) with
/// `kind: avenkin.crew-experience-set`, bound to one company profile and one vault instead of an
/// office. Applied whole.
public struct CrewExperienceSet: Codable, Equatable, Sendable {

    /// What an entry is about (team-learning §5, with the NF/IM amendment's symptom subject).
    public enum Subject: Equatable, Sendable {
        case model(modelToken: String, manufacturer: String?, equipmentType: String?)
        /// An equipment type alone (IM decision 4): answers only within that type.
        case symptom(equipmentType: String, phrase: String)

        /// The citation's subject: the model, or the equipment type.
        public var citationSubject: String {
            switch self {
            case .model(let token, _, _): return token
            case .symptom(let type, _): return type
            }
        }
    }

    /// One approved entry, field for field the contract's (§5 and the amendment).
    public struct Entry: Codable, Equatable, Sendable {
        public let entryID: String
        public let subject: Subject
        public let vaultIDs: [String]
        public let finding: String
        public let symptom: String?
        public let fix: String?
        public let faultCode: String?
        public let tried: String?
        public let outcome: String?
        /// Unix UTC seconds.
        public let approvedAt: Int64
        public let approvedByRole: String
        public let authorIsApprover: Bool
        public let contradictsSafetyNote: Bool
        /// `recollection` (a sheet row) or `spoken` (a learning approved in the portal, Plan NG P0b).
        public let origin: String
        /// Plan NG P0b, team-learning §5: the candidate a `spoken` entry was approved from
        /// (32 lowercase hex). Absent on every sheet row. Encoded only when present, so a set
        /// without it is the bytes it was.
        public let candidateID: String?
        /// Plan NG P0b: the jobs it was filed on, as the portal holds them (the per-company job
        /// hash of team-learning §12, 32 lowercase hex each), never a customer, site or address.
        /// Absent on a sheet row until a job confirms it (`CrewExperienceMerge`).
        public let sourceJobIDs: [String]?
        /// Plan NG P0b: how many jobs it was filed on; absent reads as 0 for a recollection.
        public let confirmedJobCount: Int?

        public init(entryID: String, subject: Subject, vaultIDs: [String], finding: String, symptom: String?,
                    fix: String?, faultCode: String?, tried: String?, outcome: String?, approvedAt: Int64,
                    approvedByRole: String, authorIsApprover: Bool, contradictsSafetyNote: Bool = false,
                    origin: String = CrewExperienceSheet.origin, candidateID: String? = nil,
                    sourceJobIDs: [String]? = nil, confirmedJobCount: Int? = nil) {
            self.entryID = entryID; self.subject = subject; self.vaultIDs = vaultIDs; self.finding = finding
            self.symptom = symptom; self.fix = fix; self.faultCode = faultCode; self.tried = tried
            self.outcome = outcome; self.approvedAt = approvedAt; self.approvedByRole = approvedByRole
            self.authorIsApprover = authorIsApprover; self.contradictsSafetyNote = contradictsSafetyNote
            self.origin = origin; self.candidateID = candidateID; self.sourceJobIDs = sourceJobIDs
            self.confirmedJobCount = confirmedJobCount
        }

        /// A learning approved in the portal (origin `spoken`), cited as a team learning.
        public var isSpoken: Bool { origin == CrewExperienceSheet.spokenOrigin }

        /// The team-learning §7.1 citation, amended for crew experience: `Crew experience · …` for a
        /// recollection, `Team learning · …` for a `spoken` entry.
        public var citationName: String {
            isSpoken
                ? CrewExperienceSheet.teamLearningCitationName(subject: subject.citationSubject, approvedAt: approvedAt,
                                                               role: approvedByRole)
                : CrewExperienceSheet.citationName(subject: subject.citationSubject, approvedAt: approvedAt, role: approvedByRole)
        }

        /// The same words about the same thing, whoever approved them and when.
        func sameContent(as other: Entry) -> Bool {
            subject == other.subject && vaultIDs == other.vaultIDs && finding == other.finding
                && symptom == other.symptom && fix == other.fix && faultCode == other.faultCode
                && tried == other.tried && outcome == other.outcome
                && contradictsSafetyNote == other.contradictsSafetyNote && origin == other.origin
        }
    }

    /// An entry withdrawn after publication (team-learning §5 `retracted[]`).
    public struct Retraction: Codable, Equatable, Sendable {
        public let entryID: String
        public let retractedAt: Int64
        public let reason: String

        public init(entryID: String, retractedAt: Int64, reason: String) {
            self.entryID = entryID; self.retractedAt = retractedAt; self.reason = reason
        }
    }

    public let version: Int
    public let kind: String
    public let profileId: String
    public let vaultId: String
    /// Rises with every publish for this vault; a phone refuses one not newer than the set it holds.
    public let sequence: Int
    /// Unix UTC seconds.
    public let issuedAt: Int64
    public let entries: [Entry]
    public let retracted: [Retraction]

    public init(profileId: String, vaultId: String, sequence: Int, issuedAt: Int64, entries: [Entry],
                retracted: [Retraction] = [], version: Int = CrewExperienceSheet.setVersion,
                kind: String = CrewExperienceSheet.setKind) {
        self.version = version; self.kind = kind; self.profileId = profileId; self.vaultId = vaultId
        self.sequence = sequence; self.issuedAt = issuedAt; self.entries = entries; self.retracted = retracted
    }

    public enum Refusal: Error, Equatable, Sendable {
        case invalid(String)
    }

    /// Sorted keys, unescaped slashes: the bytes the seal and `revision` are computed over.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// What the service holds a set to before sealing it, and the phone holds it to after opening.
    public static func check(_ set: CrewExperienceSet) throws {
        func refuse(_ message: String) -> Refusal { .invalid(message) }
        guard set.kind == CrewExperienceSheet.setKind, set.version == CrewExperienceSheet.setVersion else {
            throw refuse("kind must be \(CrewExperienceSheet.setKind), version \(CrewExperienceSheet.setVersion)")
        }
        guard isSafeIdentifier(set.profileId), isSafeIdentifier(set.vaultId) else {
            throw refuse("profileId and vaultId must be safe identifiers")
        }
        guard set.sequence >= 1, set.issuedAt >= 1 else { throw refuse("sequence and issuedAt must be 1 or more") }
        guard set.entries.count <= CrewExperienceSheet.Limits.rows else {
            throw refuse("a set holds at most \(CrewExperienceSheet.Limits.rows) entries")
        }
        var ids = Set<String>()
        var candidates = Set<String>()
        for entry in set.entries {
            guard CrewExperienceSheet.isEntryID(entry.entryID) else { throw refuse("\(entry.entryID) is not an entry id") }
            guard ids.insert(entry.entryID).inserted else { throw refuse("\(entry.entryID) is in the set twice") }
            guard entry.vaultIDs == [set.vaultId] else { throw refuse("\(entry.entryID) must name exactly the set's vault") }
            guard origins.contains(entry.origin) else {
                throw refuse("\(entry.entryID)'s origin \(entry.origin) is not one a set carries (\(origins.joined(separator: " or ")))")
            }
            if let problem = provenanceProblem(entry) { throw refuse("\(entry.entryID): \(problem)") }
            if let candidate = entry.candidateID, !candidates.insert(candidate).inserted {
                throw refuse("\(entry.entryID): candidate \(candidate) is on two entries")
            }
            guard entry.approvedAt >= 1 else { throw refuse("\(entry.entryID) has no approval time") }
            if let problem = textProblem(entry) { throw refuse("\(entry.entryID): \(problem)") }
        }
        for retraction in set.retracted {
            guard CrewExperienceSheet.isEntryID(retraction.entryID), !ids.contains(retraction.entryID) else {
                throw refuse("\(retraction.entryID) is retracted and published at once, or not an entry id")
            }
            guard CrewText.isPlain(retraction.reason, keepsLineBreaks: false, minimum: 1, limit: 500) else {
                throw refuse("\(retraction.entryID)'s reason is empty, too long or not plain text")
            }
        }
        let bytes = try encoder().encode(set).count
        guard bytes <= CrewExperienceSheet.Limits.bytes else {
            throw refuse("the set is \(bytes) bytes; at most \(CrewExperienceSheet.Limits.bytes)")
        }
    }

    /// The origins a set may carry: a sheet row's `recollection` and (Plan NG P0b) a learning approved
    /// in the portal, `spoken`. Builds 775–778 refuse a whole set holding a `spoken` entry, so the
    /// service publishes one only through `mayPublishSpokenEntries(seatBuilds:)`.
    public static let origins = [CrewExperienceSheet.origin, CrewExperienceSheet.spokenOrigin]

    /// Plan NG P0b: the first app build whose `check` admits a `spoken` entry. Builds 775–778 (NF P1
    /// to NG P1) refuse the whole set and keep the last good one.
    public static let spokenEntriesMinAppBuild = 779

    /// Whether any entry is a learning approved in the portal.
    public var containsSpokenEntries: Bool { entries.contains(where: \.isSpoken) }

    /// Plan NG P0b, the older-phone gate: whether a set holding `spoken` entries may be published to
    /// a company whose active seats last reported these app builds (`CFBundleVersion`, as a seat
    /// claim or renewal carries it). Every one must be a whole number at or above
    /// `spokenEntriesMinAppBuild`; a seat with no build, or one that does not read as a number,
    /// counts as old. No active seat holds nothing back. A set without `spoken` entries needs no
    /// gate: `mayPublish(_:seatBuilds:)` says so.
    public static func mayPublishSpokenEntries(seatBuilds: [String?]) -> Bool {
        seatBuilds.allSatisfy { build in
            guard let build = build?.trimmingCharacters(in: .whitespaces), !build.isEmpty,
                  build.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }), let number = Int(build) else { return false }
            return number >= spokenEntriesMinAppBuild
        }
    }

    /// The gate for a whole set: always for one without `spoken` entries, else as
    /// `mayPublishSpokenEntries(seatBuilds:)`.
    public static func mayPublish(_ set: CrewExperienceSet, seatBuilds: [String?]) -> Bool {
        !set.containsSpokenEntries || mayPublishSpokenEntries(seatBuilds: seatBuilds)
    }

    /// Plan NG P0b: where an entry came from, and the jobs it was filed on.
    /// - a `spoken` entry carries its `candidateID` and the jobs; a `recollection` carries no
    ///   candidate (a sheet row came from none), and its jobs only once a job confirmed it;
    /// - `sourceJobIDs` and `confirmedJobCount` come together or not at all; the ids are distinct
    ///   32-lowercase-hex job hashes, at least one, and the count is at least how many there are.
    static func provenanceProblem(_ entry: Entry) -> String? {
        switch (entry.isSpoken, entry.candidateID) {
        case (true, nil): return "a spoken entry carries the candidateID it was approved from"
        case (true, let id?) where !CrewExperienceSheet.isEntryID(id): return "candidateID \(id) is not 32 lowercase hex"
        case (false, _?): return "a recollection came from no candidate, so it carries no candidateID"
        default: break
        }
        switch (entry.sourceJobIDs, entry.confirmedJobCount) {
        case (nil, nil):
            return entry.isSpoken ? "a spoken entry carries sourceJobIDs and confirmedJobCount" : nil
        case (let jobs?, let count?):
            guard !jobs.isEmpty else { return "sourceJobIDs is empty" }
            guard jobs.allSatisfy(CrewExperienceSheet.isEntryID) else { return "a source job id is not 32 lowercase hex" }
            guard Set(jobs).count == jobs.count else { return "sourceJobIDs names a job twice" }
            guard count >= jobs.count else { return "confirmedJobCount \(count) is fewer than its \(jobs.count) source jobs" }
            return nil
        default:
            return "sourceJobIDs and confirmedJobCount come together or not at all"
        }
    }

    /// The team-learning §7.4 text rules, with the template's limits.
    static func textProblem(_ entry: Entry) -> String? {
        typealias C = CrewExperienceSheet.Column
        let fields: [(String, String?, Int, Bool, Int)] = [
            ("finding", entry.finding, C.notes.limit, true, 1),
            ("symptom", entry.symptom, C.symptom.limit, false, 1),
            ("fix", entry.fix, C.fix.limit, false, 1),
            ("faultCode", entry.faultCode, C.faultCode.limit, false, 1),
            ("tried", entry.tried, C.checked.limit, false, 1),
            ("outcome", entry.outcome, C.howSure.limit, false, 1),
            ("approvedByRole", entry.approvedByRole, CrewExperienceSheet.Limits.role, false, 1)
        ]
        for (name, value, limit, lineBreaks, minimum) in fields {
            guard let value else { continue }
            if !CrewText.isPlain(value, keepsLineBreaks: lineBreaks, minimum: minimum, limit: limit) {
                return "\(name) is empty, over \(limit) characters or not plain text"
            }
        }
        switch entry.subject {
        case .model(let token, let manufacturer, let type):
            for value in [token, manufacturer, type].compactMap({ $0 })
            where !CrewText.isPlain(value, keepsLineBreaks: false, minimum: 1, limit: 80) {
                return "the subject is empty, over 80 characters or not plain text"
            }
        case .symptom(let type, let phrase):
            guard CrewText.isPlain(type, keepsLineBreaks: false, minimum: 1, limit: 80),
                  CrewText.isPlain(phrase, keepsLineBreaks: false, minimum: 1, limit: C.symptom.limit) else {
                return "the subject is empty, too long or not plain text"
            }
        }
        return nil
    }

    /// 1–80 of A–Z a–z 0–9 - _ . and never `.` or `..` (the same rule as `ProfileContract`'s).
    static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id != "." && id != ".."
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }
}

extension CrewExperienceSet.Subject: Codable {
    private enum Keys: String, CodingKey { case kind, modelToken, manufacturer, equipmentType, phrase }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "model":
            self = .model(modelToken: try c.decode(String.self, forKey: .modelToken),
                          manufacturer: try c.decodeIfPresent(String.self, forKey: .manufacturer),
                          equipmentType: try c.decodeIfPresent(String.self, forKey: .equipmentType))
        case "symptom":
            self = .symptom(equipmentType: try c.decode(String.self, forKey: .equipmentType),
                            phrase: try c.decode(String.self, forKey: .phrase))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown subject kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .model(let token, let manufacturer, let type):
            try c.encode("model", forKey: .kind)
            try c.encode(token, forKey: .modelToken)
            try c.encodeIfPresent(manufacturer, forKey: .manufacturer)
            try c.encodeIfPresent(type, forKey: .equipmentType)
        case .symptom(let type, let phrase):
            try c.encode("symptom", forKey: .kind)
            try c.encode(type, forKey: .equipmentType)
            try c.encode(phrase, forKey: .phrase)
        }
    }
}

// MARK: - Merge (Plan FP decision 3 of 2026-10-09; Plan NG P0b)

/// FP's merge rule, held here so the phone's `LearningReview.merge` and the portal's "same as" compute
/// it the same way: a candidate that says what an approved entry already says folds into it — its job
/// joins `sourceJobIDs` and `confirmedJobCount` rises, no second entry, the citation unchanged. Who may
/// merge (licence, HIPAA, author is approver, the entry still live) is each side's own gate, not this.
/// Golden cases: `Contracts/fixtures/crew-experience-v1/learnings/merge-cases.json`.
public enum CrewExperienceMerge {

    /// What a merge reads and writes: the entry's origin and its jobs.
    public struct Jobs: Codable, Equatable, Sendable {
        public var origin: String
        public var sourceJobIDs: [String]?
        public var confirmedJobCount: Int?

        public init(origin: String, sourceJobIDs: [String]? = nil, confirmedJobCount: Int? = nil) {
            self.origin = origin; self.sourceJobIDs = sourceJobIDs; self.confirmedJobCount = confirmedJobCount
        }
    }

    /// The count before the merge: the entry's own when it has one; else, for a filed learning,
    /// at least the one job it was filed on (`max(1, jobs)`); for a recollection, the jobs that
    /// confirmed it, which is 0 for a sheet row (team-learning §11: absent reads as 0).
    public static func count(of jobs: Jobs) -> Int {
        let ids = jobs.sourceJobIDs ?? []
        if let count = jobs.confirmedJobCount { return count }
        return jobs.origin == CrewExperienceSheet.origin ? ids.count : max(1, ids.count)
    }

    /// Fold the job `jobSessionID` into `jobs`. A job already counted adds nothing; a new one is
    /// appended and the count rises by one. A recollection merged with a job becomes job-confirmed:
    /// its first job gives it `sourceJobIDs [job]` and a count of 1. The origin never changes.
    public static func merge(jobSessionID: String, into jobs: Jobs) -> Jobs {
        var ids = jobs.sourceJobIDs ?? []
        var count = count(of: jobs)
        if !ids.contains(jobSessionID) {
            ids.append(jobSessionID)
            count += 1
        }
        return Jobs(origin: jobs.origin, sourceJobIDs: ids, confirmedJobCount: count)
    }

    /// The same, on a set entry: everything but the jobs is kept.
    public static func merge(jobSessionID: String, into entry: CrewExperienceSet.Entry) -> CrewExperienceSet.Entry {
        let merged = merge(jobSessionID: jobSessionID, into: Jobs(origin: entry.origin, sourceJobIDs: entry.sourceJobIDs,
                                                                   confirmedJobCount: entry.confirmedJobCount))
        return CrewExperienceSet.Entry(
            entryID: entry.entryID, subject: entry.subject, vaultIDs: entry.vaultIDs, finding: entry.finding,
            symptom: entry.symptom, fix: entry.fix, faultCode: entry.faultCode, tried: entry.tried, outcome: entry.outcome,
            approvedAt: entry.approvedAt, approvedByRole: entry.approvedByRole, authorIsApprover: entry.authorIsApprover,
            contradictsSafetyNote: entry.contradictsSafetyNote, origin: entry.origin, candidateID: entry.candidateID,
            sourceJobIDs: merged.sourceJobIDs, confirmedJobCount: merged.confirmedJobCount)
    }
}

// MARK: - The CSV dialect (contract §3)

/// RFC 4180: UTF-8, comma-separated, a cell with a comma, quote or line break is quoted, a quote
/// inside one is doubled. Records end at CRLF, LF or a lone CR; a line break inside a quoted cell is
/// part of the cell. A file that ends with a line break has no empty record after it.
enum CSV {

    static func records(in text: String) throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var cell = String.UnicodeScalarView()
        var quoted = false          // inside a quoted cell
        var closed = false          // just after a quoted cell's closing quote
        var atCellStart = true
        var quoteStartRecord = 1
        var pendingCR = false
        let scalars = Array(text.unicodeScalars)

        func endCell() {
            record.append(String(cell))
            cell = String.UnicodeScalarView()
            closed = false
            atCellStart = true
        }
        func endRecord() {
            endCell()
            records.append(record)
            record = []
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if pendingCR {
                pendingCR = false
                if scalar == "\n" { continue }
            }
            if quoted {
                if scalar == "\"" {
                    if index < scalars.count, scalars[index] == "\"" {
                        cell.append("\"")
                        index += 1
                    } else {
                        quoted = false
                        closed = true
                    }
                } else {
                    cell.append(scalar)
                }
                continue
            }
            switch scalar {
            case ",":
                endCell()
            case "\r":
                endRecord()
                pendingCR = true
            case "\n":
                endRecord()
            case "\"":
                guard atCellStart else { throw CrewExperienceSheet.SheetRefusal.strayQuote(row: records.count + 1) }
                quoted = true
                atCellStart = false
                quoteStartRecord = records.count + 1
            default:
                if closed { throw CrewExperienceSheet.SheetRefusal.strayQuote(row: records.count + 1) }
                cell.append(scalar)
                atCellStart = false
            }
        }
        if quoted { throw CrewExperienceSheet.SheetRefusal.unterminatedQuote(row: quoteStartRecord) }
        if !atCellStart || !record.isEmpty || closed { endRecord() }
        return records
    }

    /// One cell as the dialect writes it: quoted when it holds a comma, a quote or a line break.
    static func cell(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - Text rules (team-learning §7.4, as the phone's `LearningCandidateText` applies them)

enum CrewText {

    /// Tabs to spaces, CRLF and CR to LF, LF to a space unless line breaks are kept; nil when any
    /// other control character or a bidirectional override is present. Trimmed.
    static func normalise(_ raw: String, keepsLineBreaks: Bool) -> String? {
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        var scalars = String.UnicodeScalarView()
        for scalar in unified.unicodeScalars {
            if scalar == "\n" {
                scalars.append(keepsLineBreaks ? scalar : " ")
                continue
            }
            if isRefused(scalar) { return nil }
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The general category Cc, plus the bidirectional embedding, override and isolate controls.
    static func isRefused(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// Lengths are Unicode scalars: never fewer than the characters a person sees.
    static func length(_ text: String) -> Int { text.unicodeScalars.count }

    /// Already plain: no refused character, a line feed only where kept, within the length bounds.
    static func isPlain(_ text: String, keepsLineBreaks: Bool, minimum: Int, limit: Int) -> Bool {
        let count = length(text)
        guard count >= minimum, count <= limit else { return false }
        return text.unicodeScalars.allSatisfy { ($0 == "\n" && keepsLineBreaks) || !isRefused($0) }
    }
}

// MARK: - Redaction (§2 of the contract)

/// The phone's `SecretPatterns` set, restated here so the service runs the same patterns (the app's
/// `CrewExperienceSheetTests` holds the two to the same names and expressions), plus phone numbers.
/// E-mail addresses are already among them.
public enum CrewExperienceRedaction {

    /// `SecretPatterns.redactionPlaceholder`.
    public static let placeholder = "‹redacted›"

    /// Name and expression, in the order they run: the phone's patterns, then `phone`.
    public static let patterns: [(name: String, expression: String)] = [
        ("openai_key", #"sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}"#),
        ("github_token", #"gh[pousr]_[A-Za-z0-9]{20,}"#),
        ("slack_token", #"xox[baprs]-[A-Za-z0-9-]{10,}"#),
        ("google_api_key", #"AIza[0-9A-Za-z_-]{35}"#),
        ("aws_access_key_id", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("jwt", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        ("bearer_token", #"(?i)bearer\s+[A-Za-z0-9._-]{16,}"#),
        ("private_key_block", #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#),
        ("email", #"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        ("nz_ird", #"\b\d{2,3}-\d{3}-\d{3}\b"#),
        // Digit groups separated by single spaces, dots or hyphens, optionally an international
        // prefix and an area code in brackets, standing alone. Only a match with 9–15 digits is a
        // phone number: a date (8 digits) or a short reading is not.
        (phonePattern, #"(?<![A-Za-z0-9+])\+?(?:\(\d{1,4}\)[ .-]?)?\d{2,4}(?:[ .-]?\d{2,5}){1,4}(?![A-Za-z0-9])"#),
    ]

    public static let phonePattern = "phone"
    public static let phoneDigits = 9...15

    private static let compiled: [(name: String, regex: NSRegularExpression)] = patterns.map { pattern in
        guard let regex = try? NSRegularExpression(pattern: pattern.expression) else {
            fatalError("CrewExperienceRedaction: invalid expression for \(pattern.name)")
        }
        return (pattern.name, regex)
    }

    /// The text with every match replaced by `placeholder`, and the names of the patterns that fired,
    /// in `patterns` order. Text that matches nothing comes back as it was.
    public static func redact(_ text: String) -> (redacted: String, hits: [String]) {
        guard !text.isEmpty else { return (text, []) }
        var result = text
        var fired: [String] = []
        for (name, regex) in compiled {
            let ns = result as NSString
            var ranges = regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).map(\.range)
            if name == phonePattern {
                ranges = ranges.filter { phoneDigits.contains(ns.substring(with: $0).filter(\.isNumber).count) }
            }
            guard !ranges.isEmpty else { continue }
            fired.append(name)
            let mutable = NSMutableString(string: result)
            for range in ranges.reversed() { mutable.replaceCharacters(in: range, with: placeholder) }
            result = String(mutable)
        }
        return (result, fired)
    }
}

// MARK: - crew-models.md (contract §7)

/// The company's model list as an add-only company layer file: one `## <model> (<other spellings>)`
/// heading per model, the format the phone's `VaultModelIndex` reads. For a vault with no manuals it
/// is the whole model index.
public enum CrewModelsFile {

    public static let fileName = "crew-models.md"

    public enum Problem: Error, Equatable, Sendable {
        /// The phone's model index would not read this spelling as a model, so a row about it would
        /// never be published to the vault.
        case notAModelNumber(String)
        case noModels
    }

    /// Whether the phone's model index reads `spelling`, written in a heading, as one model token:
    /// letters, digits and hyphens only, at least five long, two digits and a letter, and not the
    /// shape of a fault code or a refrigerant (`E223`, `R-410A`) or a stray size (`454B`). The
    /// app's `VaultModelIndex.isModelLike(_:minimumLength: 5)`, restated; `CrewModelsFileTests`
    /// holds the two together.
    public static func isIndexable(_ spelling: String) -> Bool {
        let token = spelling.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !token.isEmpty, token == spelling, token.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        guard token.count >= 5, token.filter(\.isNumber).count >= 2, token.contains(where: \.isLetter) else { return false }
        return token.range(of: #"^([A-Za-z]-?[0-9]{1,4}[A-Za-z]?|[0-9]{1,4}[A-Za-z])$"#, options: .regularExpression) == nil
    }

    /// The file's text. Names and spellings are cleaned as the starter vault cleans them (brackets,
    /// `#`, commas and line breaks out; one heading per model, spellings de-duplicated), sorted by
    /// name so the same list always gives the same bytes. Throws for a spelling the index would not
    /// read, by name, rather than writing a heading that silently knows nothing.
    public static func render(models: [VaultStarter.Model]) throws -> String {
        let cleaned = VaultStarter.normalised(models)
        guard !cleaned.isEmpty else { throw Problem.noModels }
        for model in cleaned {
            for spelling in [model.name] + model.aliases where !isIndexable(spelling) {
                throw Problem.notAModelNumber(spelling)
            }
        }
        var lines = [
            "# Crew models",
            "",
            "The models this company services, from its crew experience. One section per model; the other spellings are in brackets.",
            ""
        ]
        for model in cleaned.sorted(by: { $0.name.uppercased() < $1.name.uppercased() }) {
            lines.append(model.aliases.isEmpty ? "## \(model.name)" : "## \(model.name) (\(model.aliases.joined(separator: ", ")))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The grounding rules an experience-only vault carries: the validator's "fabricate" and
    /// "cite", and the lead-in, because nothing in it is a manufacturer's.
    public static let experienceOnlyPromptRules = [
        "Never fabricate a fault code, a model, a setting or a procedure.",
        "This vault holds no manufacturer's manual: answer only from the company's crew experience, and open every answer with \"\(CrewExperienceSheet.leadIn)\"",
        "Cite the crew experience entry on every claim, by the name it is given.",
        "Identify the exact model first; an entry written for another model is not evidence.",
        "If the crew experience does not cover the question, say so plainly rather than guessing."
    ]

    /// An experience-only vault (§7): a company vault whose core is its prompt rules and
    /// `crew-models.md`, and nothing else. On the phone it is an ordinary vault with no manual.
    public static func experienceOnlyVault(name: String, id: String? = nil,
                                           models: [VaultStarter.Model]) throws -> VaultStarter.Output {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultStarter.Failure.emptyName }
        let vaultName = trimmed.components(separatedBy: .newlines).joined(separator: " ")
        let vaultId = id ?? VaultStarter.vaultId(forName: vaultName)
        let file = VaultStarter.File(name: fileName, contents: try render(models: models))
        let manifest = VaultStarter.Manifest(id: vaultId, name: vaultName, version: VaultStarter.version, files: [fileName],
                                             documentsDir: VaultStarter.documentsDirectory, documents: [],
                                             gating: .init(iap: VaultStarter.gating), promptRules: experienceOnlyPromptRules,
                                             sourceAttributionFormat: "Source: {files}", sourceAttributionRequired: true,
                                             trades: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return VaultStarter.Output(id: vaultId, name: vaultName, manifestJSON: try encoder.encode(manifest), files: [file])
    }
}
