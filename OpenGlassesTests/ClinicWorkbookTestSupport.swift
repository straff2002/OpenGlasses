import Foundation
@testable import OpenGlasses

/// An in-memory clinic workbook behind the transport seam (Plan NK): it answers exactly the
/// builder's requests, refuses anything else the way the real transport would, and keeps every
/// request and bearer it saw. No network. Cells are kept as Excel keeps them: a leading apostrophe
/// is dropped.
final class ClinicWorkbookFixtureTransport: ClinicWorkbookTransport, @unchecked Sendable {

    struct Table {
        var id: String
        var name: String
        var headers: [String]
        var rows: [[Any]]
    }

    private let lock = NSLock()
    private var _tables: [Table] = []
    private var _seen: [GraphRequest] = []
    private var _bearers: [String?] = []
    private var _sheets: Set<String> = []
    private var _headerCells: [String: [String]] = [:]
    /// A status to answer the next request with instead (then cleared), and its Retry-After.
    var nextStatus: Int?
    var failNext: ClinicWorkbookFailure?
    /// Statuses for the token endpoint.
    var tokenStatus = 200
    var country: String? = "CA"
    let workbook = GraphWorkbook(driveID: "b!drive-1", itemID: "01ITEM")!

    var tables: [Table] { lock.withLock { _tables } }
    var seen: [GraphRequest] { lock.withLock { _seen } }
    var bearers: [String?] { lock.withLock { _bearers } }

    func setTables(_ tables: [Table]) { lock.withLock { _tables = tables } }

    /// A workbook that already has both tables, empty.
    static func withTables() -> ClinicWorkbookFixtureTransport {
        let fixture = ClinicWorkbookFixtureTransport()
        fixture.setTables(ClinicalStockWorkbookTable.allCases.enumerated().map { index, table in
            Table(id: "{T\(index)}", name: table.rawValue, headers: table.headers, rows: [])
        })
        return fixture
    }

    func rows(of table: ClinicalStockWorkbookTable) -> [[Any]] {
        tables.first { $0.name == table.rawValue }?.rows ?? []
    }

    func send(_ request: GraphRequest, bearer: String?, workbook: GraphWorkbook?) async throws -> ClinicWorkbookResponse {
        // The same refusals as the real transport, before anything is answered.
        _ = try URLSessionClinicWorkbookTransport.urlRequest(request, bearer: bearer, workbook: workbook)
        try MedicalEgressGuard.check(.clinicStockRecord)
        return try lock.withLock {
            _seen.append(request)
            _bearers.append(bearer)
            if let failure = failNext { failNext = nil; throw failure }
            if let status = nextStatus { nextStatus = nil; return reply(status, [:]) }
            return try answer(request)
        }
    }

    private func reply(_ status: Int, _ object: Any) -> ClinicWorkbookResponse {
        ClinicWorkbookResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(),
                               retryAfter: nil)
    }

    private func excel(_ value: Any) -> Any {
        if let text = value as? String, text.hasPrefix("'") { return String(text.dropFirst()) }
        return value
    }

    private func answer(_ request: GraphRequest) throws -> ClinicWorkbookResponse {
        if request.host == EntraOAuth.loginHost {
            guard tokenStatus == 200 else { return reply(tokenStatus, ["error": "invalid_grant"]) }
            return reply(200, ["access_token": "access-\(UUID().uuidString.prefix(4))", "refresh_token": "refresh-2",
                               "expires_in": 3600])
        }
        let path = String(request.path.dropFirst(GraphRequestBuilder.version.count))
        if path == "/me" { return reply(200, ["userPrincipalName": "staff@clinic.example"]) }
        if path == "/organization" { return reply(200, ["value": [["countryLetterCode": country as Any]]]) }
        if path.hasPrefix("/shares/") {
            return reply(200, ["id": workbook.itemID, "name": "Fridge stock.xlsx", "file": [:],
                               "parentReference": ["driveId": workbook.driveID]])
        }
        let rest = String(path.dropFirst(workbook.path.count))
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        switch (request.method, rest) {
        case (.get, "/tables"):
            return reply(200, ["value": _tables.map { ["id": $0.id, "name": $0.name] }])
        case (.post, "/worksheets/add"):
            _sheets.insert(body["name"] as? String ?? "")
            return reply(201, ["name": body["name"] as Any])
        case (.post, "/tables/add"):
            let address = body["address"] as? String ?? ""
            let sheet = String(address.split(separator: "!").first ?? "")
            let id = "{NEW\(_tables.count)}"
            _tables.append(Table(id: id, name: "Table\(_tables.count + 1)", headers: _headerCells[sheet] ?? [], rows: []))
            return reply(201, ["id": id, "name": "Table\(_tables.count)"])
        default:
            break
        }
        if request.method == .patch, rest.hasPrefix("/worksheets/") {
            let sheet = String(rest.dropFirst("/worksheets/".count).prefix { $0 != "/" })
            _headerCells[sheet] = (body["values"] as? [[String]])?.first ?? []
            return reply(200, [:])
        }
        if request.method == .patch, rest.hasPrefix("/tables/") {
            let id = String(rest.dropFirst("/tables/".count)).replacingOccurrences(of: "%7B", with: "{")
                .replacingOccurrences(of: "%7D", with: "}")
            guard let index = _tables.firstIndex(where: { $0.id == id }) else { return reply(404, [:]) }
            _tables[index].name = body["name"] as? String ?? ""
            return reply(200, ["id": id, "name": _tables[index].name])
        }
        for table in ClinicalStockWorkbookTable.allCases {
            guard let index = _tables.firstIndex(where: { $0.name == table.rawValue }) else { continue }
            switch (request.method, rest) {
            case (.get, "/tables/\(table.rawValue)/columns"):
                return reply(200, ["value": _tables[index].headers.map { ["name": $0] }])
            case (.get, "/tables/\(table.rawValue)/rows"):
                let skip = Int(request.query.first { $0.name == "$skip" }?.value ?? "0") ?? 0
                let top = Int(request.query.first { $0.name == "$top" }?.value ?? "0") ?? 0
                let page = _tables[index].rows.dropFirst(skip).prefix(top)
                return reply(200, ["value": page.enumerated().map { ["index": skip + $0.offset, "values": [$0.element]] }])
            case (.post, "/tables/\(table.rawValue)/rows"):
                let values = (body["values"] as? [[Any]]) ?? []
                guard values.allSatisfy({ $0.count == _tables[index].headers.count }) else { return reply(400, [:]) }
                _tables[index].rows += values.map { $0.map(excel) }
                return reply(201, ["index": _tables[index].rows.count - 1])
            default:
                continue
            }
        }
        return reply(404, [:])
    }

    /// A client on this workbook with a fixed token.
    func client(token: String = "token-1", workbook: GraphWorkbook? = nil, refreshed: String? = "token-2") -> ClinicWorkbookClient {
        let chosen = workbook ?? self.workbook
        return ClinicWorkbookClient(transport: self, workbook: chosen, token: { token },
                                    tokenAfterRejecting: { _ in refreshed })
    }
}

/// A Keychain for one test: in memory.
final class ClinicWorkbookMemoryKeychain: @unchecked Sendable {
    var items: [String: Data] = [:]
    var seat = "seat-test"

    /// Holds the keychain strongly: a refresh the service started can outlive the test's own locals.
    @MainActor var storage: ClinicWorkbookConnectionStore.Storage {
        ClinicWorkbookConnectionStore.Storage(
            read: { self.items[$0] },
            write: { data, account in self.items[account] = data },
            erase: { self.items[$0] = nil },
            makeSeat: { self.seat })
    }
}

enum ClinicWorkbookSamples {
    static func whole(_ n: Int) -> StockQuantity { StockQuantity(whole: n) }

    static func row(_ kind: ClinicalStockShareRow.Kind = .given, _ quantity: Int, day: Int = 25,
                    lot: String? = "ZZ1001") -> ClinicalStockShareRow {
        ClinicalStockShareRow(day: StockDay(year: 2026, month: 11, day: day)!, span: .day, lineID: "flu",
                              lineNumber: "8161", lineName: "Flu vaccine", lotCode: lot, lotExpiry: nil, kind: kind,
                              quantity: whole(quantity), wasteReason: nil)
    }

    static func keyed(_ rows: [ClinicalStockShareRow], seat: String = "seat-one") -> [KeyedShareRow] {
        ClinicalStockSendPlan.plan(current: rows, ledger: .init(), seat: seat, range: nil).rows
    }
}
