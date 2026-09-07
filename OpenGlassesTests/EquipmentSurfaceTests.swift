import PDFKit
import XCTest
@testable import OpenGlasses

/// Plan EL P2 — the surfaces that say which machine the session is working on: the session card,
/// the line on the lens, and the exported record.
///
/// The card is exercised through `EquipmentSectionModel` rather than SwiftUI, so every state it
/// can be in — a vault that names no models, a session with nothing recognised, a session standing
/// at a unit — is provable, and so are the two writes it makes.
@MainActor
final class EquipmentSurfaceTests: XCTestCase {

    // MARK: - Fixtures

    /// A stand-in for `FieldSessionService`: the four things the surfaces read and write.
    @MainActor
    private final class FakeHost: EquipmentHosting {
        var activeEquipment: EquipmentIdentity?
        var modelIndex: VaultModelIndex
        private(set) var setCount = 0
        private(set) var clearCount = 0

        init(index: VaultModelIndex, active: EquipmentIdentity? = nil) {
            self.modelIndex = index
            self.activeEquipment = active
        }

        func setEquipment(_ identity: EquipmentIdentity) {
            activeEquipment = identity
            setCount += 1
        }

        func clearEquipment() {
            activeEquipment = nil
            clearCount += 1
        }
    }

    private static let vaultName = "Lennox SLP99 Furnace Service"

    /// Two model sections written the way the vault guide asks for them.
    private func modelIndex() -> VaultModelIndex {
        let core = """
        # Models — SLP99UHVK series

        ## SLP99UH070XV36BK (070XV36B, SLP99UHXV-070-36B; size code A)
        Input 70,000 BTUH.

        ## SLP99UH090XV60CK (090XV60C, -090-060C, SLP99UHXV-090-60C; size code d)
        Input 90,000 BTUH.
        """
        return VaultModelIndex(vaultName: Self.vaultName, files: [(filename: "models.md", contents: core)])
    }

    /// A vault whose headings name no models at all — every bundled vault.
    private func emptyIndex() -> VaultModelIndex {
        VaultModelIndex(vaultName: "Refrigeration Service",
                        files: [(filename: "error_codes.md", contents: "# Codes\n\n## Compressor lock\nE5 means…")])
    }

    private func identity(_ source: EquipmentIdentity.Source = .nameplate,
                          at date: Date = Date(timeIntervalSince1970: 1_757_000_520)) -> EquipmentIdentity {
        EquipmentIdentity(modelToken: "SLP99UH090XV60CK",
                          heading: "SLP99UH090XV60CK (090XV60C, -090-060C, SLP99UHXV-090-60C; size code d)",
                          file: "models.md", source: source, recognisedAt: date,
                          nameplateText: "MODEL SLP99UH090XV60CK  SER 5820A12345")
    }

    // MARK: - The card's states

    func testVaultWithNoModelsDrawsNothing() {
        let model = EquipmentSectionModel(host: FakeHost(index: emptyIndex()))
        XCTAssertEqual(model.state, .unavailable,
                       "a vault that names no models has no equipment to show, so the section is absent")
    }

    func testNoEquipmentOffersTheVaultsOwnModels() throws {
        let model = EquipmentSectionModel(host: FakeHost(index: modelIndex()))
        guard case .unset(let choices) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(choices.map(\.name), ["SLP99UH070XV36BK", "SLP99UH090XV60CK"])
        XCTAssertEqual(choices.map(\.file), ["models.md", "models.md"])
        XCTAssertFalse(choices.contains { $0.isActive })
    }

    func testActiveEquipmentShowsModelProvenanceAndHeading() throws {
        let host = FakeHost(index: modelIndex(), active: identity())
        let state = EquipmentSectionModel(host: host).state
        guard case .identified(let detail, let choices) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(detail.model, "SLP99UH090XV60CK")
        XCTAssertTrue(detail.heading.hasPrefix("SLP99UH090XV60CK (090XV60C"), detail.heading)
        XCTAssertEqual(detail.source, .nameplate)
        XCTAssertTrue(detail.provenance.hasPrefix("from the nameplate at "), detail.provenance)
        XCTAssertEqual(choices.filter(\.isActive).map(\.name), ["SLP99UH090XV60CK"],
                       "the active model is ticked in the list that can correct it")
    }

    func testPickingAModelRecordsItAsPickedOnThePhone() throws {
        let host = FakeHost(index: modelIndex())
        let model = EquipmentSectionModel(host: host)
        guard case .unset(let choices) = model.state else { return XCTFail("\(model.state)") }
        model.select(try XCTUnwrap(choices.last))

        XCTAssertEqual(host.setCount, 1)
        let recorded = try XCTUnwrap(host.activeEquipment)
        XCTAssertEqual(recorded.modelToken, "SLP99UH090XV60CK")
        XCTAssertEqual(recorded.file, "models.md")
        XCTAssertEqual(recorded.source, .manual,
                       "a tapped row is not a nameplate read, and the audit record must not say it was")
        XCTAssertNil(recorded.nameplateText)
    }

    func testClearingForgetsTheMachine() {
        let host = FakeHost(index: modelIndex(), active: identity())
        EquipmentSectionModel(host: host).clear()
        XCTAssertEqual(host.clearCount, 1)
        XCTAssertNil(host.activeEquipment)
        XCTAssertEqual(EquipmentSectionModel(host: host).state, .unset(choices: [
            .init(name: "SLP99UH070XV36BK",
                  heading: "SLP99UH070XV36BK (070XV36B, SLP99UHXV-070-36B; size code A)",
                  file: "models.md", isActive: false),
            .init(name: "SLP99UH090XV60CK",
                  heading: "SLP99UH090XV60CK (090XV60C, -090-060C, SLP99UHXV-090-60C; size code d)",
                  file: "models.md", isActive: false)
        ]))
    }

    // MARK: - The line on the lens

    func testHUDLineNamesTheModelAndTheVault() {
        XCTAssertEqual(EquipmentHUDCue.line(for: identity(), vaultName: Self.vaultName),
                       "SLP99UH090XV60CK · Lennox SLP99 Furnace Service")
        XCTAssertEqual(EquipmentHUDCue.line(for: identity(), vaultName: nil), "SLP99UH090XV60CK")
        XCTAssertEqual(EquipmentHUDCue.line(for: nil, vaultName: Self.vaultName),
                       "No equipment set · Lennox SLP99 Furnace Service")
        XCTAssertEqual(EquipmentHUDCue.line(for: nil, vaultName: ""), "No equipment set")
    }

    // MARK: - The exported record

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EquipmentSurfaceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    /// Run a session to completion, optionally standing at a machine, and return its directory.
    private func runSession(equipment: EquipmentIdentity?) throws -> URL {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let session = try service.startSession(vaultId: "refrigeration", assetId: "Unit 47B")
        if let equipment { service.setEquipment(equipment) }
        service.logUserMessage("what is the manifold pressure on high fire")
        _ = try service.endSession(outcome: .resolved)
        return tempRoot.appendingPathComponent(session.id, isDirectory: true)
    }

    func testExportCarriesTheEquipmentThroughJSON() throws {
        let dir = try runSession(equipment: identity())
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        let equipment = try XCTUnwrap(export.equipment)
        XCTAssertEqual(equipment.model, "SLP99UH090XV60CK")
        XCTAssertEqual(equipment.source, "nameplate")
        XCTAssertEqual(equipment.recognisedAt.timeIntervalSince1970, 1_757_000_520, accuracy: 1)
        XCTAssertFalse(equipment.heading.isEmpty)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try encoder.encode(export)
        XCTAssertTrue(try XCTUnwrap(String(data: raw, encoding: .utf8)).contains("\"recognised_at\""))
        XCTAssertEqual(try decoder.decode(SessionExport.self, from: raw), export)

        // The plate's own text is audit material in the event log; the work order names the machine.
        XCTAssertFalse(try XCTUnwrap(String(data: raw, encoding: .utf8)).contains("SER 5820A12345"))
    }

    func testExportWithoutEquipmentSaysNothingAboutIt() throws {
        let dir = try runSession(equipment: nil)
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        XCTAssertNil(export.equipment)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = try encoder.encode(export)
        XCTAssertEqual(try decoder.decode(SessionExport.self, from: raw), export)
        XCTAssertFalse(SessionExporter.summaryLines(export).contains { $0.hasPrefix("Equipment:") })
    }

    /// An audit written before identity existed has no `equipment` key at all and must still read.
    func testExportDecodesRecordWrittenBeforeIdentity() throws {
        let dir = try runSession(equipment: identity())
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(export)) as? [String: Any])
        object.removeValue(forKey: "equipment")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let older = try decoder.decode(SessionExport.self,
                                       from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.equipment)
    }

    func testWorkOrderPrintsTheEquipmentSentenceFirst() throws {
        let dir = try runSession(equipment: identity())
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        let lines = SessionExporter.summaryLines(export)
        XCTAssertEqual(lines.first,
                       "Equipment: SLP99UH090XV60CK — from the nameplate at "
                       + EquipmentIdentity.clock(Date(timeIntervalSince1970: 1_757_000_520)))
        XCTAssertEqual(lines.dropFirst().first, "Asset: Unit 47B")

        let urls = try SessionExporter.export(sessionDir: dir, formats: [.pdf])
        let pdf = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(urls.first)))
        let text = (pdf.string ?? "").replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(text.contains("Equipment: SLP99UH090XV60CK"), text.prefix(400).description)
    }

    func testWorkOrderWithoutEquipmentPrintsNoSuchLine() throws {
        let dir = try runSession(equipment: nil)
        let urls = try SessionExporter.export(sessionDir: dir, formats: [.pdf])
        let pdf = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(urls.first)))
        XCTAssertFalse((pdf.string ?? "").contains("Equipment:"))
    }
}
