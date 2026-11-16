import XCTest
@testable import OpenGlasses

/// Plan MD P0–P2 through an installed vault and a real session: a site chosen on New job is the
/// job's match and is logged as ids and counts; a serial at another documented site is asked about
/// once and never switched to; today's job starts as that job ahead; a Workiz client's chosen site
/// is remembered and matches its next job.
@MainActor
final class ChosenSiteSessionTests: XCTestCase {

    private typealias F = SiteSystemFixtures
    private var root: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private let vaultId = "site_chosen_test"
    private let client = SiteSystemDocument.ExternalRef(system: "workiz", id: "CL-1042")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChosenSiteSessionTests-\(UUID().uuidString)", isDirectory: true)
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

    /// The fixture vault with a second documented site, Elm Road, whose boiler has its own serial.
    private func installVault() throws {
        let elm = F.document(id: "elm-road", name: "Elm Road boiler room",
                             units: [F.unit("boiler", model: "NV80F060", serial: "ER-5501")],
                             extra: ["location_label": "Elm Road"])
        try VaultImporter.install(from: F.copyVault(to: root, id: vaultId, sites: [
            F.siteFile: try F.exampleObject(), "sites/elm-road.json": elm,
        ]))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
    }

    private func makeService() throws -> FieldSessionService {
        try installVault()
        let service = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        service.clientSiteLinks = ClientSiteLinkStore(directory: root.appendingPathComponent("links", isDirectory: true))
        return service
    }

    private func startSession() throws -> FieldSessionService {
        let service = try makeService()
        _ = try service.startSession(vaultId: vaultId, assetId: nil, jobReference: "1007")
        return service
    }

    private func events(_ service: FieldSessionService) throws -> [SessionLogger.Event] {
        let id = try XCTUnwrap(service.activeSession?.id)
        return SessionLogger.readEvents(at: root.appendingPathComponent("sessions").appendingPathComponent(id, isDirectory: true))
    }

    private func workizJob() -> UpcomingJob {
        let external = ExternalJobReference(system: "workiz", systemName: "Workiz", jobID: "J-77", jobNumber: "1240",
                                            appointmentID: nil, locationID: nil, customerID: client.id,
                                            technicianID: nil, equipmentIDs: nil)
        return UpcomingJob(id: "workiz:J-77", jobReference: "1240",
                           site: JobSite(customer: "Smith & Co", address: "14 Smith St"),
                           scheduledFor: Date(), origin: .connector,
                           provenance: JobFileProvenance(fileName: "Workiz", signature: .unsigned, signer: nil,
                                                         digest: "", external: external, connector: "workiz"))
    }

    // MARK: - A chosen site

    func testAChosenSiteIsTheJobsMatchAndIsLoggedAsIdsOnly() throws {
        let service = try startSession()
        service.applyChosenSite(site: JobSite(customer: "Smith & Co", address: "14 Smith St"),
                                siteDocumentId: "hillside-house", source: "documented_site")
        let match = try XCTUnwrap(service.activeSession?.siteSystem)
        XCTAssertEqual(match.strength, .confirmed)
        XCTAssertEqual(match.basis, .chosen)
        XCTAssertEqual(match.siteId, "hillside-house")
        XCTAssertEqual(service.activeSession?.site, JobSite(customer: "Smith & Co", address: "14 Smith St"))
        XCTAssertTrue(try XCTUnwrap(service.continuityContext()).contains("chosen by the technician on site"))

        let chosen = try XCTUnwrap(try events(service).first { $0.kind == .siteChosen })
        XCTAssertEqual(chosen.payload?["site_id"]?.value as? String, "hillside-house")
        XCTAssertEqual(chosen.payload?["units"]?.value as? Int, 3)
        let text = try events(service).map { "\($0.text ?? "") \($0.payload.map { "\($0)" } ?? "")" }.joined()
        XCTAssertFalse(text.contains("Smith"), "no customer text reaches the log")
        XCTAssertFalse(text.contains("Hillside house"), "no site text reaches the log")
    }

    func testASerialAtTheChosenSiteKeepsItAndNamesTheUnit() throws {
        let service = try startSession()
        service.applyChosenSite(site: nil, siteDocumentId: "hillside-house", source: "documented_site")
        _ = service.recordIdentityField(name: "Serial", value: "AF80 2201", source: .spoken)
        let match = try XCTUnwrap(service.activeSession?.siteSystem)
        XCTAssertEqual(match.siteId, "hillside-house")
        XCTAssertEqual(match.basis, .chosen)
        XCTAssertEqual(match.matchedUnitIDs, ["furnace"])
        XCTAssertNil(match.conflict)
        XCTAssertNil(service.siteSystemConflictQuestion())
    }

    func testASerialAtAnotherSiteIsAskedAboutOnceAndNeverSwitched() async throws {
        let service = try startSession()
        service.applyChosenSite(site: nil, siteDocumentId: "hillside-house", source: "documented_site")
        let lookup = EquipmentLookupTool(sessionService: service)

        let first = try await lookup.execute(args: ["serial": "ER-5501"])
        XCTAssertTrue(first.contains("That serial is listed at Elm Road, not Hillside house — which is it?"), first)
        XCTAssertEqual(service.activeSession?.siteSystem?.siteId, "hillside-house")
        XCTAssertEqual(service.activeSession?.siteSystem?.conflict?.siteId, "elm-road")
        XCTAssertTrue(try XCTUnwrap(service.continuityContext()).contains("SITE CONFLICT:"))

        let again = try await lookup.execute(args: ["serial": "ER-5501"])
        XCTAssertFalse(again.contains("which is it?"), "asked once: \(again)")
        XCTAssertEqual(try events(service).filter { $0.kind == .siteSystemConflictRaised }.count, 1)
    }

    func testAJobAlreadyFiledUnderASiteKeepsIt() throws {
        let service = try startSession()
        service.applyJobAhead(workizJob())
        service.applyChosenSite(site: JobSite(customer: "Someone else"), siteDocumentId: nil, source: "recent_site")
        XCTAssertEqual(service.activeSession?.site?.customer, "Smith & Co")
    }

    // MARK: - Remembered Workiz clients (P2)

    func testChoosingASiteForAWorkizJobRemembersItAndTheNextJobMatches() throws {
        let service = try startSession()
        service.applyJobAhead(workizJob())
        XCTAssertNotEqual(service.activeSession?.siteSystem?.strength, .confirmed, "Workiz names no location")
        service.applyChosenSite(site: nil, siteDocumentId: "elm-road", source: "scheduled_job", rememberClient: client)
        let links = try XCTUnwrap(service.clientSiteLinks)
        XCTAssertEqual(links.siteIDs(vaultId: vaultId), [client: "elm-road"])
        XCTAssertEqual(links.links.first?.siteLabel, "Elm Road")
        _ = try service.endSession(outcome: .resolved)

        // The client's next job matches as its location, with nothing chosen.
        _ = try service.startSession(vaultId: vaultId, assetId: nil, jobReference: "1241")
        service.applyJobAhead(workizJob())
        let match = try XCTUnwrap(service.activeSession?.siteSystem)
        XCTAssertEqual(match.strength, .confirmed)
        XCTAssertEqual(match.basis, .location)
        XCTAssertEqual(match.siteId, "elm-road")
    }

    // MARK: - Starting from New job

    private func makeModel(_ service: FieldSessionService, flow: RecordingJobFlow) -> JobTabModel {
        JobTabModel(host: service, flow: flow, defaults: .init(
            vaultId: { [vaultId] in vaultId },
            mode: { .aiOnly },
            vaultName: { _ in "Site test" },
            vaultUnlocked: { _ in true },
            siteDocuments: { id in VaultRegistry.shared.store(forId: id)?.siteDocuments() ?? [] },
            clientSites: { _ in [:] }))
    }

    func testADocumentedSiteStartsAnOrdinaryJobMatchedAsChosen() throws {
        let service = try makeService()
        let store = ConversationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let flow = RecordingJobFlow(GuidedJobFlow(sessions: service, store: store))
        let model = makeModel(service, flow: flow)
        let hillside = try XCTUnwrap(model.siteChoices(upcoming: []).first { $0.siteDocumentId == "hillside-house" })

        let session = try model.startJob(jobReference: "1007", site: NewJobSitePick(hillside))
        XCTAssertEqual(flow.startCount, 1)
        XCTAssertEqual(session.jobReference, "1007")
        XCTAssertEqual(session.siteSystem?.basis, .chosen)
        XCTAssertEqual(session.siteSystem?.siteId, "hillside-house")
    }

    func testTodaysJobStartsAsThatJobAhead() throws {
        let service = try makeService()
        let store = ConversationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let inner = GuidedJobFlow(sessions: service, store: store)
        let upcoming = UpcomingJobStore(directory: root.appendingPathComponent("upcoming", isDirectory: true))
        inner.connectUpcoming(upcoming)
        upcoming.add(workizJob())
        let flow = RecordingJobFlow(inner)
        let model = makeModel(service, flow: flow)
        let today = try XCTUnwrap(model.siteChoices(upcoming: upcoming.jobs).first { $0.source == .scheduledJob })

        let session = try model.startJob(jobReference: "1240", site: NewJobSitePick(today))
        XCTAssertEqual(flow.startCount, 1)
        XCTAssertEqual(session.jobReference, "1240")
        XCTAssertEqual(session.site?.customer, "Smith & Co")
        XCTAssertNil(upcoming.job(id: "workiz:J-77"), "the job ahead is the job now")
    }

    func testNoSiteStartsAJobExactlyAsBefore() throws {
        let service = try makeService()
        let store = ConversationStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let flow = RecordingJobFlow(GuidedJobFlow(sessions: service, store: store))
        let session = try makeModel(service, flow: flow).startJob(jobReference: "1007", site: nil)
        XCTAssertEqual(flow.startCount, 1)
        XCTAssertNil(session.site)
        XCTAssertNil(session.siteSystem)
        XCTAssertFalse(try events(service).contains { $0.kind == .siteChosen })
    }
}
