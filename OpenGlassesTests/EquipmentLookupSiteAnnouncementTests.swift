import XCTest
@testable import OpenGlasses

/// Plan HV P1–P2 through an installed vault and a real session: the job ahead's match is copied
/// to the visit and logged, a serial heard mid-job upgrades it, the block reaches the model's
/// context, `equipment_lookup` answers "site system", and recording a unit the site lists says
/// so once per unit per job.
@MainActor
final class EquipmentLookupSiteAnnouncementTests: XCTestCase {

    private typealias F = SiteSystemFixtures
    private var root: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private let vaultId = "site_session_test"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EquipmentLookupSiteAnnouncementTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func startSession() throws -> FieldSessionService {
        try VaultImporter.install(from: F.copyVault(to: root, id: vaultId))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let service = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        _ = try service.startSession(vaultId: vaultId, assetId: nil, jobReference: "1007")
        return service
    }

    private func events(_ service: FieldSessionService) throws -> [SessionLogger.Event] {
        let id = try XCTUnwrap(service.activeSession?.id)
        return SessionLogger.readEvents(at: root.appendingPathComponent("sessions").appendingPathComponent(id, isDirectory: true))
    }

    private func job(equipment: [KnownEquipment], match: SiteSystemMatch? = nil) -> UpcomingJob {
        var job = UpcomingJob(jobReference: "1007", equipment: equipment, origin: .typed)
        job.siteSystem = match
        return job
    }

    // MARK: - The match on the visit

    func testTheJobAheadsMatchIsCopiedToTheVisitAndLogged() throws {
        let service = try startSession()
        service.applyJobAhead(job(equipment: [KnownEquipment(model: "NV80F060", serial: "AF80-2201")]))
        let match = try XCTUnwrap(service.activeSession?.siteSystem)
        XCTAssertEqual(match.strength, .confirmed)
        XCTAssertEqual(match.vaultId, vaultId)
        let logged = try events(service).filter { $0.kind == .siteSystemMatched }
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.payload?["site_id"]?.value as? String, "hillside-house")
        XCTAssertEqual(logged.first?.payload?["strength"]?.value as? String, "confirmed")
        // Identifiers only: never the site's name or any of its text.
        let text = try events(service).map { "\($0.text ?? "") \($0.payload.map { "\($0)" } ?? "")" }.joined()
        XCTAssertFalse(text.contains("Hillside house"))
        XCTAssertFalse(text.contains("basement furnace"))
    }

    func testASerialHeardMidJobUpgradesProbableToConfirmedAndLogsIt() throws {
        let service = try startSession()
        service.applyJobAhead(job(equipment: [KnownEquipment(model: "NV80F060")]))
        XCTAssertEqual(service.activeSession?.siteSystem?.strength, .probable)
        _ = service.recordIdentityField(name: "Serial", value: "AF80 2201", source: .spoken)
        XCTAssertEqual(service.activeSession?.siteSystem?.strength, .confirmed)
        XCTAssertEqual(service.activeSession?.siteSystem?.basis, .serial)
        let logged = try events(service).filter { $0.kind == .siteSystemMatched }
        XCTAssertEqual(logged.map { $0.payload?["strength"]?.value as? String }, ["probable", "confirmed"])
        XCTAssertEqual(logged.last?.payload?["previous_strength"]?.value as? String, "probable")
    }

    func testTheModelsContextCarriesTheBlockAndAJobAtNoSiteDoesNot() throws {
        let service = try startSession()
        XCTAssertFalse(try XCTUnwrap(service.continuityContext()).contains(SiteSystemContract.heading))
        service.applyJobAhead(job(equipment: [KnownEquipment(model: "NV80F060", serial: "AF80-2201")]))
        let context = try XCTUnwrap(service.continuityContext())
        XCTAssertTrue(context.contains(#"SITE SYSTEM: "Hillside house, whole-home system""#), context)
        XCTAssertTrue(context.contains("INTERACTION FAULT:"))
        // Outside the vault's core: the core prompt and its budget are untouched.
        let core = try XCTUnwrap(VaultPromptBuilder.promptContext(for: try XCTUnwrap(service.activeVault)))
        XCTAssertFalse(core.contains("Hillside house"))
    }

    // MARK: - equipment_lookup

    func testTheSiteSystemQueryReturnsTheWholeDocument() async throws {
        let service = try startSession()
        let lookup = EquipmentLookupTool(sessionService: service)
        let none = try await lookup.execute(args: ["query": "site system"])
        XCTAssertTrue(none.contains("No site system"), none)
        service.applyJobAhead(job(equipment: [KnownEquipment(model: "NV36HP2", serial: "AH36-7713")]))
        let answer = try await lookup.execute(args: ["query": "site system"])
        XCTAssertTrue(answer.hasPrefix(#"SITE SYSTEM: "Hillside house, whole-home system" — confirmed"#), answer)
        XCTAssertTrue(answer.contains("NOTES:"))
    }

    /// Plan KE P2: a unit recorded from the turn's own words has no tool reply to carry the line.
    func testAUnitSaidInTheTurnPutsTheSiteLineInItsPrompt() throws {
        let service = try startSession()
        service.applyJobAhead(job(equipment: [KnownEquipment(model: "NV80F060", serial: "AF80-2201")]))
        let said = "the NV80F060 has no heat"
        service.technicianWords = { said }
        let prompt = service.promptContext(turn: said) ?? ""
        XCTAssertTrue(prompt.contains("Part of the Hillside house system with 2 other units."), prompt)
        XCTAssertEqual(try events(service).filter { $0.kind == .siteSystemAnnounced }.count, 1)
    }

    func testRecordingAUnitTheSiteListsSaysSoOncePerUnit() async throws {
        let service = try startSession()
        service.applyJobAhead(job(equipment: [KnownEquipment(model: "NV80F060", serial: "AF80-2201")]))
        let lookup = EquipmentLookupTool(sessionService: service)

        let first = try await lookup.execute(args: ["set_equipment": "NV80F060"])
        XCTAssertTrue(first.contains("Part of the Hillside house system with 2 other units."), first)
        let again = try await lookup.execute(args: ["set_equipment": "NV80-F060"])
        XCTAssertFalse(again.contains("Part of the Hillside house system"), "once per unit per job: \(again)")

        service.startNextUnit(nil)
        let heatPump = try await lookup.execute(args: ["set_equipment": "NV36HP2"])
        XCTAssertTrue(heatPump.contains("Part of the Hillside house system with 2 other units."), "another unit says it: \(heatPump)")
        XCTAssertEqual(try events(service).filter { $0.kind == .siteSystemAnnounced }.count, 2)
    }

    func testAProbableMatchIsAnnouncedAsUnconfirmed() async throws {
        let service = try startSession()
        service.applyJobAhead(job(equipment: [KnownEquipment(model: "NV36HP2")]))
        let lookup = EquipmentLookupTool(sessionService: service)
        let reply = try await lookup.execute(args: ["set_equipment": "NV36HP2"])
        XCTAssertTrue(reply.contains("Probably part of the Hillside house system with 2 other units (matched by model only; the serial will confirm it)."), reply)
    }

    func testAUnitTheSiteDoesNotListSaysNothing() async throws {
        let service = try startSession()
        service.applyJobAhead(job(equipment: [KnownEquipment(model: "NV80F060", serial: "AF80-2201")]))
        let lookup = EquipmentLookupTool(sessionService: service)
        let reply = try await lookup.execute(args: ["set_equipment": "NV48HP2"])
        XCTAssertFalse(reply.contains("Hillside house"), reply)
    }

    func testTheLiveBlockCarriesTheLine() throws {
        let service = try startSession()
        service.applyJobAhead(job(equipment: [KnownEquipment(model: "NV80F060", serial: "AF80-2201")]))
        let block = try XCTUnwrap(LiveJobContract.block(session: service.activeSession))
        XCTAssertTrue(block.contains(#"SITE SYSTEM: "Hillside house, whole-home system", 3 units (confirmed)."#), block)
    }
}
