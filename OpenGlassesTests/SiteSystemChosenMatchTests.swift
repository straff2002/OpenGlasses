import XCTest
@testable import OpenGlasses

/// Plan MD P0 — a site the technician chose on New job is the match, confirmed with basis
/// `chosen`; a serial at the chosen site changes nothing but the unit it names, and one at another
/// documented site is kept as a question, never switched to. A remembered Workiz client matches
/// as the job's location (P2).
final class SiteSystemChosenMatchTests: XCTestCase {

    private typealias F = SiteSystemFixtures

    private let workizClient = SiteSystemDocument.ExternalRef(system: "workiz", id: "CL-1042")

    private func elmRoad() throws -> SiteSystemDocument {
        try F.decoded(F.document(id: "elm-road", name: "Elm Road boiler room",
                                 units: [F.unit("boiler", model: "NV80F060", serial: "ER-5501")],
                                 extra: ["location_label": "Elm Road"]))
    }

    private func documents() throws -> [SiteSystemDocument] {
        [try F.exampleDocument(), try elmRoad()]
    }

    private func match(_ evidence: SiteSystemEvidence,
                       clientSites: [SiteSystemDocument.ExternalRef: String] = [:]) throws -> SiteSystemMatch? {
        SiteSystemMatcher.match(evidence: evidence, documents: try documents(), vaultId: F.vaultId,
                                modelKey: try F.modelKey(), clientSites: clientSites)
    }

    // MARK: - Chosen

    func testAChosenSiteIsConfirmedWithBasisChosenAndListsItsUnits() throws {
        let m = try XCTUnwrap(try match(SiteSystemEvidence(chosenSiteID: "hillside-house")))
        XCTAssertEqual(m.strength, .confirmed)
        XCTAssertEqual(m.basis, .chosen)
        XCTAssertEqual(m.siteId, "hillside-house")
        XCTAssertEqual(m.siteLabel, "Hillside house")
        XCTAssertEqual(m.units.count, 3)
        XCTAssertEqual(m.matchedUnitIDs, [])
        XCTAssertNil(m.conflict)
    }

    func testASerialAtTheChosenSiteChangesNothingButTheUnitItNames() throws {
        let m = try XCTUnwrap(try match(SiteSystemEvidence(serials: ["af80 2201"], chosenSiteID: "hillside-house")))
        XCTAssertEqual(m.siteId, "hillside-house")
        XCTAssertEqual(m.basis, .chosen)
        XCTAssertEqual(m.matchedUnitIDs, ["furnace"])
        XCTAssertNil(m.conflict)
    }

    func testASerialAtAnotherDocumentedSiteIsAQuestionNotASwitch() throws {
        let m = try XCTUnwrap(try match(SiteSystemEvidence(serials: ["ER-5501"], chosenSiteID: "hillside-house")))
        XCTAssertEqual(m.siteId, "hillside-house", "a chosen site is never switched silently")
        XCTAssertEqual(m.strength, .confirmed)
        XCTAssertEqual(m.conflict, SiteSystemMatch.Conflict(siteId: "elm-road", siteLabel: "Elm Road", basis: .serial))
        XCTAssertEqual(SiteSystemContract.conflictQuestion(m),
                       "That serial is listed at Elm Road, not Hillside house — which is it?")
    }

    func testWithoutAChoiceTheSameSerialStillNamesItsOwnSite() throws {
        let m = try XCTUnwrap(try match(SiteSystemEvidence(serials: ["ER-5501"])))
        XCTAssertEqual(m.siteId, "elm-road")
        XCTAssertEqual(m.basis, .serial)
        XCTAssertNil(m.conflict)
    }

    func testAChosenSiteNoLongerInTheVaultFallsBackToTheEvidence() throws {
        let m = try XCTUnwrap(try match(SiteSystemEvidence(serials: ["AF80-2201"], chosenSiteID: "demolished")))
        XCTAssertEqual(m.siteId, "hillside-house")
        XCTAssertEqual(m.basis, .serial)
    }

    // MARK: - Remembered clients (P2)

    func testARememberedClientMatchesAsTheJobsLocation() throws {
        let m = try XCTUnwrap(try match(SiteSystemEvidence(customer: workizClient),
                                        clientSites: [workizClient: "elm-road"]))
        XCTAssertEqual(m.strength, .confirmed)
        XCTAssertEqual(m.basis, .location)
        XCTAssertEqual(m.siteId, "elm-road")
    }

    func testAClientAloneIsNoEvidenceAndAnotherSystemsClientIsAnotherClient() throws {
        XCTAssertTrue(SiteSystemEvidence(customer: workizClient).isEmpty)
        XCTAssertNil(try match(SiteSystemEvidence(customer: workizClient)))
        let other = SiteSystemDocument.ExternalRef(system: "example-fsm", id: "CL-1042")
        XCTAssertNil(try match(SiteSystemEvidence(customer: other), clientSites: [workizClient: "elm-road"]))
    }

    func testAWorkizJobsEvidenceCarriesItsClient() {
        let external = ExternalJobReference(system: "workiz", systemName: "Workiz", jobID: "J-77", jobNumber: "1240",
                                            appointmentID: nil, locationID: nil, customerID: "CL-1042",
                                            technicianID: nil, equipmentIDs: nil)
        let evidence = SiteSystemEvidence(equipment: [], external: external)
        XCTAssertEqual(evidence.customer, workizClient)
        XCTAssertNil(evidence.location)
    }

    func testMergingKeepsTheChoiceAndTheClientAndALaterChoiceWins() {
        let kept = SiteSystemEvidence(chosenSiteID: "hillside-house", customer: workizClient)
        let merged = kept.merged(with: SiteSystemEvidence(serials: ["AF80-2201"]))
        XCTAssertEqual(merged.chosenSiteID, "hillside-house")
        XCTAssertEqual(merged.customer, workizClient)
        XCTAssertEqual(merged.serials, ["AF802201"])
        XCTAssertEqual(merged.merged(with: SiteSystemEvidence(chosenSiteID: "elm-road")).chosenSiteID, "elm-road")
    }

    // MARK: - Old data

    func testAMatchSavedBeforeChoicesStillDecodes() throws {
        let json = #"""
        {"vault_id":"v","strength":"confirmed","site_id":"hillside-house","site_name":"Hillside","site_label":"Hillside",
         "basis":"serial","units":[{"id":"furnace","name":"basement furnace","model":"NV80F060"}],
         "matched_unit_ids":["furnace"],"candidate_count":1,
         "evidence":{"serials":["AF802201"],"models":[],"equipment_ids":[]}}
        """#
        let match = try JSONDecoder().decode(SiteSystemMatch.self, from: Data(json.utf8))
        XCTAssertEqual(match.basis, .serial)
        XCTAssertNil(match.conflict)
        XCTAssertNil(match.evidence.chosenSiteID)
        XCTAssertNil(match.evidence.customer)
        // An evidence block missing its lists, as a hand-trimmed file might be, still loads.
        let bare = try JSONDecoder().decode(SiteSystemEvidence.self, from: Data(#"{"location":null}"#.utf8))
        XCTAssertTrue(bare.isEmpty)
    }

    func testAChosenMatchWithAConflictRoundTrips() throws {
        let m = try XCTUnwrap(try match(SiteSystemEvidence(serials: ["ER-5501"], chosenSiteID: "hillside-house",
                                                           customer: workizClient)))
        let data = try JSONEncoder().encode(m)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""basis":"chosen""#), text)
        XCTAssertTrue(text.contains(#""chosen_site_id":"hillside-house""#), text)
        XCTAssertEqual(try JSONDecoder().decode(SiteSystemMatch.self, from: data), m)
    }

    // MARK: - What is said

    func testTheBlockSaysTheSiteWasChosenAndCarriesTheConflict() throws {
        let chosen = try XCTUnwrap(try match(SiteSystemEvidence(chosenSiteID: "hillside-house")))
        let lines = SiteSystemContract.lines(match: chosen, document: try F.exampleDocument(), vaultId: F.vaultId)
        XCTAssertEqual(lines.first, #"SITE SYSTEM: "Hillside house, whole-home system" — chosen by the technician on site"#)
        XCTAssertFalse(lines.contains { $0.hasPrefix("SITE CONFLICT:") })
        XCTAssertNil(SiteSystemContract.conflictQuestion(chosen))

        let disputed = try XCTUnwrap(try match(SiteSystemEvidence(serials: ["ER-5501"], chosenSiteID: "hillside-house")))
        let withConflict = SiteSystemContract.lines(match: disputed, document: try F.exampleDocument(), vaultId: F.vaultId)
        XCTAssertTrue(withConflict.contains { $0.hasPrefix(#"SITE CONFLICT: A serial on this job names "Elm Road""#) },
                      withConflict.joined(separator: "\n"))
        let live = try XCTUnwrap(SiteSystemContract.liveLine(disputed, vaultId: F.vaultId))
        XCTAssertTrue(live.contains("(chosen by the technician)"), live)
        XCTAssertTrue(live.contains("SITE CONFLICT:"), live)
    }
}
