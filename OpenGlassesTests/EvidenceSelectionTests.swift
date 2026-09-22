import XCTest
@testable import OpenGlasses

/// The pure half of the evidence review (Plan FO P2a): what is selected by default, in what order
/// the report prints it, what a stored selection does when the evidence has moved on, and whether
/// a thirty-photo job still produces a file anybody can send.
final class EvidenceSelectionTests: XCTestCase {

    private func item(_ id: String, origin: JobMediaItem.Origin = .photoLog,
                      task: String? = nil, caption: String? = nil,
                      at offset: TimeInterval = 0, blurred: Bool = false) -> JobMediaItem {
        JobMediaItem(id: id, capturedAt: Date(timeIntervalSince1970: 1_000 + offset),
                     origin: origin, taskId: task, caption: caption, filterWasOn: blurred)
    }

    // MARK: - Defaults

    /// A picture taken *in order to* document something is part of the record unless the
    /// technician removes it. Everything else is offered.
    func testPhotoLogIsTickedAndEverythingElseIsOffered() {
        let items = [item("a", origin: .photoLog),
                     item("b", origin: .capture, at: 1),
                     item("c", origin: .phoneCamera, at: 2),
                     item("d", origin: .photoLibrary, at: 3)]
        let selection = EvidenceSelection.proposed(for: items)

        XCTAssertEqual(selection.entries.map(\.itemId), ["a", "b", "c", "d"])
        XCTAssertEqual(selection.entries.map(\.included), [true, false, false, false])
        XCTAssertEqual(selection.includedCount, 1)
        XCTAssertEqual(selection.entries.map(\.order), [0, 1, 2, 3])
    }

    /// The proposal is not an answer. Until the technician has been through the step, the record
    /// goes out the way it always has.
    func testAProposalIsNotAReview() {
        XCTAssertFalse(EvidenceSelection.proposed(for: [item("a")]).reviewed)
        XCTAssertTrue(EvidenceSelection.proposed(for: [item("a")]).confirmed().reviewed)
        XCTAssertFalse(EvidenceSelection.skipped().reviewed)
    }

    /// Skipping and excluding everything must not be the same value — one sends the text-only
    /// record, the other is a deliberate empty selection.
    func testSkippingIsNotTheSameAsExcludingEverything() {
        var everythingOut = EvidenceSelection.proposed(for: [item("a")])
        everythingOut.excludeAll()
        let confirmed = everythingOut.confirmed()

        XCTAssertTrue(confirmed.reviewed)
        XCTAssertEqual(confirmed.includedCount, 0)
        XCTAssertNotEqual(confirmed, EvidenceSelection.skipped())
    }

    // MARK: - Ordering

    func testRenderOrderIsFaultThenFixThenUnmarkedAndThenCaptureOrder() {
        let items = (0..<6).map { item("p\($0)", at: TimeInterval($0)) }
        var selection = EvidenceSelection.proposed(for: items)
        selection.includeAll()
        selection.setRole(.fix, for: "p1")
        selection.setRole(.fault, for: "p4")
        selection.setRole(.fault, for: "p2")
        selection.setRole(.fix, for: "p5")

        XCTAssertEqual(selection.includedItemIds, ["p2", "p4", "p1", "p5", "p0", "p3"])
    }

    /// Marking is optional and never prompted. With none at all the order is simply the order the
    /// pictures were taken in — not an empty list, and not a crash.
    func testNoMarksAtAllIsAValidReportInCaptureOrder() {
        let items = (0..<3).map { item("p\($0)", at: TimeInterval($0)) }
        var selection = EvidenceSelection.proposed(for: items)
        selection.includeAll()

        XCTAssertEqual(selection.includedItemIds, ["p0", "p1", "p2"])
        XCTAssertTrue(selection.entries.allSatisfy { $0.role == nil })
    }

    /// Two marks the same way clears it, which is the grid's one tap per role.
    func testMarkingTwiceClearsTheMarkAndMarkingIncludes() {
        var selection = EvidenceSelection.proposed(for: [item("a", origin: .capture)])
        XCTAssertFalse(selection.entry(for: "a")!.included)

        selection.setRole(.fault, for: "a")
        XCTAssertEqual(selection.entry(for: "a")?.role, .fault)
        XCTAssertTrue(selection.entry(for: "a")!.included, "marking says this is part of the story")

        selection.setRole(.fault, for: "a")
        XCTAssertNil(selection.entry(for: "a")?.role)
        XCTAssertTrue(selection.entry(for: "a")!.included, "un-marking must not silently drop it")
    }

    func testAnEmptyCaptionIsNoCaption() {
        var selection = EvidenceSelection.proposed(for: [item("a", caption: "gauge")])
        selection.setCaption("   ", for: "a")
        XCTAssertNil(selection.entry(for: "a")?.caption)
        selection.setCaption("  suction gauge ", for: "a")
        XCTAssertEqual(selection.entry(for: "a")?.caption, "suction gauge")
    }

    // MARK: - Reconciling

    /// A photo taken while the review is open takes the default; one whose file has gone is
    /// dropped; every decision already made survives.
    func testReconcilingKeepsDecisionsAndTakesDefaultsForNewEvidence() {
        var selection = EvidenceSelection.proposed(for: [item("a"), item("b", origin: .capture, at: 1)])
        selection.setIncluded(true, for: "b")
        selection.setRole(.fix, for: "b")
        selection.setCaption("new trap", for: "b")
        selection = selection.confirmed()

        let now = [item("b", origin: .capture, at: 1),
                   item("c", origin: .photoLog, at: 2),
                   item("d", origin: .capture, at: 3)]
        let carried = selection.reconciled(with: now)

        XCTAssertEqual(carried.entries.map(\.itemId), ["b", "c", "d"])
        XCTAssertTrue(carried.reviewed)
        XCTAssertEqual(carried.entry(for: "b")?.role, .fix)
        XCTAssertEqual(carried.entry(for: "b")?.caption, "new trap")
        XCTAssertTrue(carried.entry(for: "c")!.included, "a new photo_log photo takes its default")
        XCTAssertFalse(carried.entry(for: "d")!.included, "a new capture is offered, not assumed")
        XCTAssertEqual(carried.entries.map(\.order), [0, 1, 2], "order follows the current list")
    }

    // MARK: - Persistence

    func testSelectionRoundTripsThroughJSON() throws {
        var selection = EvidenceSelection.proposed(for: [item("a"), item("b", origin: .capture, at: 1)])
        selection.setRole(.fault, for: "a")
        selection.setCaption("leak site", for: "a")
        let confirmed = selection.confirmed()

        let data = try JSONEncoder().encode(confirmed)
        let decoded = try JSONDecoder().decode(EvidenceSelection.self, from: data)
        XCTAssertEqual(decoded, confirmed)
    }

    /// A session written before any of this existed decodes with an empty, unreviewed selection
    /// rather than throwing — the same rule every other field added to `FieldSession` follows.
    func testALegacyPayloadDecodesToNothingChosen() throws {
        let decoded = try JSONDecoder().decode(EvidenceSelection.self,
                                               from: Data("{}".utf8))
        XCTAssertFalse(decoded.reviewed)
        XCTAssertTrue(decoded.entries.isEmpty)
    }

    /// An entry from a build that knew a media kind or a role this one does not must not take the
    /// whole record down with it.
    func testAnUnknownKindOrRoleDecodesToTheOrdinaryCase() throws {
        let json = """
        {"reviewed":true,"entries":[
          {"item_id":"a","kind":"hologram","included":true,"role":"sideways","order":0}]}
        """
        let decoded = try JSONDecoder().decode(EvidenceSelection.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries[0].kind, .photo)
        XCTAssertNil(decoded.entries[0].role)
        XCTAssertTrue(decoded.entries[0].included)
    }

    /// The second kind has to exist before clips do, or adding them means reshaping the selection,
    /// the grid and the export at once (Plan FO P2b).
    func testTheSelectionCanHoldASecondMediaKind() throws {
        let clip = JobMediaItem(id: "c1", kind: .clip, capturedAt: Date(), origin: .photoLog,
                                filterWasOn: false)
        let selection = EvidenceSelection.proposed(for: [item("a"), clip])
        XCTAssertEqual(selection.entries.map(\.kind), [.photo, .clip])

        let data = try JSONEncoder().encode(selection)
        XCTAssertEqual(try JSONDecoder().decode(EvidenceSelection.self, from: data), selection)
    }

    // MARK: - The render plan

    func testTheReportGroupsByTaskAndPutsJobLevelEvidenceLast() {
        let items = [item("a", task: "t1", at: 0),
                     item("b", at: 1),
                     item("c", task: "t2", at: 2),
                     item("d", task: "t1", at: 3)]
        var selection = EvidenceSelection.proposed(for: items)
        selection.includeAll()
        selection.setRole(.fix, for: "a")
        selection.setRole(.fault, for: "d")

        let plan = EvidenceRenderPlan.make(items: items, selection: selection,
                                           taskTitles: [(id: "t1", title: "Condensate trap"),
                                                        (id: "t2", title: "Flame sensor")])

        XCTAssertEqual(plan.groups.map(\.title),
                       ["Condensate trap", "Flame sensor", EvidenceRenderPlan.jobLevelTitle])
        XCTAssertEqual(plan.groups[0].entries.map(\.item.id), ["d", "a"], "fault before fix")
        XCTAssertEqual(plan.itemIds, ["d", "a", "c", "b"])
        XCTAssertEqual(plan.entryCount, 4)
    }

    func testUnselectedEvidenceIsNotInThePlanAtAll() {
        let items = [item("a"), item("b", origin: .capture, at: 1)]
        let plan = EvidenceRenderPlan.make(items: items,
                                           selection: EvidenceSelection.proposed(for: items),
                                           taskTitles: [])
        XCTAssertEqual(plan.itemIds, ["a"])
    }

    /// An item the selection has never heard of has not been chosen. "Not decided" and "chosen"
    /// must never collapse when what is at stake is a photograph leaving the device.
    func testAnItemWithNoEntryIsNotRendered() {
        let plan = EvidenceRenderPlan.make(items: [item("a")], selection: EvidenceSelection(),
                                           taskTitles: [])
        XCTAssertTrue(plan.isEmpty)
    }

    /// A task that has gone from the record must not take its photographs with it.
    func testEvidenceOnAVanishedTaskFallsBackToTheJobGroup() {
        let items = [item("a", task: "gone")]
        var selection = EvidenceSelection.proposed(for: items)
        selection.includeAll()
        let plan = EvidenceRenderPlan.make(items: items, selection: selection, taskTitles: [])
        XCTAssertEqual(plan.groups.map(\.title), [EvidenceRenderPlan.jobLevelTitle])
        XCTAssertEqual(plan.itemIds, ["a"])
    }

    // MARK: - The image budget

    func testTheBudgetHoldsAtOneTwentyAndThirtyPhotos() {
        let budget = EvidenceImageBudget.standard
        for count in [1, 20, 30] {
            let plan = budget.plan(photoCount: count)
            XCTAssertLessThanOrEqual(plan.estimatedTotalBytes, budget.totalByteCeiling,
                                     "\(count) photos blew the ceiling")
            XCTAssertFalse(plan.atFloor, "\(count) photos should not need the floor rung")
        }
    }

    /// The same count must always produce the same file, or a re-send would be a different PDF.
    func testTheBudgetIsDeterministic() {
        for count in [1, 7, 20, 30, 300] {
            XCTAssertEqual(EvidenceImageBudget.standard.plan(photoCount: count),
                           EvidenceImageBudget.standard.plan(photoCount: count))
        }
    }

    /// More pictures never buys a bigger one.
    func testTheLadderOnlyEverGoesDown() {
        var previous = EvidenceImageBudget.standard.plan(photoCount: 1)
        for count in 2...60 {
            let plan = EvidenceImageBudget.standard.plan(photoCount: count)
            XCTAssertLessThanOrEqual(plan.longEdge, previous.longEdge, "grew at \(count)")
            XCTAssertLessThanOrEqual(plan.quality, previous.quality, "grew at \(count)")
            previous = plan
        }
    }

    /// The floor is a floor, not a cliff: an absurd job produces a larger file honestly rather
    /// than evidence nobody can read.
    func testAnAbsurdJobStopsAtTheFloorAndSaysSo() {
        let plan = EvidenceImageBudget.standard.plan(photoCount: 2_000)
        XCTAssertTrue(plan.atFloor)
        XCTAssertEqual(plan.longEdge, EvidenceImageBudget.standard.tiers.last?.longEdge)
    }

    func testFittingNeverEnlargesAndKeepsTheAspectRatio() {
        let plan = EvidenceImageBudget.standard.plan(photoCount: 1)
        let wide = plan.fitted(CGSize(width: 4_000, height: 3_000),
                               in: CGSize(width: 512, height: 512))
        XCTAssertEqual(wide.width / wide.height, 4.0 / 3.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(wide.width, 512)

        let tiny = plan.fitted(CGSize(width: 40, height: 30), in: CGSize(width: 512, height: 512))
        XCTAssertEqual(tiny.width, 40, accuracy: 0.001, "a small picture is never blown up")
    }

    // MARK: - The review grid

    func testTheGridGroupsByTaskWithTheNewestLast() {
        let items = [item("b", task: "t1", at: 5),
                     item("a", task: "t1", at: 1),
                     item("c", at: 3)]
        let review = EvidenceReviewModel(items: items,
                                         taskTitles: [(id: "t1", title: "Pressure switch")],
                                         photosDirectory: URL(fileURLWithPath: "/tmp/photos"),
                                         faceBlurOn: true)

        XCTAssertEqual(review.groups.map(\.title),
                       ["Pressure switch", EvidenceRenderPlan.jobLevelTitle])
        XCTAssertEqual(review.groups[0].rows.map(\.id), ["a", "b"], "newest last")
        XCTAssertEqual(review.faceBlurLine, "Face blur: On")
        XCTAssertEqual(review.count, 3)
    }

    /// The share sheet gets exactly what was selected, in the order the report prints it, and
    /// nothing that is not on the job.
    func testShareURLsAreExactlyTheSelectedStoredFiles() {
        let directory = URL(fileURLWithPath: "/tmp/photos")
        let items = [item("a", at: 0), item("b", origin: .capture, at: 1), item("c", at: 2)]
        var selection = EvidenceSelection.proposed(for: items)
        selection.setIncluded(true, for: "b")
        selection.setRole(.fault, for: "c")
        // Something the job no longer holds, as a stale selection would carry.
        selection.entries.append(.init(itemId: "ghost", included: true, order: 99))

        let review = EvidenceReviewModel(items: items, taskTitles: [],
                                         photosDirectory: directory, faceBlurOn: false)
        XCTAssertEqual(review.shareURLs(for: selection).map(\.lastPathComponent),
                       ["c", "a", "b"])
    }

    func testTheSummaryCountsWhatIsGoingOut() {
        let items = [item("a"), item("b", origin: .capture, at: 1)]
        let review = EvidenceReviewModel(items: items, taskTitles: [],
                                         photosDirectory: URL(fileURLWithPath: "/tmp"),
                                         faceBlurOn: false)
        XCTAssertEqual(review.summary(for: EvidenceSelection.proposed(for: items)),
                       "1 of 2 photos will go with the report.")
        var none = EvidenceSelection.proposed(for: items)
        none.excludeAll()
        XCTAssertEqual(review.summary(for: none), "No photos will go with the report.")
    }

    // MARK: - What the face-blur line is allowed to claim

    /// A finished job states what was **applied**, not what the setting says today. The setting is
    /// app-wide and may have been toggled since; the pictures cannot change either way.
    func testAFinishedJobReportsTheBlurThatWasApplied() {
        let directory = URL(fileURLWithPath: "/tmp/photos")
        let blurred = [item("a", blurred: true), item("b", at: 1, blurred: true)]
        let allBlurred = EvidenceReviewModel(items: blurred, taskTitles: [],
                                             photosDirectory: directory,
                                             faceBlur: .recorded(from: blurred))
        XCTAssertEqual(allBlurred.faceBlurLine, "Face blur: On when these were taken")
        XCTAssertTrue(allBlurred.faceBlurOn)
        // Nothing can be changed about a finished job's pictures, so nothing offers to.
        XCTAssertFalse(allBlurred.faceBlurDetail.contains("Settings"),
                       "a finished job offered a setting that cannot affect its pictures")

        let plain = [item("a"), item("b", at: 1)]
        let none = EvidenceReviewModel(items: plain, taskTitles: [], photosDirectory: directory,
                                       faceBlur: .recorded(from: plain))
        XCTAssertEqual(none.faceBlurLine, "Face blur: Off when these were taken")
        XCTAssertFalse(none.faceBlurOn)
    }

    /// Half and half is its own answer. Saying "On" would tell the technician every face was
    /// covered when one of these is about to go to a customer unblurred.
    func testAMixedJobSaysHowManyWereBlurred() {
        let items = [item("a", blurred: true), item("b", at: 1), item("c", at: 2, blurred: true)]
        let review = EvidenceReviewModel(items: items, taskTitles: [],
                                         photosDirectory: URL(fileURLWithPath: "/tmp/photos"),
                                         faceBlur: .recorded(from: items))
        XCTAssertEqual(review.faceBlurLine, "Face blur: On for 2 of 3")
        XCTAssertFalse(review.faceBlurOn, "a mixed job must not draw as fully blurred")
    }

    /// A finished job's summary is past tense: the report was already made from these.
    func testAFinishedJobSummaryIsPastTense() {
        let items = [item("a"), item("b", at: 1)]
        let review = EvidenceReviewModel(items: items, taskTitles: [],
                                         photosDirectory: URL(fileURLWithPath: "/tmp/photos"),
                                         faceBlur: .recorded(from: items))
        XCTAssertEqual(review.summary(for: EvidenceSelection.proposed(for: items)),
                       "2 of 2 photos went with the report.")
        var none = EvidenceSelection.proposed(for: items)
        none.excludeAll()
        XCTAssertEqual(review.summary(for: none), "No photos went with the report.")
    }

    /// An open job keeps answering with the live setting: it is what the next picture gets, and it
    /// is still changeable.
    func testAnOpenJobStillReportsTheLiveSetting() {
        let items = [item("a", blurred: true)]
        let review = EvidenceReviewModel(items: items, taskTitles: [],
                                         photosDirectory: URL(fileURLWithPath: "/tmp/photos"),
                                         faceBlur: .live(on: false))
        XCTAssertEqual(review.faceBlurLine, "Face blur: Off")
        XCTAssertTrue(review.faceBlurDetail.contains("Settings"),
                      "an open job should say where the blur is changed")
    }

    /// A picture taken while the blur was on is labelled as such, because the technician is
    /// deciding what a customer sees.
    func testTheSpokenLabelSaysWhatTheRecipientWillSee() {
        let row = EvidenceReviewModel.Row(item: item("a", caption: "leak site", blurred: true),
                                          taskTitle: "Condensate trap")
        let spoken = row.spoken(included: true, role: .fault)
        XCTAssertTrue(spoken.contains("leak site"))
        XCTAssertTrue(spoken.contains("Condensate trap"))
        XCTAssertTrue(spoken.contains("Fault"))
        XCTAssertTrue(spoken.contains("Included in the report"))
        XCTAssertTrue(spoken.contains("face blur on"))
    }
}
