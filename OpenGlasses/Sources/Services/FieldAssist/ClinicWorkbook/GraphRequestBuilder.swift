import Foundation

/// The one workbook a connection reads and adds to: its drive and its item, as Graph names them.
struct GraphWorkbook: Codable, Equatable, Hashable, Sendable {
    let driveID: String
    let itemID: String

    /// Nil unless both ids are 1–256 characters of letters, digits, `!`, `-`, `_` and `.`: what Graph's
    /// drive and item ids are made of, and nothing that could leave the path.
    init?(driveID: String, itemID: String) {
        guard Self.isID(driveID), Self.isID(itemID) else { return nil }
        self.driveID = driveID
        self.itemID = itemID
    }

    static func isID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "!-_.".unicodeScalars.contains($0)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let workbook = GraphWorkbook(driveID: try container.decode(String.self, forKey: .driveID),
                                           itemID: try container.decode(String.self, forKey: .itemID)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a workbook"))
        }
        self = workbook
    }

    /// The workbook's path under Graph's version.
    var path: String { "/drives/\(driveID)/items/\(itemID)/workbook" }
}

/// One request to Microsoft's hosts, as the builder made it. The transport sends nothing else.
struct GraphRequest: Equatable, Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
    }

    let method: Method
    let host: String
    /// Percent-encoded where it needs to be, starting with "/".
    let path: String
    let query: [URLQueryItem]
    let body: Data?
    let contentType: String?

    init(method: Method, host: String = GraphRequestBuilder.host, path: String, query: [URLQueryItem] = [],
         body: Data? = nil, contentType: String? = nil) {
        self.method = method
        self.host = host
        self.path = path
        self.query = query
        self.body = body
        self.contentType = contentType
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}

/// Builds the only requests the clinic's workbook connection may make (Plan NK §3). Pure.
///
/// - `GET /me` and `GET /organization` (its `countryLetterCode`) once at sign-in;
/// - `GET /shares/{u!…}/driveItem` to find the workbook from the sharing link pasted;
/// - `GET …/workbook/tables`, and for the two tables their column names and their rows (paged);
/// - only to create the two tables when they are missing: a sheet for each (`worksheets/add`), its
///   heading row (exactly the fixed headings), the table over it (`tables/add`) and the table's
///   name (one of the two);
/// - `POST …/workbook/tables/{Movements|Counts}/rows`: keyed share rows, in that table's columns.
///
/// All on `https://graph.microsoft.com/v1.0`, all on the one drive and item. `isAllowed` checks a
/// request against these shapes again, and the transport asks it before every send, so a request
/// built any other way is refused. Even where the permission granted is the broader
/// `Files.ReadWrite`, nothing here can reach another file.
enum GraphRequestBuilder {

    static let host = "graph.microsoft.com"
    static let version = "/v1.0"
    /// Rows read per page.
    static let pageSize = 500
    /// Rows added per request.
    static let maximumRowsPerRequest = 200
    /// The longest sharing link taken.
    static let maximumLinkLength = 2048

    // MARK: - Sign-in

    static func me() -> GraphRequest {
        GraphRequest(method: .get, path: version + "/me",
                     query: [URLQueryItem(name: "$select", value: "userPrincipalName")])
    }

    static func organization() -> GraphRequest {
        GraphRequest(method: .get, path: version + "/organization",
                     query: [URLQueryItem(name: "$select", value: "countryLetterCode")])
    }

    // MARK: - The workbook

    /// Whether a pasted link is a sharing link to a file in Microsoft 365: HTTPS, on SharePoint or
    /// OneDrive, with no user name or password.
    static func isSharingLink(_ raw: String) -> Bool {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.count <= maximumLinkLength, let url = URL(string: link), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".sharepoint.com") || host == "onedrive.live.com" || host == "1drv.ms"
    }

    /// The share id Graph takes for a link: "u!" and the link in unpadded base64url.
    static func shareID(_ link: String) -> String {
        "u!" + PKCE.base64URL(Data(link.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    /// Nil for anything that is not a sharing link.
    static func resolveShare(link: String) -> GraphRequest? {
        guard isSharingLink(link) else { return nil }
        return GraphRequest(method: .get, path: version + "/shares/\(shareID(link))/driveItem",
                            query: [URLQueryItem(name: "$select", value: "id,name,parentReference,file")])
    }

    static func tables(in workbook: GraphWorkbook) -> GraphRequest {
        GraphRequest(method: .get, path: version + workbook.path + "/tables",
                     query: [URLQueryItem(name: "$select", value: "id,name")])
    }

    static func columns(of table: ClinicalStockWorkbookTable, in workbook: GraphWorkbook) -> GraphRequest {
        GraphRequest(method: .get, path: version + workbook.path + "/tables/\(table.rawValue)/columns",
                     query: [URLQueryItem(name: "$select", value: "name")])
    }

    static func rows(of table: ClinicalStockWorkbookTable, in workbook: GraphWorkbook, skip: Int) -> GraphRequest {
        GraphRequest(method: .get, path: version + workbook.path + "/tables/\(table.rawValue)/rows",
                     query: [URLQueryItem(name: "$top", value: String(pageSize)),
                             URLQueryItem(name: "$skip", value: String(max(0, skip)))])
    }

    // MARK: - Creating the two tables

    static func addWorksheet(for table: ClinicalStockWorkbookTable, in workbook: GraphWorkbook) -> GraphRequest {
        json(.post, workbook.path + "/worksheets/add", ["name": table.rawValue])
    }

    static func writeHeaders(of table: ClinicalStockWorkbookTable, in workbook: GraphWorkbook) -> GraphRequest {
        json(.patch, workbook.path + "/worksheets/\(table.rawValue)/range(address='\(table.headerAddress)')",
             ["values": [table.headers]])
    }

    static func addTable(_ table: ClinicalStockWorkbookTable, in workbook: GraphWorkbook) -> GraphRequest {
        json(.post, workbook.path + "/tables/add", ["address": "\(table.rawValue)!\(table.headerAddress)", "hasHeaders": true])
    }

    /// Nil for a table id Graph would not have given: 1–64 letters, digits, braces and hyphens.
    static func nameTable(id: String, as table: ClinicalStockWorkbookTable, in workbook: GraphWorkbook) -> GraphRequest? {
        guard isTableID(id) else { return nil }
        return json(.patch, workbook.path + "/tables/\(encodedTableID(id))", ["name": table.rawValue])
    }

    static func isTableID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "{}-".unicodeScalars.contains($0)
        }
    }

    static func encodedTableID(_ id: String) -> String {
        id.replacingOccurrences(of: "{", with: "%7B").replacingOccurrences(of: "}", with: "%7D")
    }

    // MARK: - Adding rows

    /// The most columns a table may have for rows to be added to it.
    static let maximumColumns = 64

    /// Rows laid out in the table's own columns (`columns`, as the workbook has them now: staff may
    /// have added some, which get an empty cell). Nil when `rows` is empty, longer than one request
    /// takes, holds a row for the other table, or the table is missing one of its fixed columns.
    static func addRows(_ rows: [KeyedShareRow], to table: ClinicalStockWorkbookTable, columns: [String]? = nil,
                        in workbook: GraphWorkbook) -> GraphRequest? {
        let columns = columns ?? table.headers
        let position = Dictionary(table.headers.enumerated().map { (ClinicalStockWorkbookSchema.normalised($1), $0) },
                                  uniquingKeysWith: { first, _ in first })
        let layout = columns.map { position[ClinicalStockWorkbookSchema.normalised($0)] }
        guard !rows.isEmpty, rows.count <= maximumRowsPerRequest, columns.count <= maximumColumns,
              Set(layout.compactMap { $0 }).count == table.headers.count,
              rows.allSatisfy({ ClinicalStockWorkbookTable.of($0.row) == table }) else { return nil }
        let values = rows.map { keyed -> [Any] in
            let cells = ClinicalStockWorkbookSchema.cells(keyed)
            return layout.map { $0.map { cells[$0].json } ?? "" }
        }
        return json(.post, workbook.path + "/tables/\(table.rawValue)/rows", ["index": NSNull(), "values": values])
    }

    private static func json(_ method: GraphRequest.Method, _ path: String, _ body: [String: Any]) -> GraphRequest {
        let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return GraphRequest(method: method, path: version + path, body: data, contentType: "application/json")
    }

    // MARK: - The check

    /// Whether `request` is one of the shapes above, on `workbook` where it names one. The transport
    /// runs this before every request to Graph.
    static func isAllowed(_ request: GraphRequest, workbook: GraphWorkbook?) -> Bool {
        guard request.host == host, request.path.hasPrefix(version + "/") else { return false }
        let path = String(request.path.dropFirst(version.count))
        let query = Dictionary(request.query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })

        switch (request.method, path) {
        case (.get, "/me"):
            return request.body == nil && query == ["$select": "userPrincipalName"]
        case (.get, "/organization"):
            return request.body == nil && query == ["$select": "countryLetterCode"]
        default:
            break
        }
        if request.method == .get, path.hasPrefix("/shares/u!"), path.hasSuffix("/driveItem") {
            let id = path.dropFirst("/shares/u!".count).dropLast("/driveItem".count)
            return request.body == nil && !id.isEmpty
                && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
                && query == ["$select": "id,name,parentReference,file"]
        }

        guard let workbook, path.hasPrefix(workbook.path + "/") else { return false }
        let rest = String(path.dropFirst(workbook.path.count))
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]

        for table in ClinicalStockWorkbookTable.allCases {
            switch (request.method, rest) {
            case (.get, "/tables/\(table.rawValue)/columns"):
                return request.body == nil && query == ["$select": "name"]
            case (.get, "/tables/\(table.rawValue)/rows"):
                guard request.body == nil, Set(query.keys) == ["$top", "$skip"], query["$top"] == String(pageSize),
                      let skip = Int(query["$skip"] ?? ""), skip >= 0 else { return false }
                return true
            case (.post, "/tables/\(table.rawValue)/rows"):
                guard let body, Set(body.keys) == ["index", "values"], body["index"] is NSNull,
                      let values = body["values"] as? [[Any]], !values.isEmpty,
                      values.count <= maximumRowsPerRequest, let width = values.first?.count,
                      (table.headers.count...maximumColumns).contains(width) else { return false }
                return values.allSatisfy { $0.count == width }
            case (.patch, "/worksheets/\(table.rawValue)/range(address='\(table.headerAddress)')"):
                return (body?["values"] as? [[String]]) == [table.headers] && body?.count == 1
            default:
                continue
            }
        }
        switch (request.method, rest) {
        case (.get, "/tables"):
            return request.body == nil && query == ["$select": "id,name"]
        case (.post, "/worksheets/add"):
            return body?.count == 1 && ClinicalStockWorkbookTable(rawValue: body?["name"] as? String ?? "") != nil
        case (.post, "/tables/add"):
            guard let body, body.count == 2, body["hasHeaders"] as? Bool == true,
                  let address = body["address"] as? String else { return false }
            return ClinicalStockWorkbookTable.allCases.contains { address == "\($0.rawValue)!\($0.headerAddress)" }
        default:
            break
        }
        if request.method == .patch, rest.hasPrefix("/tables/") {
            let id = String(rest.dropFirst("/tables/".count))
                .replacingOccurrences(of: "%7B", with: "{").replacingOccurrences(of: "%7D", with: "}")
            return isTableID(id) && ClinicalStockWorkbookTable(rawValue: id) == nil && body?.count == 1
                && ClinicalStockWorkbookTable(rawValue: body?["name"] as? String ?? "") != nil
        }
        return false
    }
}

// MARK: - Reading Graph's replies

/// The parts of Graph's replies the connection reads. Pure; anything else in a reply is ignored.
enum GraphReply {

    struct DriveItem: Equatable, Sendable {
        let workbook: GraphWorkbook
        let name: String
    }

    struct Table: Equatable, Sendable {
        let id: String
        let name: String
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func values(_ data: Data) -> [[String: Any]]? {
        object(data)?["value"] as? [[String: Any]]
    }

    static func account(_ data: Data) -> String? {
        (object(data)?["userPrincipalName"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }
    }

    /// The organisation's two-letter country, upper-cased. Nil when Graph did not give one.
    static func country(_ data: Data) -> String? {
        guard let code = values(data)?.first?["countryLetterCode"] as? String else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.count == 2 && trimmed.allSatisfy({ $0.isASCII && $0.isLetter }) ? trimmed : nil
    }

    /// The workbook a sharing link names. Nil for a folder, or for a file that is not an Excel
    /// workbook.
    static func driveItem(_ data: Data) -> DriveItem? {
        guard let object = object(data), let id = object["id"] as? String, let name = object["name"] as? String,
              object["file"] != nil, name.lowercased().hasSuffix(".xlsx"),
              let drive = (object["parentReference"] as? [String: Any])?["driveId"] as? String,
              let workbook = GraphWorkbook(driveID: drive, itemID: id) else { return nil }
        return DriveItem(workbook: workbook, name: String(name.prefix(255)))
    }

    static func tables(_ data: Data) -> [Table]? {
        values(data)?.compactMap { table in
            guard let id = table["id"] as? String, let name = table["name"] as? String else { return nil }
            return Table(id: id, name: name)
        }
    }

    /// A new table's id, from `tables/add`.
    static func addedTable(_ data: Data) -> String? {
        (object(data)?["id"] as? String).flatMap { GraphRequestBuilder.isTableID($0) ? $0 : nil }
    }

    static func columnNames(_ data: Data) -> [String]? {
        values(data)?.compactMap { $0["name"] as? String }
    }

    /// One page of rows' cells.
    static func rows(_ data: Data) -> [[Any]]? {
        values(data)?.compactMap { ($0["values"] as? [[Any]])?.first }
    }
}
