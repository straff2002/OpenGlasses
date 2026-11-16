import XCTest
@testable import OpenGlasses

/// Plan MD P0 — what New job's site picker offers, in the plan's order and each place once, and
/// what choosing a row does when the job starts.
final class NewJobSiteChoicesTests: XCTestCase {

    private typealias F = SiteSystemFixtures

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-17 09:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_906_000)

    private let workizClient = SiteSystemDocument.ExternalRef(system: "workiz", id: "CL-1042")

    private func elmRoad() throws -> SiteSystemDocument {
        try F.decoded(F.document(id: "elm-road", name: "Elm Road boiler room",
                                 units: [F.unit("boiler", model: "NV80F060", serial: "ER-5501")],
                                 extra: ["location_label": "Elm Road"]))
    }

    private func documents() throws -> [SiteSystemDocument] { [try F.exampleDocument(), try elmRoad()] }

    private func workizJob(id: String = "workiz:J-77", reference: String = "1240", hoursFromNow: Double = 2,
                           customer: String = "Smith & Co", address: String = "14 Smith St") -> UpcomingJob {
        let external = ExternalJobReference(system: "workiz", systemName: "Workiz", jobID: id, jobNumber: reference,
                                            appointmentID: nil, locationID: nil, customerID: workizClient.id,
                                            technicianID: nil, equipmentIDs: nil)
        return UpcomingJob(id: id, jobReference: reference, site: JobSite(customer: customer, address: address),
                           scheduledFor: now.addingTimeInterval(hoursFromNow * 3600), origin: .connector,
                           provenance: JobFileProvenance(fileName: "Workiz", signature: .unsigned, signer: nil,
                                                         receivedAt: now, digest: "", external: external,
                                                         connector: "workiz"),
                           createdAt: now)
    }

    private func inputs(upcoming: [UpcomingJob] = [], recent: [NewJobSiteChoices.RecentSite] = [],
                        clientSites: [SiteSystemDocument.ExternalRef: String] = [:]) throws -> NewJobSiteChoices.Inputs {
        var inputs = NewJobSiteChoices.Inputs(upcoming: upcoming, documents: try documents(), vaultId: F.vaultId,
                                              recent: recent, clientSites: clientSites, now: now)
        inputs.calendar = calendar
        return inputs
    }

    private func recent(_ customer: String?, _ address: String?, daysAgo: Double,
                        document: String? = nil) -> NewJobSiteChoices.RecentSite {
        .init(site: JobSite(customer: customer, address: address),
              lastVisit: now.addingTimeInterval(-daysAgo * 86_400), siteDocumentId: document)
    }

    // MARK: - Sources and order

    func testTodaysJobsComeFirstThenDocumentedSitesThenRecentSites() throws {
        let choices = NewJobSiteChoices.choices(try inputs(
            upcoming: [workizJob()], recent: [recent("Baker Ltd", "3 Baker Lane", daysAgo: 4)]))
        XCTAssertEqual(choices.map(\.source), [.scheduledJob, .documentedSite, .documentedSite, .recentSite])
        XCTAssertEqual(choices.map(\.title), ["Smith & Co, 14 Smith St", "Hillside house", "Elm Road",
                                             "Baker Ltd, 3 Baker Lane"])
        XCTAssertEqual(choices[0].upcomingJobId, "workiz:J-77")
        XCTAssertEqual(choices[0].detail, "Job 1240")
        XCTAssertEqual(choices[1].detail, "3 units")
        XCTAssertEqual(choices[2].detail, "1 unit")
    }

    func testOnlyTodaysJobsAreOffered() throws {
        var unscheduled = workizJob(id: "workiz:J-2", reference: "1241")
        unscheduled.scheduledFor = nil
        let tomorrow = workizJob(id: "workiz:J-3", reference: "1242", hoursFromNow: 26)
        let choices = NewJobSiteChoices.choices(try inputs(upcoming: [workizJob(), unscheduled, tomorrow]))
        XCTAssertEqual(choices.filter { $0.source == .scheduledJob }.map(\.jobReference), ["1240"])
    }

    func testAJobMatchedToADocumentedSiteIsShownOnceAsThatSiteWithTheCustomerBesideIt() throws {
        var job = workizJob()
        job.siteSystem = SiteSystemMatcher.match(evidence: SiteSystemEvidence(serials: ["AF80-2201"]),
                                                 documents: try documents(), vaultId: F.vaultId,
                                                 modelKey: try F.modelKey())
        let choices = NewJobSiteChoices.choices(try inputs(upcoming: [job]))
        XCTAssertEqual(choices.map(\.title), ["Hillside house", "Elm Road"])
        XCTAssertEqual(choices[0].source, .scheduledJob)
        XCTAssertEqual(choices[0].siteDocumentId, "hillside-house")
        XCTAssertTrue(choices[0].documentFromJob)
        XCTAssertEqual(choices[0].detail, "Job 1240 · Smith & Co, 14 Smith St · 3 units")
    }

    func testARememberedWorkizClientMakesTodaysJobItsSite() throws {
        let choices = NewJobSiteChoices.choices(try inputs(upcoming: [workizJob()],
                                                           clientSites: [workizClient: "elm-road"]))
        XCTAssertEqual(choices.map(\.title), ["Elm Road", "Hillside house"])
        XCTAssertEqual(choices[0].siteDocumentId, "elm-road")
        XCTAssertTrue(choices[0].documentFromJob)
    }

    func testRecentSitesAreOnePerSiteKeyNewestFirst() throws {
        let choices = NewJobSiteChoices.choices(try inputs(recent: [
            recent("Baker Ltd", "3 Baker Lane", daysAgo: 10),
            recent("Smith", "14 Smith St.", daysAgo: 9),
            recent("Smith & Co", "14 smith st", daysAgo: 2),
        ])).filter { $0.source == .recentSite }
        XCTAssertEqual(choices.map(\.title), ["Smith & Co, 14 smith st", "Baker Ltd, 3 Baker Lane"])
    }

    func testARecentSiteAlreadyOnTodaysListIsNotRepeated() throws {
        let choices = NewJobSiteChoices.choices(try inputs(
            upcoming: [workizJob()], recent: [recent("Smith & Co", "14 Smith St.", daysAgo: 3)]))
        XCTAssertEqual(choices.filter { $0.source == .recentSite }, [])
    }

    func testARecentSiteThatIsADocumentedSiteIsShownAsTheDocumentedSite() throws {
        let choices = NewJobSiteChoices.choices(try inputs(recent: [
            recent("Mrs Elm", "8 Elm Road", daysAgo: 30, document: "elm-road"),
            // A newer visit to the same address that was not matched still finds the document.
            recent("Mrs Elm", "8 Elm Road", daysAgo: 1),
        ]))
        XCTAssertEqual(choices.map(\.source), [.documentedSite, .documentedSite])
        let elm = try XCTUnwrap(choices.first { $0.siteDocumentId == "elm-road" })
        XCTAssertEqual(elm.site, JobSite(customer: "Mrs Elm", address: "8 Elm Road"))
        XCTAssertEqual(elm.detail, "Mrs Elm, 8 Elm Road · 1 unit")
    }

    func testRecentSitesAreCapped() throws {
        var many: [NewJobSiteChoices.RecentSite] = []
        for day in 1...12 { many.append(recent("Customer \(day)", "\(day) High Street", daysAgo: Double(day))) }
        var limited = try inputs(recent: many)
        limited.recentLimit = 5
        let recents = NewJobSiteChoices.choices(limited).filter { $0.source == .recentSite }
        XCTAssertEqual(recents.count, 5)
        XCTAssertEqual(recents.first?.title, "Customer 1, 1 High Street")
    }

    // MARK: - Search

    func testSearchNeedsEveryWordIgnoringCaseAndAccents() throws {
        let choices = NewJobSiteChoices.choices(try inputs(
            upcoming: [workizJob()], recent: [recent("Café Rouge", "2 Market Sq", daysAgo: 4)]))
        XCTAssertEqual(NewJobSiteChoices.filter(choices, query: "smith 1240").map(\.jobReference), ["1240"])
        XCTAssertEqual(NewJobSiteChoices.filter(choices, query: "CAFE").map(\.title), ["Café Rouge, 2 Market Sq"])
        // A documented site is found by its name as well as its label.
        XCTAssertEqual(NewJobSiteChoices.filter(choices, query: "boiler room").map(\.siteDocumentId), ["elm-road"])
        XCTAssertEqual(NewJobSiteChoices.filter(choices, query: "smith elm"), [])
        XCTAssertEqual(NewJobSiteChoices.filter(choices, query: "  "), choices)
    }

    // MARK: - What a choice does

    func testTodaysJobStartsThatJobAndBringsItsOwnSite() throws {
        var job = workizJob()
        job.siteSystem = SiteSystemMatcher.match(evidence: SiteSystemEvidence(serials: ["AF80-2201"]),
                                                 documents: try documents(), vaultId: F.vaultId,
                                                 modelKey: try F.modelKey())
        let pick = NewJobSitePick(try XCTUnwrap(NewJobSiteChoices.choices(try inputs(upcoming: [job])).first))
        XCTAssertEqual(pick.kind, .scheduledJob)
        XCTAssertEqual(pick.upcomingJobId, "workiz:J-77")
        XCTAssertEqual(pick.jobReference, "1240")
        XCTAssertEqual(pick.rowLabel, "Hillside house · 3 units")
        // The job ahead carries its site and its own match; nothing is applied over them.
        XCTAssertNil(pick.siteToFill)
        XCTAssertNil(pick.documentToChoose)
        XCTAssertFalse(pick.appliesAfterStart)
        XCTAssertFalse(pick.canRememberClient)
    }

    func testADocumentedSiteIsChosenAndARecentOneFillsTheSite() throws {
        let choices = NewJobSiteChoices.choices(try inputs(recent: [
            recent("Mrs Elm", "8 Elm Road", daysAgo: 30, document: "elm-road"),
            recent("Baker Ltd", "3 Baker Lane", daysAgo: 4),
        ]))
        let elm = NewJobSitePick(try XCTUnwrap(choices.first { $0.siteDocumentId == "elm-road" }))
        XCTAssertEqual(elm.documentToChoose, "elm-road")
        XCTAssertEqual(elm.siteToFill, JobSite(customer: "Mrs Elm", address: "8 Elm Road"))
        XCTAssertEqual(elm.rowLabel, "Elm Road · 1 unit")

        let baker = NewJobSitePick(try XCTUnwrap(choices.first { $0.source == .recentSite }))
        XCTAssertEqual(baker.kind, .recentSite)
        XCTAssertNil(baker.documentToChoose)
        XCTAssertEqual(baker.siteToFill, JobSite(customer: "Baker Ltd", address: "3 Baker Lane"))
        XCTAssertEqual(baker.rowLabel, "Baker Ltd, 3 Baker Lane")
    }

    func testAWorkizJobGivenADocumentedSiteOffersToRememberTheClient() throws {
        var pick = NewJobSitePick(try XCTUnwrap(NewJobSiteChoices.choices(try inputs(upcoming: [workizJob()])).first))
        XCTAssertTrue(pick.canAttachDocument)
        XCTAssertFalse(pick.canRememberClient, "nothing to remember until a site is chosen")

        let elm = try XCTUnwrap(NewJobSiteChoices.documentedSites(try documents()).first { $0.siteDocumentId == "elm-road" })
        pick.attach(elm)
        XCTAssertEqual(pick.documentToChoose, "elm-road")
        XCTAssertNil(pick.siteToFill, "the job ahead brings its own customer and address")
        XCTAssertEqual(pick.rowLabel, "Elm Road · 1 unit")
        XCTAssertTrue(pick.canRememberClient)
        XCTAssertEqual(pick.clientToRemember, workizClient)

        pick.remembersClient = false
        XCTAssertNil(pick.clientToRemember)
        pick.detachDocument()
        XCTAssertNil(pick.documentToChoose)
        XCTAssertFalse(pick.appliesAfterStart)
    }

    func testOnlyAWorkizClientIsOfferedToBeRemembered() throws {
        var job = workizJob()
        let external = ExternalJobReference(system: "example-fsm", systemName: nil, jobID: "x", jobNumber: nil,
                                            appointmentID: nil, locationID: nil, customerID: "C-9",
                                            technicianID: nil, equipmentIDs: nil)
        job.provenance = JobFileProvenance(fileName: "job.ogjob", signature: .unsigned, signer: nil, receivedAt: now,
                                           digest: "d", external: external)
        var pick = NewJobSitePick(try XCTUnwrap(NewJobSiteChoices.choices(try inputs(upcoming: [job])).first))
        pick.attach(try XCTUnwrap(NewJobSiteChoices.documentedSites(try documents()).first))
        XCTAssertEqual(pick.documentToChoose, "hillside-house")
        XCTAssertFalse(pick.canRememberClient)
        XCTAssertNil(pick.clientToRemember)
    }

    func testANewSiteIsFiledAsTypedAndAnEmptyOneIsNothing() {
        XCTAssertNil(NewJobSitePick.newSite(JobSite(customer: "  ", address: "")))
        let pick = NewJobSitePick.newSite(JobSite(customer: "Dunn & Sons", address: "40 Quay Road"))
        XCTAssertEqual(pick?.kind, .newSite)
        XCTAssertEqual(pick?.siteToFill, JobSite(customer: "Dunn & Sons", address: "40 Quay Road"))
        XCTAssertNil(pick?.documentToChoose)
        XCTAssertNil(pick?.upcomingJobId)
        XCTAssertEqual(pick?.rowLabel, "Dunn & Sons, 40 Quay Road")
    }
}
