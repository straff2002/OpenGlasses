import XCTest
@testable import OpenGlasses

/// Plan GB P2 — equipment is recorded as the technician stated it, and a job on two machines is
/// recorded as two.
///
/// The index is the real example vault's core (`examples/vaults/lennox-slp99`), because job 1011's
/// model numbers are only interesting against its actual headings.
@MainActor
final class EquipmentUnitsTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var installedId: String?

    private static var exampleDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/vaults/lennox-slp99", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EquipmentUnitsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        if let installedId { VaultImporter.uninstall(id: installedId) }
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func lennoxIndex() throws -> VaultModelIndex {
        let dir = Self.exampleDirectory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("example vault not found at \(dir.path)")
        }
        let manifest = try JSONDecoder().decode(
            VaultManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        let files = try manifest.files.map {
            (filename: $0, contents: try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
        return VaultModelIndex(vaultName: manifest.name, files: files)
    }

    /// The example vault's core, installed and started — manuals dropped, identity is core-only.
    private func startLennoxSession() throws -> FieldSessionService {
        let source = Self.exampleDirectory
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("example vault not found at \(source.path)")
        }
        let copy = tempRoot.appendingPathComponent("lennox", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: copy)
        let manifest = try JSONDecoder().decode(
            VaultManifest.self, from: Data(contentsOf: copy.appendingPathComponent("manifest.json")))
        let coreOnly = VaultManifest(id: manifest.id, name: manifest.name, version: manifest.version,
                                     files: manifest.files, proceduresDir: manifest.proceduresDir,
                                     documentsDir: nil, documents: [], gating: manifest.gating,
                                     promptRules: manifest.promptRules,
                                     sourceAttributionFormat: manifest.sourceAttributionFormat,
                                     sourceAttributionRequired: manifest.sourceAttributionRequired)
        try JSONEncoder().encode(coreOnly).write(to: copy.appendingPathComponent("manifest.json"))
        let installed = try VaultImporter.install(from: copy)
        installedId = installed.id
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        _ = try service.startSession(vaultId: installed.id, assetId: nil, jobReference: "1011")
        return service
    }

    // MARK: - Recognition

    func testJob1011sModelNumbersResolveAsTheyShould() throws {
        let index = try lennoxIndex()
        XCTAssertEqual(EquipmentRecognition.resolve(stated: "SLP99UH070XB36B", index: index), .unmatched,
                       "XB is not XV: a changed letter is another product, not a slip")
        guard case .near(let model, _, let distance) = EquipmentRecognition.resolve(stated: "SLP99UH090XV48C",
                                                                                      index: index) else {
            return XCTFail("…48C is one letter short of …48CK")
        }
        XCTAssertEqual(model.name, "SLP99UH090XV48CK")
        XCTAssertEqual(distance, 1)
        XCTAssertEqual(EquipmentRecognition.resolve(stated: "SLP99UH090XV48CK", index: index).kind, .exact)
        XCTAssertEqual(EquipmentRecognition.resolve(stated: "090XV48C", index: index).kind, .alias)
        XCTAssertEqual(EquipmentRecognition.resolve(stated: "slp99uh-090xv48ck", index: index).kind, .exact,
                       "spelling-insensitive")
        XCTAssertEqual(EquipmentRecognition.resolve(stated: "070", index: index), .unmatched,
                       "a fragment is never fuzzily matched")
    }

    func testEditDistanceCountsInsertionsAndDeletions() {
        XCTAssertEqual(EquipmentRecognition.distance("ABC", "ABCK"), 1)
        XCTAssertEqual(EquipmentRecognition.distance("AXB", "AVB"), 2, "a substitution costs two")
        XCTAssertEqual(EquipmentRecognition.distance("", "AB"), 2)
    }

    // MARK: - The 1011 sequence, through the tools

    func testJob1011RecordsTwoUnitsAsStatedWithTheirVaultSectionsAndTheirOwnWork() async throws {
        let service = try startLennoxSession()
        let lookup = EquipmentLookupTool(sessionService: service)
        let tasks = TaskTool(sessionService: service)

        // The first furnace: not in the vault, stated by the technician.
        let first = try await lookup.execute(args: ["set_equipment": "SLP99UH070XB36B"])
        XCTAssertTrue(first.contains("not a model the loaded manuals cover"), first)
        XCTAssertEqual(service.equipmentScope(turn: "what is the rise on the SLP99UH070XB36B"), .inScope,
                       "a unit the technician named is never 'not one of them'")
        _ = try await tasks.execute(args: ["verb": "add", "title": "Checked the filter"])
        _ = try await tasks.execute(args: ["verb": "done"])

        // The second: the next unit on the same job, said one letter short of the vault's heading.
        _ = try await FieldSessionTool(service: service).execute(args: ["action": "next_unit"])
        let second = try await lookup.execute(args: ["set_equipment": "SLP99UH090XV48C"])
        XCTAssertTrue(second.contains("Did you mean SLP99UH090XV48CK?"), second)
        let recognisedAt = try XCTUnwrap(service.activeEquipment?.recognisedAt)
        _ = try await tasks.execute(args: ["verb": "add", "title": "Adjusted blower speed"])
        _ = try await tasks.execute(args: ["verb": "done"])

        // The technician says no, it really is the 48C: restated, same unit, same first-seen time.
        _ = try await lookup.execute(args: ["set_equipment": "SLP99UH090XV48C"])
        XCTAssertEqual(service.activeEquipment?.stated, "SLP99UH090XV48C")
        XCTAssertEqual(service.activeEquipment?.recognisedAt, recognisedAt,
                       "recognised at is when the unit was identified, not when it was restated")

        let ledger = service.unitLedger
        XCTAssertEqual(ledger.units.count, 2)
        XCTAssertEqual(ledger.units.map(\.label), ["SLP99UH070XB36B (not in the vault)",
                                                   "SLP99UH090XV48C (vault section SLP99UH090XV48CK)"])
        let record = try XCTUnwrap(service.workRecord())
        let titles = { (unit: UnitLedger.Unit) in
            record.tasks.filter { unit.taskIds.contains($0.id) }.map(\.title)
        }
        XCTAssertEqual(titles(ledger.units[0]), ["Checked the filter"])
        XCTAssertEqual(titles(ledger.units[1]), ["Adjusted blower speed"])

        let lines = record.summaryLines
        XCTAssertTrue(lines.contains("Units on this job: 2."), lines.description)
        XCTAssertTrue(lines.contains("Unit 1: SLP99UH070XB36B (not in the vault)."), lines.description)
        XCTAssertTrue(lines.contains("Unit 2: SLP99UH090XV48C (vault section SLP99UH090XV48CK)."),
                      lines.description)
        XCTAssertTrue(record.jsonString.contains("\"units\""))
        XCTAssertEqual(record.equipment?.model, "SLP99UH090XV48C", "the record keeps what was said")

        let log = try String(contentsOf: tempRoot.appendingPathComponent("sessions")
            .appendingPathComponent(try XCTUnwrap(service.activeSession?.id))
            .appendingPathComponent("log.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("equipment_corrected"), log)
        XCTAssertTrue(log.contains("unit_started"), log)
    }

    func testASpokenSerialReachesTheIdentityFields() async throws {
        let service = try startLennoxSession()
        let reply = try await EquipmentLookupTool(sessionService: service)
            .execute(args: ["serial": "5820A12345"])
        XCTAssertTrue(reply.contains("Serial: 5820A12345 (from the technician)"), reply)
        XCTAssertEqual(service.activeSession?.identityFields.map(\.value), ["5820A12345"])
    }

    // MARK: - Earlier work and the first identification (Plan GD2)

    /// Job 1011's shape: two tasks recorded before anyone read the nameplate, then the first
    /// identification. The work is attached to that unit and the reply says so; "that was a
    /// different unit" then puts it on an unidentified unit of its own.
    func testAFirstIdentificationAfterWorkSaysSoAndSeparatingKeepsTheWorkApart() async throws {
        let service = try startLennoxSession()
        let lookup = EquipmentLookupTool(sessionService: service)
        let tasks = TaskTool(sessionService: service)
        _ = try await tasks.execute(args: ["verb": "add", "title": "Checked the filter"])
        _ = try await tasks.execute(args: ["verb": "done"])
        _ = try await tasks.execute(args: ["verb": "add", "title": "Checked the flue"])
        _ = try await tasks.execute(args: ["verb": "done"])

        let identified = try await lookup.execute(args: ["set_equipment": "SLP99UH090XV48C"])
        XCTAssertTrue(identified.contains(FieldSessionTool.earlierWorkSentence), identified)
        XCTAssertTrue(service.earlierWorkAttached)
        XCTAssertEqual(service.unitLedger.units.count, 1, "attached, not guessed apart")

        // Said again, it is not a first identification: no second sentence.
        let restated = try await lookup.execute(args: ["set_equipment": "SLP99UH090XV48C"])
        XCTAssertFalse(restated.contains(FieldSessionTool.earlierWorkSentence), restated)

        // Work recorded on the identified machine before the technician speaks up moves with it.
        _ = try await tasks.execute(args: ["verb": "add", "title": "Adjusted blower speed"])

        let reply = try await FieldSessionTool(service: service).execute(args: ["action": "separate_earlier_work"])
        XCTAssertTrue(reply.contains("Separated the earlier work"), reply)
        XCTAssertFalse(service.earlierWorkAttached)
        XCTAssertEqual(service.activeEquipment?.stated, "SLP99UH090XV48C", "the identity stays")

        let ledger = service.unitLedger
        XCTAssertEqual(ledger.units.map(\.label), ["Unidentified unit",
                                                   "SLP99UH090XV48C (vault section SLP99UH090XV48CK)"])
        let record = try XCTUnwrap(service.workRecord())
        let titles = { (unit: UnitLedger.Unit) in
            record.tasks.filter { unit.taskIds.contains($0.id) }.map(\.title)
        }
        XCTAssertEqual(titles(ledger.units[0]), ["Checked the filter", "Checked the flue"])
        XCTAssertEqual(titles(ledger.units[1]), ["Adjusted blower speed"])
        XCTAssertTrue(record.summaryLines.contains("Unit 1: Unidentified unit."), record.summaryLines.description)
        XCTAssertTrue(record.summaryLines.contains("Unit 2: SLP99UH090XV48C (vault section SLP99UH090XV48CK)."),
                      record.summaryLines.description)

        let log = try String(contentsOf: tempRoot.appendingPathComponent("sessions")
            .appendingPathComponent(try XCTUnwrap(service.activeSession?.id))
            .appendingPathComponent("log.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("unit_split"), log)

        // Once is all: there is nothing left to separate.
        let again = try await FieldSessionTool(service: service).execute(args: ["action": "separate_earlier_work"])
        XCTAssertTrue(again.contains("nothing was separated"), again)
    }

    func testAFirstIdentificationWithNoEarlierWorkSetsNothing() async throws {
        let service = try startLennoxSession()
        let reply = try await EquipmentLookupTool(sessionService: service)
            .execute(args: ["set_equipment": "SLP99UH090XV48CK"])
        XCTAssertFalse(reply.contains(FieldSessionTool.earlierWorkSentence), reply)
        XCTAssertFalse(service.earlierWorkAttached)
        XCTAssertNil(service.activeSession?.earlierWorkAttachedAt)
        XCTAssertFalse(service.separateEarlierWork())
    }

    func testNextUnitClearsTheEarlierWorkMarker() async throws {
        let service = try startLennoxSession()
        _ = try await TaskTool(sessionService: service).execute(args: ["verb": "add", "title": "Checked the filter"])
        _ = try await EquipmentLookupTool(sessionService: service).execute(args: ["set_equipment": "SLP99UH090XV48CK"])
        XCTAssertTrue(service.earlierWorkAttached)
        _ = try await FieldSessionTool(service: service).execute(args: ["action": "next_unit"])
        XCTAssertFalse(service.earlierWorkAttached)
        XCTAssertFalse(service.separateEarlierWork(), "next_unit answered the question")
    }

    func testTheEarlierWorkMarkerRoundTripsAndALegacySessionDecodesWithoutIt() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacy = singleUnitSession()
        let legacyJSON = try encoder.encode(legacy)
        XCTAssertFalse(String(decoding: legacyJSON, as: UTF8.self).contains("earlierWorkAttachedAt"),
                       "an unset marker writes no key, so a session reads as it did")
        XCTAssertNil(try decoder.decode(FieldSession.self, from: legacyJSON).earlierWorkAttachedAt)

        var marked = legacy
        marked.earlierWorkAttachedAt = Date(timeIntervalSince1970: 1_790_000_100)
        let reloaded = try decoder.decode(FieldSession.self, from: encoder.encode(marked))
        XCTAssertEqual(reloaded.earlierWorkAttachedAt, marked.earlierWorkAttachedAt)
    }

    // MARK: - One unit prints as it always did

    private func singleUnitSession(statedModel: String? = nil) -> FieldSession {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        var session = FieldSession(
            id: "s1", vaultId: "lennox_slp99", assetId: nil, mode: .aiOnly, startedAt: started,
            endedAt: started.addingTimeInterval(600), outcome: .resolved, escalations: [],
            billableSeconds: 600, jobReference: "1010",
            tasks: [.init(id: "t1", title: "Checked the filter", origin: .operatorAdded, status: .done,
                          createdAt: started)])
        let identity = EquipmentIdentity(modelToken: "SLP99UH090XV60CK", heading: "SLP99UH090XV60CK (090XV60C)",
                                         file: "models.md", source: .nameplate, recognisedAt: started,
                                         statedModel: statedModel)
        session.equipment = identity
        session.visitedUnits = [VisitedUnit(identity: identity, continuityScope: "initial", firstSeenAt: started)]
        return session
    }

    func testASingleUnitJobIsByteForByteWhatItWas() throws {
        let record = WorkRecord(session: singleUnitSession(), vaultName: "Lennox SLP99")
        XCTAssertNil(record.units)
        XCTAssertFalse(record.jsonString.contains("\"units\""))
        XCTAssertFalse(record.jsonString.contains("vaultSection"))
        XCTAssertEqual(record.summaryLines[1], "Equipment: SLP99UH090XV60CK (from the nameplate).")
        XCTAssertFalse(record.summaryLines.contains { $0.hasPrefix("Unit ") })
    }

    func testALegacyIdentityAndRecordDecodeUnchanged() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyIdentity = #"{"modelToken":"SLP99UH090XV60CK","heading":"H","file":"models.md","source":"spoken","recognisedAt":"2026-01-02T03:04:05Z"}"#
        let identity = try decoder.decode(EquipmentIdentity.self, from: Data(legacyIdentity.utf8))
        XCTAssertNil(identity.statedModel)
        XCTAssertEqual(identity.stated, "SLP99UH090XV60CK", "a legacy identity reads its model as stated")
        XCTAssertFalse(identity.isOutOfVault)

        let legacyUnit = #"{"modelToken":"M","heading":"H","firstSeenAt":"2026-01-02T03:04:05Z","continuityScope":"initial"}"#
        let unit = try decoder.decode(VisitedUnit.self, from: Data(legacyUnit.utf8))
        XCTAssertEqual(unit.stated, "M")

        // A record written before units existed decodes with none, and re-encodes without the key.
        let record = WorkRecord(session: singleUnitSession(), vaultName: "Lennox SLP99")
        let reloaded = try decoder.decode(WorkRecord.self, from: record.json)
        XCTAssertEqual(reloaded, record)
    }

    func testTheSignOffDigestIsUntouchedByUnits() {
        var session = singleUnitSession()
        let single = WorkRecord(session: session, vaultName: "Lennox SLP99").customerSummaryLines
        // A second unit and its work change the record, not what the customer is asked to sign
        // beyond the work itself.
        let other = EquipmentIdentity(modelToken: "X1", heading: "X1", file: "", source: .spoken,
                                      statedModel: "X1", vaultMatch: nil)
        session.visitedUnits.append(VisitedUnit(identity: other, continuityScope: "second"))
        let multi = WorkRecord(session: session, vaultName: "Lennox SLP99")
        XCTAssertNotNil(multi.units)
        XCTAssertEqual(multi.customerSummaryLines, single)
    }
}
