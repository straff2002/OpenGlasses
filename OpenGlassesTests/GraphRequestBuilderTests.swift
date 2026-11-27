import XCTest
@testable import OpenGlasses

/// Plan NK §3 — the connection may make only the named requests, all on Graph v1.0 and the one
/// workbook; the transport refuses a foreign host, a redirect and an oversized reply, keeps the
/// token in a header, and never sends it to the sign-in host. No network: the wire is a stub.
final class GraphRequestBuilderTests: XCTestCase {

    private let workbook = GraphWorkbook(driveID: "b!drive-1", itemID: "01ITEM")!
    private let other = GraphWorkbook(driveID: "b!drive-2", itemID: "01OTHER")!

    override func setUp() {
        super.setUp()
        MedicalEgressGuard.currentMode = { .off }
    }

    override func tearDown() {
        MedicalEgressGuard.currentMode = { MedicalEgressGuard.Mode(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly) }
        StockTransportStubProtocol.answer { _ in .failure(URLError(.notConnectedToInternet)) }
        super.tearDown()
    }

    private var keyed: [KeyedShareRow] { ClinicWorkbookSamples.keyed([ClinicWorkbookSamples.row(.given, 3)]) }

    /// Every request the builder can make, for the one workbook.
    private var everything: [GraphRequest] {
        var requests = [GraphRequestBuilder.me(), GraphRequestBuilder.organization(),
                        GraphRequestBuilder.resolveShare(link: "https://clinic.sharepoint.com/:x:/s/stock/EaBc?e=1")!,
                        GraphRequestBuilder.tables(in: workbook)]
        for table in ClinicalStockWorkbookTable.allCases {
            requests += [GraphRequestBuilder.columns(of: table, in: workbook),
                         GraphRequestBuilder.rows(of: table, in: workbook, skip: 500),
                         GraphRequestBuilder.addWorksheet(for: table, in: workbook),
                         GraphRequestBuilder.writeHeaders(of: table, in: workbook),
                         GraphRequestBuilder.addTable(table, in: workbook),
                         GraphRequestBuilder.nameTable(id: "{00000000-0001-0000-C000-000000000000}", as: table, in: workbook)!]
        }
        requests.append(GraphRequestBuilder.addRows(keyed, to: .movements, in: workbook)!)
        requests.append(GraphRequestBuilder.addRows(ClinicWorkbookSamples.keyed([ClinicWorkbookSamples.row(.counted, 9)]),
                                                    to: .counts, in: workbook)!)
        return requests
    }

    // MARK: - Only the named requests, on one workbook

    func testEveryBuiltRequestIsAllowedOnGraphV1AndItsWorkbookOnly() throws {
        for request in everything {
            XCTAssertTrue(GraphRequestBuilder.isAllowed(request, workbook: workbook), request.path)
            let url = try XCTUnwrap(request.url, request.path)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "graph.microsoft.com")
            XCTAssertTrue(url.path.hasPrefix("/v1.0/"), url.path)
            if request.path.contains("/drives/") {
                XCTAssertTrue(request.path.hasPrefix("/v1.0/drives/b!drive-1/items/01ITEM/workbook/"), request.path)
                XCTAssertFalse(GraphRequestBuilder.isAllowed(request, workbook: other), "another workbook: \(request.path)")
                XCTAssertFalse(GraphRequestBuilder.isAllowed(request, workbook: nil), request.path)
            }
        }
        XCTAssertEqual(everything.count, 18)
    }

    func testAnythingElseIsRefused() {
        let base = "/v1.0" + workbook.path
        let refused: [GraphRequest] = [
            GraphRequest(method: .get, path: "/v1.0/me/drive/root/children"),
            GraphRequest(method: .get, path: "/v1.0/users"),
            GraphRequest(method: .get, path: "/v1.0/me"),                                             // no $select
            GraphRequest(method: .get, path: "/beta/me", query: [URLQueryItem(name: "$select", value: "userPrincipalName")]),
            GraphRequest(method: .get, path: "/v1.0/drives/b!drive-1/items/01ITEM/content"),
            GraphRequest(method: .get, path: base + "/worksheets"),
            GraphRequest(method: .get, path: base + "/tables/Patients/rows",
                         query: [URLQueryItem(name: "$top", value: "500"), URLQueryItem(name: "$skip", value: "0")]),
            GraphRequest(method: .get, path: base + "/tables/Movements/rows",
                         query: [URLQueryItem(name: "$top", value: "500"), URLQueryItem(name: "$skip", value: "-1")]),
            GraphRequest(method: .patch, path: base + "/tables/Movements/rows/itemAt(index=0)", body: Data("{}".utf8)),
            GraphRequest(method: .post, path: base + "/worksheets/add", body: Data(#"{"name":"Patients"}"#.utf8)),
            GraphRequest(method: .post, path: base + "/tables/add", body: Data(#"{"address":"Sheet1!A1:Z99","hasHeaders":true}"#.utf8)),
            GraphRequest(method: .patch, path: base + "/worksheets/Movements/range(address='A1:J1')",
                         body: Data(#"{"values":[["Name","DOB"]]}"#.utf8)),
            GraphRequest(method: .patch, path: base + "/tables/Movements", body: Data(#"{"name":"Counts"}"#.utf8)),
            GraphRequest(method: .patch, path: base + "/tables/%7B1%7D", body: Data(#"{"name":"Patients"}"#.utf8)),
            GraphRequest(method: .post, path: base + "/tables/Movements/rows", body: Data(#"{"index":null,"values":[["a"]]}"#.utf8)),
            GraphRequest(method: .get, host: "graph.microsoft.com.example.invalid", path: "/v1.0/organization",
                         query: [URLQueryItem(name: "$select", value: "countryLetterCode")]),
        ]
        for request in refused {
            XCTAssertFalse(GraphRequestBuilder.isAllowed(request, workbook: workbook), "\(request.method) \(request.path)")
        }
    }

    func testOnlyASharingLinkInMicrosoft365IsResolved() throws {
        for link in ["https://clinic.sharepoint.com/:x:/s/stock/EaBc", "https://onedrive.live.com/edit?id=1", "https://1drv.ms/x/s!Ab"] {
            XCTAssertNotNil(GraphRequestBuilder.resolveShare(link: link), link)
        }
        for link in ["http://clinic.sharepoint.com/x", "https://evil.example/clinic.sharepoint.com", "https://user:pw@clinic.sharepoint.com/x",
                     "not a link", "https://sharepoint.com.example.invalid/x", String(repeating: "a", count: 3000)] {
            XCTAssertNil(GraphRequestBuilder.resolveShare(link: link), link)
        }
        // The share id is the link itself, unpadded base64url, as Graph documents it.
        let link = "https://clinic.sharepoint.com/:x:/s/stock/EaBc?e=1"
        let id = GraphRequestBuilder.shareID(link)
        XCTAssertTrue(id.hasPrefix("u!"))
        XCTAssertFalse(id.contains("=") || id.contains("+") || id.contains("/"))
        var encoded = String(id.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        XCTAssertEqual(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }, link)
    }

    func testIdsThatCouldLeaveThePathAreRefused() {
        XCTAssertNil(GraphWorkbook(driveID: "b!drive/../x", itemID: "01"))
        XCTAssertNil(GraphWorkbook(driveID: "b!drive", itemID: "01?x=1"))
        XCTAssertNil(GraphWorkbook(driveID: "", itemID: "01"))
        XCTAssertNil(GraphRequestBuilder.nameTable(id: "1/../../x", as: .movements, in: workbook))
        XCTAssertEqual(GraphRequestBuilder.nameTable(id: "{AB-1}", as: .counts, in: workbook)?.path,
                       "/v1.0" + workbook.path + "/tables/%7BAB-1%7D")
    }

    // MARK: - Adding rows

    func testRowsAreAddedOnlyToTheirOwnTableAndInItsColumns() throws {
        let given = ClinicWorkbookSamples.keyed([ClinicWorkbookSamples.row(.given, 3)])
        let count = ClinicWorkbookSamples.keyed([ClinicWorkbookSamples.row(.counted, 9)])
        XCTAssertNil(GraphRequestBuilder.addRows([], to: .movements, in: workbook))
        XCTAssertNil(GraphRequestBuilder.addRows(given + count, to: .movements, in: workbook), "a count is not a movement")
        XCTAssertNil(GraphRequestBuilder.addRows(count, to: .movements, in: workbook))
        let many = Array(repeating: given[0], count: GraphRequestBuilder.maximumRowsPerRequest + 1)
        XCTAssertNil(GraphRequestBuilder.addRows(many, to: .movements, in: workbook))
        XCTAssertNil(GraphRequestBuilder.addRows(given, to: .movements, columns: ["Day", "Line"], in: workbook),
                     "a table missing a fixed column takes nothing")

        // Staff added a column in the middle: it gets an empty cell, and the rest keep their names.
        let columns = ["Day", "Span", "Checked by", "Line number", "Line", "Lot", "Expiry", "Kind", "Quantity", "Reason", "Row key"]
        let request = try XCTUnwrap(GraphRequestBuilder.addRows(given, to: .movements, columns: columns, in: workbook))
        XCTAssertTrue(GraphRequestBuilder.isAllowed(request, workbook: workbook))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        let row = try XCTUnwrap((body["values"] as? [[Any]])?.first)
        XCTAssertEqual(row.count, 11)
        XCTAssertEqual(row[2] as? String, "")
        XCTAssertEqual(row[4] as? String, "'Flu vaccine")
        XCTAssertEqual(row[10] as? String, "'" + given[0].key)
        XCTAssertTrue(body["index"] is NSNull)
    }

    // MARK: - Replies

    func testRepliesAreReadForWhatTheConnectionNeedsOnly() throws {
        let item = try XCTUnwrap(GraphReply.driveItem(Data(#"{"id":"01ITEM","name":"Fridge.xlsx","file":{},"parentReference":{"driveId":"b!drive-1"}}"#.utf8)))
        XCTAssertEqual(item.workbook, workbook)
        XCTAssertEqual(item.name, "Fridge.xlsx")
        XCTAssertNil(GraphReply.driveItem(Data(#"{"id":"01","name":"Stock","folder":{},"parentReference":{"driveId":"b!d"}}"#.utf8)), "a folder")
        XCTAssertNil(GraphReply.driveItem(Data(#"{"id":"01","name":"Stock.docx","file":{},"parentReference":{"driveId":"b!d"}}"#.utf8)))
        XCTAssertEqual(GraphReply.country(Data(#"{"value":[{"countryLetterCode":"ca"}]}"#.utf8)), "CA")
        XCTAssertNil(GraphReply.country(Data(#"{"value":[{"countryLetterCode":""}]}"#.utf8)))
        XCTAssertEqual(GraphReply.tables(Data(#"{"value":[{"id":"{1}","name":"Movements"}]}"#.utf8)),
                       [GraphReply.Table(id: "{1}", name: "Movements")])
        XCTAssertEqual(GraphReply.columnNames(Data(#"{"value":[{"name":"Day"},{"name":"Lot"}]}"#.utf8)), ["Day", "Lot"])
        XCTAssertEqual(GraphReply.rows(Data(#"{"value":[{"index":0,"values":[["2026-11-25",3]]}]}"#.utf8))?.first?.count, 2)
        XCTAssertNil(GraphReply.addedTable(Data(#"{"id":"../x"}"#.utf8)))
        XCTAssertEqual(GraphReply.account(Data(#"{"userPrincipalName":"staff@clinic.example"}"#.utf8)), "staff@clinic.example")
    }

    // MARK: - The transport

    private func transport() -> URLSessionClinicWorkbookTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StockTransportStubProtocol.self]
        return URLSessionClinicWorkbookTransport(configuration: configuration)
    }

    func testTheTokenIsABearerHeaderToGraphAndNeverGoesToTheSignInHost() throws {
        let graph = try URLSessionClinicWorkbookTransport.urlRequest(GraphRequestBuilder.tables(in: workbook), bearer: "abc.def",
                                                                     workbook: workbook)
        XCTAssertEqual(graph.value(forHTTPHeaderField: "Authorization"), "Bearer abc.def")
        XCTAssertFalse(graph.url?.absoluteString.contains("abc.def") ?? true)
        let token = try URLSessionClinicWorkbookTransport.urlRequest(
            EntraOAuth.refreshRequest(clientID: "11111111-2222-3333-4444-555555555555", refreshToken: "r"), bearer: "abc.def",
            workbook: nil)
        XCTAssertNil(token.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(token.url?.host, "login.microsoftonline.com")
        XCTAssertThrowsError(try URLSessionClinicWorkbookTransport.urlRequest(GraphRequestBuilder.tables(in: workbook),
                                                                              bearer: "abc def\r\nX: 1", workbook: workbook))
    }

    func testAForeignHostOrAnOffListRequestIsRefusedBeforeTheWire() {
        let foreign = GraphRequest(method: .get, host: "graph.microsoft.com.example.invalid", path: "/v1.0/me",
                                   query: [URLQueryItem(name: "$select", value: "userPrincipalName")])
        XCTAssertThrowsError(try URLSessionClinicWorkbookTransport.urlRequest(foreign, bearer: "t", workbook: nil)) {
            XCTAssertEqual($0 as? ClinicWorkbookTransportRefusal, .foreignHost)
        }
        let login = GraphRequest(method: .get, host: "login.microsoftonline.com", path: "/organizations/oauth2/v2.0/authorize")
        XCTAssertThrowsError(try URLSessionClinicWorkbookTransport.urlRequest(login, bearer: nil, workbook: nil)) {
            XCTAssertEqual($0 as? ClinicWorkbookTransportRefusal, .offList)
        }
        XCTAssertThrowsError(try URLSessionClinicWorkbookTransport.urlRequest(GraphRequestBuilder.tables(in: workbook),
                                                                              bearer: "t", workbook: other)) {
            XCTAssertEqual($0 as? ClinicWorkbookTransportRefusal, .offList)
        }
        XCTAssertEqual(URLSessionClinicWorkbookTransport.hosts, ["graph.microsoft.com", "login.microsoftonline.com"])
    }

    func testARedirectIsRefused() async throws {
        StockTransportStubProtocol.answer { _ in
            .response(status: 302, headers: ["Location": "https://evil.example.invalid/v1.0/me"], body: Data())
        }
        do {
            _ = try await transport().send(GraphRequestBuilder.me(), bearer: "t", workbook: nil)
            XCTFail("a redirect was followed")
        } catch {
            XCTAssertEqual(error as? ClinicWorkbookTransportRefusal, .redirected)
        }
        XCTAssertEqual(StockTransportStubProtocol.seen.map { $0.url?.host }, ["graph.microsoft.com"])

        let session = URLSession(configuration: .ephemeral)
        let redirect = HTTPURLResponse(url: URL(string: "https://graph.microsoft.com/v1.0/me")!, statusCode: 301,
                                       httpVersion: nil, headerFields: nil)!
        var followed: URLRequest? = URLRequest(url: URL(string: "https://example.invalid")!)
        transport().urlSession(session, task: session.dataTask(with: URLRequest(url: redirect.url!)),
                               willPerformHTTPRedirection: redirect,
                               newRequest: URLRequest(url: URL(string: "https://evil.example.invalid")!)) { followed = $0 }
        XCTAssertNil(followed)
        session.invalidateAndCancel()
    }

    func testAnOversizedReplyIsRefused() async throws {
        let cap = URLSessionClinicWorkbookTransport.maximumResponseBytes
        for headers in [["Content-Length": String(cap + 1)], [:]] {
            StockTransportStubProtocol.answer { _ in .response(status: 200, headers: headers, body: Data(count: cap + 1)) }
            do {
                _ = try await transport().send(GraphRequestBuilder.organization(), bearer: "t", workbook: nil)
                XCTFail("a reply over the cap was read")
            } catch {
                XCTAssertEqual(error as? ClinicWorkbookFailure, .tooLarge)
            }
        }
        StockTransportStubProtocol.answer { _ in .response(status: 200, headers: ["Retry-After": "7"], body: Data("{}".utf8)) }
        let fits = try await transport().send(GraphRequestBuilder.organization(), bearer: "t", workbook: nil)
        XCTAssertEqual(fits.body, Data("{}".utf8))
        XCTAssertEqual(fits.retryAfter, 7)
    }

    func testNoConnectionIsUnreachableAndStatusesMapToFailures() async throws {
        StockTransportStubProtocol.answer { _ in .failure(URLError(.notConnectedToInternet)) }
        do {
            _ = try await transport().send(GraphRequestBuilder.me(), bearer: "t", workbook: nil)
            XCTFail("no connection was not reported")
        } catch {
            XCTAssertEqual(error as? ClinicWorkbookFailure, .unreachable)
        }
        XCTAssertNil(ClinicWorkbookFailure.from(status: 201, retryAfter: nil))
        XCTAssertEqual(ClinicWorkbookFailure.from(status: 401, retryAfter: nil), .unauthorized)
        XCTAssertEqual(ClinicWorkbookFailure.from(status: 403, retryAfter: nil), .forbidden)
        XCTAssertEqual(ClinicWorkbookFailure.from(status: 404, retryAfter: nil), .notFound)
        XCTAssertEqual(ClinicWorkbookFailure.from(status: 429, retryAfter: 5), .rateLimited(5))
        XCTAssertEqual(ClinicWorkbookFailure.from(status: 503, retryAfter: nil), .rateLimited(nil))
        XCTAssertEqual(ClinicWorkbookFailure.from(status: 500, retryAfter: nil), .server)
    }

    /// The clinic's own record system: Medical Local Only does not stop it, as it does not stop
    /// the FHIR export.
    func testLocalOnlyLetsTheClinicsOwnRecordThrough() async throws {
        MedicalEgressGuard.currentMode = { .localOnly }
        StockTransportStubProtocol.answer { _ in .response(status: 200, headers: [:], body: Data("{}".utf8)) }
        _ = try await transport().send(GraphRequestBuilder.organization(), bearer: "t", workbook: nil)
        XCTAssertEqual(StockTransportStubProtocol.seen.count, 1)
    }
}
