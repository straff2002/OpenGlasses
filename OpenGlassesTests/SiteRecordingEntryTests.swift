import Foundation
import XCTest
@testable import OpenGlasses

/// Plan IM P4 — the site recording's entry points, how a kept one reads, and "Draft site document".
///
/// The vault is HV's fictional dual-fuel fixture (`Fixtures/SiteSystemVault`). Every model, serial,
/// site and word here is invented.
@MainActor
final class ExperienceRecordingEntryTests: XCTestCase {

    private func recording(_ kind: ExperienceRecording.Kind) -> ExperienceRecording {
        ExperienceRecording(id: "abc", kind: kind, createdAt: Date(timeIntervalSince1970: 1_795_600_000),
                            duration: 134, transcript: "The heat pump is an NV36 HP2.", redactions: [],
                            vaultId: SiteSystemFixtures.vaultId)
    }

    // MARK: Which kind each surface starts

    func testThePhonePageStartsThePickedKindAndShowsTheRunningOneWhileBusy() {
        XCTAssertEqual(ExperienceRecordingEntry.kind(selected: .site, recorderBusy: false, recording: .experience), .site)
        XCTAssertEqual(ExperienceRecordingEntry.kind(selected: .experience, recorderBusy: false, recording: .site), .experience)
        XCTAssertEqual(ExperienceRecordingEntry.kind(selected: .experience, recorderBusy: true, recording: .site), .site)
        XCTAssertEqual(ExperienceRecordingEntry.kind(selected: .site, recorderBusy: true, recording: .experience), .experience)
    }

    func testTheJobsListRoutesOpenTheRecorderOnTheirKind() {
        XCTAssertEqual(ExperienceRecordingEntry.kind(for: JobRoute.recordExperience), .experience)
        XCTAssertEqual(ExperienceRecordingEntry.kind(for: JobRoute.recordSite), .site)
        XCTAssertNil(ExperienceRecordingEntry.kind(for: JobRoute.vanStock))
        XCTAssertNil(ExperienceRecordingEntry.kind(for: JobRoute.currentJob))
    }

    func testTheCarRowsStartTheirKind() {
        XCTAssertEqual(ExperienceRecordingEntry.kind(for: CarPlayJobsList.Selection.recordExperience), .experience)
        XCTAssertEqual(ExperienceRecordingEntry.kind(for: CarPlayJobsList.Selection.recordSite), .site)
        XCTAssertNil(ExperienceRecordingEntry.kind(for: CarPlayJobsList.Selection.stopExperienceRecording))
        XCTAssertNil(ExperienceRecordingEntry.kind(for: CarPlayJobsList.Selection.readSendQueue))
    }

    func testTheStartButtonSaysWhichKind() {
        XCTAssertEqual(ExperienceRecordingEntry.startTitle(.experience), "Record experience")
        XCTAssertEqual(ExperienceRecordingEntry.startTitle(.site), "Tell me about this site")
    }

    // MARK: A site recording on the phone

    func testASiteIsNeverFiledOnAnOpenJob() {
        XCTAssertTrue(ExperienceRecordingEntry.filesOnOpenJob(kind: .experience, jobOpen: true))
        XCTAssertFalse(ExperienceRecordingEntry.filesOnOpenJob(kind: .experience, jobOpen: false))
        XCTAssertFalse(ExperienceRecordingEntry.filesOnOpenJob(kind: .site, jobOpen: true))
        XCTAssertFalse(ExperienceRecordingEntry.filesOnOpenJob(kind: .site, jobOpen: false))
    }

    func testAKeptSiteRecordingIsLabelledAsOne() {
        XCTAssertEqual(ExperienceRecordingEntry.rowCaption(recording(.site)), "Site · 2:14 · On this phone")
        XCTAssertEqual(ExperienceRecordingEntry.rowCaption(recording(.experience)), "2:14 · On this phone")
        XCTAssertEqual(ExperienceRecordingEntry.detailTitle(.site), "Site recording")
        XCTAssertEqual(ExperienceRecordingEntry.detailTitle(.experience), "Recording")
    }

    // MARK: The car

    func testTheCarOffersASiteRowBesideRecordExperience() throws {
        let rows = CarPlayJobsList.rows(active: nil, history: [], boundThreadId: nil, experience: .offered)
        XCTAssertEqual(rows.map(\.id), [CarPlayJobsList.experienceRowId, CarPlayJobsList.siteRowId])
        let site = try XCTUnwrap(rows.last)
        XCTAssertEqual(site.selection, .recordSite)
        XCTAssertEqual(site.title, "Tell me about this site")
        XCTAssertLessThanOrEqual(site.title.count, 24)
        XCTAssertLessThanOrEqual(site.detail.count, 28)
    }

    func testWhileRecordingASiteOneStopRowSaysSo() throws {
        XCTAssertEqual(CarPlayJobsList.experienceRow(verdict: .available, recorderBusy: true, recordingKind: .site),
                       .recordingSite)
        XCTAssertEqual(CarPlayJobsList.experienceRow(verdict: .available, recorderBusy: true, recordingKind: .experience),
                       .recording)
        XCTAssertEqual(CarPlayJobsList.experienceRow(verdict: .notOffered, recorderBusy: true, recordingKind: .site),
                       .hidden)
        let rows = CarPlayJobsList.rows(active: nil, history: [], boundThreadId: nil, experience: .recordingSite)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, CarPlayJobsList.experienceRowId)
        XCTAssertEqual(row.selection, .stopExperienceRecording)
        XCTAssertEqual(row.detail, "Recording a site")
    }

    func testHiddenOffersNeitherRow() {
        XCTAssertTrue(CarPlayJobsList.rows(active: nil, history: [], boundThreadId: nil, experience: .hidden).isEmpty)
    }

    // MARK: Who is offered the draft

    func testOnlyASiteRecordingOnAReviewersPhoneOffersTheDraft() {
        XCTAssertEqual(SiteDraftOffer.offer(for: .site, reviewerDevice: true, medicalCompliance: false), .available)
        XCTAssertEqual(SiteDraftOffer.offer(for: .site, reviewerDevice: false, medicalCompliance: false), .reviewerOnly)
        XCTAssertEqual(SiteDraftOffer.offer(for: .site, reviewerDevice: true, medicalCompliance: true), .none)
        XCTAssertEqual(SiteDraftOffer.offer(for: .site, reviewerDevice: false, medicalCompliance: true), .none)
        XCTAssertEqual(SiteDraftOffer.offer(for: .experience, reviewerDevice: true, medicalCompliance: false), .none)
        XCTAssertEqual(SiteDraftOffer.reviewerOnlyLine, "A reviewer's phone drafts the site document from this recording.")
    }
}

@MainActor
final class SiteDraftReviewModelTests: XCTestCase {

    private final class StubModel: RecollectionDraftModel {
        var answers: [Data?]
        var calls = 0
        init(_ answers: [Data?]) { self.answers = answers }
        func extract(system: String, transcript: String, schema: [String: Any]) async -> Data? {
            calls += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private static let transcript = "This is the Hillside house system. In the basement there's the NV80-F060 furnace, "
        + "serial NV80-2201. The side yard heat pump is an NV36 HP2. The hall thermostat is an AT-9. "
        + "The thermostat talks to the furnace over a 4-wire serial bus. The heat pump shows E77 when the furnace "
        + "board drops off the bus, so check the bus at the furnace first. That's all."

    private static func recording(kind: ExperienceRecording.Kind = .site,
                                  vaultId: String = SiteSystemFixtures.vaultId) -> ExperienceRecording {
        ExperienceRecording(id: "0123456789abcdef0123456789abcdef", kind: kind,
                            createdAt: Date(timeIntervalSince1970: 1_795_600_000), duration: 48,
                            transcript: transcript, redactions: [], vaultId: vaultId)
    }

    private static func answer(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var answer: [String: Any] = [
            "name": "Hillside house system", "location_label": "Hillside house", "notes": "",
            "units": [
                ["id": "furnace", "model": "NV80F060", "serial": "NV80-2201", "label": "basement furnace", "covered": true],
                ["id": "heatpump", "model": "NV36HP2", "serial": "", "label": "side yard heat pump", "covered": true],
                ["id": "tstat", "model": "AT-9", "serial": "", "label": "hall thermostat", "covered": false],
            ],
            "connections": [
                ["from": "tstat", "to": "furnace", "kind": "communication", "medium": "", "protocol": "4-wire serial bus",
                 "direction": "", "detail": ""],
            ],
            "controls": [], "integrations": [], "settings": [],
            "interaction_faults": [
                ["seen_on": "heatpump", "code": "E77", "link": "furnace",
                 "text": "Shows E77 when the furnace board drops off the bus; check the bus at the furnace first."],
            ],
        ]
        change(&answer)
        return try JSONSerialization.data(withJSONObject: answer)
    }

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteDraftReviewModelTests_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func model(_ stub: StubModel, reviewer: Bool = true, hipaa: Bool = false,
                       installed: Bool = true) -> SiteDraftReviewModel {
        let drafter = SiteRecordingDrafter(model: stub)
        drafter.context = { .init(isReviewerDevice: reviewer, medicalComplianceMode: hipaa) }
        return SiteDraftReviewModel(drafter: drafter, index: { id in
            installed && id == SiteSystemFixtures.vaultId ? try? SiteSystemFixtures.modelIndex() : nil
        }, shareFolder: folder)
    }

    func testADraftIsShownAndSharedAsItsValidatedFile() async throws {
        let review = model(StubModel([try Self.answer()]))
        XCTAssertEqual(review.state, .idle)
        await review.draft(Self.recording())
        guard case .drafted(let draft) = review.state else { return XCTFail("\(review.state)") }

        XCTAssertEqual(SiteDraftReviewModel.shareFileName(draft), "site-0123456789abcdef0123456789abcdef.json")
        let url = try XCTUnwrap(review.shareURL)
        XCTAssertEqual(url.lastPathComponent, "site-0123456789abcdef0123456789abcdef.json")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes, draft.data, "the shared file is the validated bytes, unchanged")
        let checked = SiteSystemValidator.check(bytes, path: draft.path, modelCovered: try SiteSystemFixtures.covered())
        XCTAssertEqual(checked.issues, [])
        XCTAssertEqual(checked.document, draft.document)

        let summary = SiteDraftSummary(draft.document)
        XCTAssertEqual(summary.name, "Hillside house system")
        XCTAssertEqual(summary.location, "Hillside house")
        XCTAssertNil(summary.notes)
        XCTAssertEqual(summary.units.map(\.model), ["NV80F060", "NV36HP2", "AT-9"])
        XCTAssertEqual(summary.units.map(\.serial), ["NV80-2201", nil, nil])
        XCTAssertEqual(summary.units.map(\.label), ["basement furnace", "side yard heat pump", "hall thermostat"])
        XCTAssertEqual(summary.units.map(\.isCovered), [true, true, false])
        XCTAssertEqual(summary.details, ["4-wire serial bus", "E77",
                                         "Shows E77 when the furnace board drops off the bus; check the bus at the furnace first."])
    }

    func testARefusalShowsTheDraftersReasonsVerbatim() async throws {
        let review = model(StubModel([try Self.answer { answer in
            var units = answer["units"] as! [[String: Any]]
            units[1]["model"] = "NV99HP9"
            answer["units"] = units
        }]))
        await review.draft(Self.recording())
        guard case .refused(let message, let reasons) = review.state else { return XCTFail("\(review.state)") }
        XCTAssertEqual(message, SiteRecordingDraftValidator.Refusal.siteDocument([]).message)
        XCTAssertFalse(reasons.isEmpty)
        XCTAssertTrue(reasons.contains { $0.contains("is not a model this vault has a section for") }, "\(reasons)")
        XCTAssertNil(review.shareURL)
    }

    func testAWordNobodySaidNamesTheMember() async throws {
        let review = model(StubModel([try Self.answer { $0["notes"] = "Installed in 2024." }]))
        await review.draft(Self.recording())
        guard case .refused(_, let reasons) = review.state else { return XCTFail("\(review.state)") }
        XCTAssertEqual(reasons, ["Words not said in the recording: notes"])
    }

    func testNoAnswerIsTheDraftersMessage() async throws {
        let review = model(StubModel([nil]))
        await review.draft(Self.recording())
        XCTAssertEqual(review.state, .refused(message: SiteRecordingDraftValidator.Refusal.noAnswer.message, reasons: []))
    }

    func testAVaultNotOnThePhoneDraftsNothingAndAsksNoModel() async throws {
        let stub = StubModel([try Self.answer()])
        let review = model(stub, installed: false)
        await review.draft(Self.recording())
        XCTAssertEqual(review.state, .refused(message: SiteDraftReviewModel.vaultMissing, reasons: []))
        XCTAssertEqual(stub.calls, 0)
    }

    func testTheDraftersGatesHoldEvenIfThePageOffered() async throws {
        for (reviewer, hipaa, refusal) in [(false, false, SiteRecordingDraftValidator.Refusal.notReviewerDevice),
                                           (true, true, .medicalCompliance)] {
            let stub = StubModel([try Self.answer()])
            let review = model(stub, reviewer: reviewer, hipaa: hipaa)
            await review.draft(Self.recording())
            XCTAssertEqual(review.state, .refused(message: refusal.message, reasons: []))
            XCTAssertEqual(stub.calls, 0)
            XCTAssertNil(review.shareURL)
        }
        let stub = StubModel([try Self.answer()])
        let review = model(stub)
        await review.draft(Self.recording(kind: .experience))
        XCTAssertEqual(review.state, .refused(message: SiteRecordingDraftValidator.Refusal.notASiteRecording.message,
                                              reasons: []))
        XCTAssertEqual(stub.calls, 0)
    }
}
