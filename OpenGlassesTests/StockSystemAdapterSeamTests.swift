import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan MM P1 — the vendor-neutral seam every stock system plugs into: the request value, the
/// driver loop, the common idempotency and time rules, and the guard that the common folder names
/// no vendor.
final class StockSystemAdapterSeamTests: XCTestCase {

    private let read = StockSystemEndpoint(.get, "/v1/stores/{store}/items", purpose: .stock, scope: "stock:read")
    private let write = StockSystemEndpoint(.post, "/v1/adjustments", purpose: .write, scope: "stock:write")
    private var allowed: [StockSystemEndpoint] { [read, write] }

    // MARK: - The common folder names no vendor

    /// Every common file, comments included: everything under `StockSystem/` except a vendor's own
    /// adapter folder (one holding a type that conforms to `StockSystemAdapter`) and `Registry/`,
    /// which is the one place adapters are listed by name; and the common files elsewhere (Plan MM
    /// P2's settings view). Only these may name a vendor: an adapter's folder, the registry, the
    /// network route, the privacy manifest and copy, tests and docs.
    func testTheCommonFilesNameNoVendor() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folder = repo.appendingPathComponent("OpenGlasses/Sources/Services/FieldAssist/StockSystem")
        let manager = FileManager.default
        var common: [URL] = []
        var vendorFolders: [String] = []
        for entry in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
            let isFolder = (try entry.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            guard isFolder else {
                if entry.pathExtension == "swift" { common.append(entry) }
                continue
            }
            let files = (manager.enumerator(at: entry, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "swift" }
            if entry.lastPathComponent == "Registry" { continue }
            let isAdapter = try files.contains { try String(contentsOf: $0, encoding: .utf8).contains(": StockSystemAdapter {") }
            if isAdapter { vendorFolders.append(entry.lastPathComponent); continue }
            common += files
        }
        let elsewhere = ["OpenGlasses/Sources/App/Views/StockSystemSettingsView.swift",
                         // Plan MM P3: van stock speaking for a system-held place, and its screen.
                         "OpenGlasses/Sources/App/Views/Job/StockSystemStockSection.swift",
                         "OpenGlasses/Sources/Services/FieldAssist/VanStock/VanStockService.swift",
                         "OpenGlasses/Sources/Services/NativeTools/VanStockTool.swift",
                         // Plan MM P4: the parts step, and the close and record it feeds.
                         "OpenGlasses/Sources/App/Views/Job/StockSystemPartsSendSheet.swift",
                         "OpenGlasses/Sources/App/Views/Job/JobTab.swift",
                         "OpenGlasses/Sources/Services/FieldAssist/Job/JobCloseSequence.swift",
                         "OpenGlasses/Sources/Services/FieldAssist/Job/GuidedJobFlow.swift",
                         "OpenGlasses/Sources/Services/FieldAssist/VanStock/VanStockUse.swift",
                         "OpenGlasses/Sources/Services/FieldAssist/VanStock/VanStockImportService.swift"]
        common += elsewhere.map { repo.appendingPathComponent($0) }
        XCTAssertGreaterThanOrEqual(common.count, 24, "the common files are there to scan")
        for required in ["StockSystemConnectionStore", "StockSystemTransport", "StockSystemHTTPConnector",
                         "StockSystemSnapshotStore", "StockSystemService", "StockSystemSettingsView",
                         "StagedStockUseStore", "StockSystemFreshLines", "StockSystemVanStock", "StockSystemScreenModel",
                         "StockSystemStockSection", "VanStockService", "VanStockTool",
                         "StockSystemPartsDelivery", "StockSystemPartsUsed", "StockSystemSyncSink",
                         "StockSystemPartsSendSheet", "GuidedJobFlow", "JobCloseSequence"] {
            XCTAssertTrue(common.contains { $0.lastPathComponent == required + ".swift" }, "\(required) is scanned")
        }
        for file in common {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            for vendor in ["square", "simpro", "shopify", "lightspeed"] {
                XCTAssertFalse(text.contains(vendor), "\(file.lastPathComponent) names \(vendor)")
            }
        }
        // The vendor's adapter lives in its own subfolder, and the registry lists it.
        XCTAssertEqual(vendorFolders, ["Square"])
        XCTAssertTrue(manager.fileExists(atPath: folder.appendingPathComponent("Square/SquareStockAdapter.swift").path))
        XCTAssertTrue(manager.fileExists(atPath: folder.appendingPathComponent("Registry/StockSystemAdapterRegistry.swift").path))
    }

    // MARK: - The request value

    func testARequestFillsItsPathFromCheckedIdentifiersOnly() throws {
        let request = try StockSystemRequest(read, allowed: allowed, parameters: ["store": "ST-1_a.b"],
                                             query: [URLQueryItem(name: "page", value: "2")])
        XCTAssertEqual(request.path, "/v1/stores/ST-1_a.b/items")
        XCTAssertEqual(request.url(host: "api.example.invalid")?.absoluteString, "https://api.example.invalid/v1/stores/ST-1_a.b/items?page=2")
        for bad in ["", "..", ".", "a/b", "a?b", "a b", "a%2Fb", "é", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try StockSystemRequest(read, allowed: allowed, parameters: ["store": bad]), bad) {
                XCTAssertEqual($0 as? StockSystemRequestRefusal, .badParameter)
            }
        }
        XCTAssertThrowsError(try StockSystemRequest(read, allowed: allowed), "a missing parameter")
        XCTAssertThrowsError(try StockSystemRequest(read, allowed: allowed, parameters: ["store": "S", "extra": "E"]),
                             "an unexpected parameter")
        XCTAssertThrowsError(try StockSystemRequest(write, allowed: allowed, parameters: ["store": "S"]))
    }

    func testARequestIsOnlyForAnEndpointOnTheList() {
        let other = StockSystemEndpoint(.post, "/v1/counts", purpose: .write, scope: nil)
        XCTAssertThrowsError(try StockSystemRequest(other, allowed: allowed)) {
            XCTAssertEqual($0 as? StockSystemRequestRefusal, .offList)
        }
        XCTAssertThrowsError(try StockSystemRequest(write, allowed: [read]))
        XCTAssertNoThrow(try StockSystemRequest(write, allowed: allowed, body: Data("{}".utf8)))
    }

    func testABodyGoesOnlyOnAPostAndWithinItsCap() {
        XCTAssertThrowsError(try StockSystemRequest(read, allowed: allowed, parameters: ["store": "S"], body: Data("{}".utf8))) {
            XCTAssertEqual($0 as? StockSystemRequestRefusal, .badBody)
        }
        XCTAssertThrowsError(try StockSystemRequest(write, allowed: allowed,
                                                    body: Data(count: StockSystemRequest.maximumBodyBytes + 1)))
    }

    func testCredentialHeadersAndControlCharactersAreRefused() {
        for (name, value) in [("Authorization", "Bearer x"), ("AUTHORIZATION", "x"), ("Cookie", "a=b"), ("Host", "evil.invalid"),
                              ("X-Api-Key", "x"), ("Version", "1\r\nInjected: yes"), ("Bad Name", "x"), ("", "x")] {
            XCTAssertThrowsError(try StockSystemRequest(write, allowed: allowed, headers: [name: value]), name) {
                XCTAssertEqual($0 as? StockSystemRequestRefusal, .forbiddenHeader)
            }
        }
        XCTAssertNoThrow(try StockSystemRequest(write, allowed: allowed, headers: ["Api-Version": "2026-01-01"]))
    }

    func testAURLIsHTTPSOnAPlainHostOnly() throws {
        let request = try StockSystemRequest(write, allowed: allowed)
        XCTAssertEqual(request.url(host: "api.example.invalid")?.scheme, "https")
        for host in ["", "evil.invalid/path", "user@evil.invalid", "evil.invalid:8443", "http://evil.invalid", "a b"] {
            XCTAssertNil(request.url(host: host), host)
        }
    }

    func testADescriptionNamesTheMethodPathAndSizeOnly() throws {
        let request = try StockSystemRequest(write, allowed: allowed, body: Data(#"{"secretish":"value-in-body"}"#.utf8),
                                             headers: ["Api-Version": "header-value"])
        var dumped = ""
        dump(request, to: &dumped)
        for text in [String(describing: request), String(reflecting: request), dumped] {
            XCTAssertFalse(text.contains("value-in-body"), text)
            XCTAssertFalse(text.contains("header-value"), text)
        }
        XCTAssertEqual(request.description, "POST /v1/adjustments (29-byte body)")
    }

    func testAResponseReadsHeadersWithoutRegardToCase() {
        let response = StockSystemResponse(status: 429, body: Data(), headers: ["retry-after": "3"])
        XCTAssertEqual(response.header("Retry-After"), "3")
        XCTAssertFalse(response.succeeded)
        XCTAssertTrue(StockSystemResponse(status: 204, body: Data()).succeeded)
    }

    // MARK: - The driver

    /// A two-page fake plan: the shape every system's paging takes.
    private struct PagedPlan: StockSystemPullPlan {
        let endpoint: StockSystemEndpoint
        let allowed: [StockSystemEndpoint]
        var pages: Int
        var asked = 0
        var waiting = false
        var items: [String] = []
        var result: [String]?

        mutating func next() throws -> StockSystemRequest? {
            guard result == nil else { return nil }
            asked += 1
            return try StockSystemRequest(endpoint, allowed: allowed, parameters: ["store": "S"],
                                          query: [URLQueryItem(name: "page", value: String(asked))])
        }

        mutating func consume(_ response: StockSystemResponse) throws {
            guard response.succeeded else { throw StockSystemFailure.forStatus(response.status, endpoint: endpoint)! }
            items.append(String(decoding: response.body, as: UTF8.self))
            if asked >= pages { result = items }
        }
    }

    func testTheDriverLoopsAPlanUntilItHasItsResult() async throws {
        var sent: [String] = []
        let items = try await StockSystemPlanDriver.run(PagedPlan(endpoint: read, allowed: allowed, pages: 3),
                                                        allowed: allowed) { request in
            sent.append(request.query.first?.value ?? "")
            return StockSystemResponse(status: 200, body: Data("item-\(sent.count)".utf8))
        }
        XCTAssertEqual(items, ["item-1", "item-2", "item-3"])
        XCTAssertEqual(sent, ["1", "2", "3"])
    }

    func testTheDriverStopsOnAFailureABudgetAndAnOffListRequest() async {
        do {
            _ = try await StockSystemPlanDriver.run(PagedPlan(endpoint: read, allowed: allowed, pages: 3), allowed: allowed) { _ in
                StockSystemResponse(status: 401, body: Data())
            }
            XCTFail()
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .unauthorized(.invalid))
        }
        do {
            _ = try await StockSystemPlanDriver.run(PagedPlan(endpoint: read, allowed: allowed, pages: .max), allowed: allowed) { _ in
                StockSystemResponse(status: 200, body: Data())
            }
            XCTFail()
        } catch {
            XCTAssertEqual(error as? StockSystemFailure, .tooLarge)
        }
        // A plan that builds a request for an endpoint the transport was not given is refused
        // before anything is sent.
        var sent = 0
        do {
            _ = try await StockSystemPlanDriver.run(PagedPlan(endpoint: read, allowed: allowed, pages: 1), allowed: [write]) { _ in
                sent += 1
                return StockSystemResponse(status: 200, body: Data())
            }
            XCTFail()
        } catch {
            XCTAssertEqual(error as? StockSystemRequestRefusal, .offList)
        }
        XCTAssertEqual(sent, 0)
    }

    // MARK: - Idempotency and time

    func testTheBatchKeyIsSHA256OverTheSortedStepKeys() {
        let keys = ["b-key", "a-key", "c-key"]
        var bytes = Data()
        for key in keys.sorted() {
            bytes.append(contentsOf: Array(key.utf8))
            bytes.append(0)
        }
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(StockSystemIdempotency.batchKey(stepKeys: keys), expected)
        XCTAssertEqual(StockSystemIdempotency.batchKey(stepKeys: keys.reversed()), expected, "order does not matter")
        XCTAssertNotEqual(StockSystemIdempotency.batchKey(stepKeys: ["a-key", "b-key"]), expected)
        XCTAssertNotEqual(StockSystemIdempotency.batchKey(stepKeys: ["ab", "c"]), StockSystemIdempotency.batchKey(stepKeys: ["a", "bc"]),
                          "the zero byte keeps the keys apart")
        XCTAssertEqual(expected.count, 64)
    }

    func testAWritesTimeIsTheConfirmationUnlessItIsTooOld() {
        let now = Date(timeIntervalSince1970: 1_800_000_000.75)
        let hour: TimeInterval = 3600
        XCTAssertEqual(StockSystemIdempotency.occurredAt(confirmedAt: now.addingTimeInterval(-hour), now: now, maximumAge: 2 * hour),
                       Date(timeIntervalSince1970: 1_799_996_400))
        XCTAssertEqual(StockSystemIdempotency.occurredAt(confirmedAt: now.addingTimeInterval(-3 * hour), now: now, maximumAge: 2 * hour),
                       Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(StockSystemIdempotency.occurredAt(confirmedAt: now.addingTimeInterval(60), now: now, maximumAge: 2 * hour),
                       Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - The read-back seam

    func testAMismatchedStepIsNeitherAppliedNorSentAgain() {
        let snapshot = StockSystemSamples.snapshot([StockSystemSamples.row("A", [("L1", "3")]),
                                                    StockSystemSamples.row("B", [("L1", "3")])])
        let capabilities = StockSystemCapabilities(connectorID: "sample-system", displayName: "Sample System", hasJobs: false,
                                                   wholeNumbersOnly: false, adjustmentReasons: [.waste], chosenReason: .waste)
        let batch = ConfirmedStockUseBatch(jobID: "JOB-1", jobNumber: nil, locationID: "L1", lines: [
            StagedStockUse(id: "S1", itemID: "A", part: nil, description: "A", quantity: .whole(1), unit: .each, source: .spoken),
            StagedStockUse(id: "S2", itemID: "B", part: nil, description: "B", quantity: .whole(1), unit: .each, source: .spoken),
            StagedStockUse(id: "S3", itemID: "A", part: nil, description: "A", quantity: .whole(2), unit: .each, source: .spoken),
        ], confirmation: .person(.screen))
        let plan = PartsUsedWritePlan(batch: batch, reference: nil, capabilities: capabilities, snapshot: snapshot)
        let keys = plan.steps.map(\.idempotencyKey)
        let readBack = StockSystemReadBack(applied: [keys[0]], mismatched: [.init(idempotencyKey: keys[1], difference: .quantity)])
        XCTAssertEqual(plan.remaining(after: readBack).map(\.stagedLineID), ["S3"])
        XCTAssertEqual(plan.needsAttention(after: readBack).map(\.stagedLineID), ["S2"])
        XCTAssertEqual(readBack.needsAttention, [keys[1]])
        XCTAssertEqual(StockSystemReadBack(applied: []).mismatched, [])
    }
}
