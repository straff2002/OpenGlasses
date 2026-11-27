import Foundation

/// The workbook connection's calls, over any transport (Plan NK P1). Every request comes from
/// `GraphRequestBuilder`; the token comes from the caller and goes only into the transport. Tests
/// drive it with a fixture transport and no network.
struct ClinicWorkbookClient: Sendable {

    /// The most pages of rows read from one table: 200 × 500 rows.
    static let maximumPages = 200

    let transport: any ClinicWorkbookTransport
    /// The workbook the connection is on; nil before one is chosen.
    let workbook: GraphWorkbook?
    /// A current access token, refreshed first when it is near expiry.
    let token: @Sendable () async throws -> String
    /// A new token after Graph refused `rejected` (one retry), or nil when there is none.
    let tokenAfterRejecting: @Sendable (String) async throws -> String?

    // MARK: - Sending

    /// One request to Graph. A `401` is answered once with a fresh token; every other status
    /// outside 2xx is the failure it maps to.
    func send(_ request: GraphRequest) async throws -> Data {
        let first = try await token()
        var response = try await transport.send(request, bearer: first, workbook: workbook)
        if response.status == 401, let second = try await tokenAfterRejecting(first), second != first {
            response = try await transport.send(request, bearer: second, workbook: workbook)
        }
        if let failure = ClinicWorkbookFailure.from(status: response.status, retryAfter: response.retryAfter) {
            throw failure
        }
        return response.body
    }

    private func requireWorkbook() throws -> GraphWorkbook {
        guard let workbook else { throw ClinicWorkbookFailure.notFound }
        return workbook
    }

    // MARK: - Sign-in

    /// The signed-in account's name, as Microsoft shows it.
    func account() async throws -> String? {
        GraphReply.account(try await send(GraphRequestBuilder.me()))
    }

    /// The organisation's two-letter country.
    func country() async throws -> String? {
        GraphReply.country(try await send(GraphRequestBuilder.organization()))
    }

    /// The workbook a pasted sharing link names.
    func resolve(link: String) async throws -> GraphReply.DriveItem {
        guard let request = GraphRequestBuilder.resolveShare(link: link) else { throw ClinicWorkbookSetupError.notASharingLink }
        guard let item = GraphReply.driveItem(try await send(request)) else { throw ClinicWorkbookSetupError.notAWorkbook }
        return item
    }

    // MARK: - The tables

    /// Make whichever of the two tables is missing: its sheet, its heading row, the table, its
    /// name. Returns the tables made.
    @discardableResult
    func ensureTables() async throws -> [ClinicalStockWorkbookTable] {
        let workbook = try requireWorkbook()
        guard let existing = GraphReply.tables(try await send(GraphRequestBuilder.tables(in: workbook))) else {
            throw ClinicWorkbookFailure.malformedResponse
        }
        let names = Set(existing.map(\.name))
        var made: [ClinicalStockWorkbookTable] = []
        for table in ClinicalStockWorkbookTable.allCases where !names.contains(table.rawValue) {
            _ = try await send(GraphRequestBuilder.addWorksheet(for: table, in: workbook))
            _ = try await send(GraphRequestBuilder.writeHeaders(of: table, in: workbook))
            let added = try await send(GraphRequestBuilder.addTable(table, in: workbook))
            guard let id = GraphReply.addedTable(added),
                  let rename = GraphRequestBuilder.nameTable(id: id, as: table, in: workbook) else {
                throw ClinicWorkbookFailure.malformedResponse
            }
            _ = try await send(rename)
            made.append(table)
        }
        return made
    }

    /// A table's headings, as the workbook has them now.
    func headings(of table: ClinicalStockWorkbookTable) async throws -> [String] {
        guard let names = GraphReply.columnNames(try await send(GraphRequestBuilder.columns(of: table, in: try requireWorkbook()))) else {
            throw ClinicWorkbookFailure.malformedResponse
        }
        return names
    }

    /// Every row of a table, page by page.
    func cells(of table: ClinicalStockWorkbookTable) async throws -> [[Any]] {
        let workbook = try requireWorkbook()
        var all: [[Any]] = []
        for page in 0..<Self.maximumPages {
            guard let rows = GraphReply.rows(try await send(GraphRequestBuilder.rows(of: table, in: workbook,
                                                                                   skip: page * GraphRequestBuilder.pageSize))) else {
                throw ClinicWorkbookFailure.malformedResponse
            }
            all.append(contentsOf: rows)
            if rows.count < GraphRequestBuilder.pageSize { return all }
        }
        throw ClinicWorkbookFailure.tooLarge
    }

    /// Both tables read back, refused when either carries a patient-like column.
    func read() async throws -> Result<ClinicalStockWorkbookSchema.Read, ClinicalStockWorkbookRefusal> {
        var read = ClinicalStockWorkbookSchema.Read(entries: [], skipped: 0)
        for table in ClinicalStockWorkbookTable.allCases {
            let headings = try await headings(of: table)
            let cells = try await cells(of: table)
            switch ClinicalStockWorkbookSchema.read(table, headers: headings, rows: cells) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let part):
                read.entries += part.entries
                read.skipped += part.skipped
            }
        }
        return .success(read)
    }

    // MARK: - Adding rows

    /// Add the rows the workbook does not already hold, by key, a table at a time. Returns the keys
    /// now in the workbook (those already there and those added). Refuses a table with a
    /// patient-like column: rows are never written beside one.
    func append(_ rows: [KeyedShareRow]) async throws -> Set<String> {
        let workbook = try requireWorkbook()
        var present = Set<String>()
        for table in ClinicalStockWorkbookTable.allCases {
            let mine = rows.filter { ClinicalStockWorkbookTable.of($0.row) == table }
            guard !mine.isEmpty else { continue }
            let headings = try await headings(of: table)
            let cells = try await cells(of: table)
            switch ClinicalStockWorkbookSchema.read(table, headers: headings, rows: cells) {
            case .failure(let refusal): throw ClinicWorkbookSetupError.refused(refusal)
            case .success(let read):
                let there = Set(read.entries.compactMap(\.key))
                present.formUnion(mine.map(\.key).filter(there.contains))
                let missing = mine.filter { !there.contains($0.key) }
                var start = 0
                while start < missing.count {
                    let chunk = Array(missing[start..<min(start + GraphRequestBuilder.maximumRowsPerRequest, missing.count)])
                    guard let request = GraphRequestBuilder.addRows(chunk, to: table, columns: headings, in: workbook) else {
                        throw ClinicWorkbookSetupError.refused(.missingColumns(table.headers))
                    }
                    _ = try await send(request)
                    present.formUnion(chunk.map(\.key))
                    start += chunk.count
                }
            }
        }
        return present
    }
}

/// Why choosing the workbook stopped, in plain words.
enum ClinicWorkbookSetupError: Error, Equatable, Sendable {
    case notASharingLink
    case notAWorkbook
    case refused(ClinicalStockWorkbookRefusal)

    var sentence: String {
        switch self {
        case .notASharingLink:
            return String(localized: "That isn't a sharing link to a file in Microsoft 365. In Excel, choose Share, copy the link, and paste it here.",
                          comment: "The pasted text is not a Microsoft 365 sharing link.")
        case .notAWorkbook:
            return String(localized: "That link isn't to an Excel workbook. Paste the link to the workbook itself.",
                          comment: "The sharing link names something other than an Excel workbook.")
        case .refused(let refusal):
            return refusal.sentence
        }
    }
}
