import XCTest
@testable import OpenGlasses

/// Clips as evidence: what the selection defaults to, how they order beside photographs, what the
/// report plans to print, and what the read-out says (Plan FO P2b).
///
/// All pure. The recorder has its own suite; this one is about the decisions a technician's choice
/// runs through between a file existing and a customer receiving it.
@MainActor
final class JobClipEvidenceTests: XCTestCase {

    private func photo(_ id: String, origin: JobMediaItem.Origin = .photoLog,
                       at seconds: TimeInterval = 0, task: String? = nil) -> JobMediaItem {
        JobMediaItem(id: id, kind: .photo, capturedAt: Date(timeIntervalSince1970: seconds),
                     origin: origin, taskId: task, caption: id, filterWasOn: false)
    }

    private func clip(_ id: String, at seconds: TimeInterval = 0, task: String? = nil,
                      length: TimeInterval = 12, bytes: Int = 900_000,
                      cutShort: Bool = false, poster: Bool = true) -> JobMediaItem {
        JobMediaItem(id: id, kind: .clip, capturedAt: Date(timeIntervalSince1970: seconds),
                     origin: .clipRecord, taskId: task, caption: id, filterWasOn: false,
                     durationSeconds: length, byteCount: bytes,
                     posterId: poster ? id + ".jpg" : nil, cutShort: cutShort)
    }

    // MARK: - Defaults

    /// The rule the owner set: a clip is offered, never pre-selected. It is the one piece of
    /// evidence that may not fit down the channel, so sending it is always a deliberate act.
    func testAClipIsOfferedButNeverTickedByDefault() {
        let selection = EvidenceSelection.proposed(for: [photo("p"), clip("c")])
        XCTAssertEqual(try XCTUnwrap(selection.entry(for: "p")).included, true,
                       "a logged photograph keeps its P2a default")
        XCTAssertEqual(try XCTUnwrap(selection.entry(for: "c")).included, false)
        XCTAssertEqual(try XCTUnwrap(selection.entry(for: "c")).kind, .clip)
    }

    /// Even a clip that arrived by the deliberate `record_clip` route is not pre-selected: the
    /// default keys on the kind, not only on the reason it was captured.
    func testTheClipDefaultIsAboutTheKindNotOnlyTheOrigin() {
        XCTAssertFalse(clip("c").isIncludedByDefault)
        XCTAssertTrue(photo("p").isIncludedByDefault)
        XCTAssertFalse(photo("q", origin: .capture).isIncludedByDefault)
    }

    /// A clip recorded after the review was proposed still arrives at its own default rather than
    /// inheriting a neighbour's.
    func testReconcilingKeepsDecisionsAndGivesANewClipTheClipDefault() {
        var selection = EvidenceSelection.proposed(for: [photo("p")])
        selection.setIncluded(false, for: "p")
        let next = selection.reconciled(with: [photo("p"), clip("c")])
        XCTAssertEqual(try XCTUnwrap(next.entry(for: "p")).included, false)
        XCTAssertEqual(try XCTUnwrap(next.entry(for: "c")).included, false)
        XCTAssertEqual(try XCTUnwrap(next.entry(for: "c")).kind, .clip)
    }

    // MARK: - Ordering across kinds

    /// Fault → Fix → unmarked, exactly as P2a, with kind playing no part: a clip marked Fault
    /// leads a photograph marked Fix, because the ordering is the story, not the file type.
    func testOrderingIsByRoleThenCaptureOrderWhateverTheKind() {
        let items = [photo("p1", at: 10), clip("c1", at: 20), photo("p2", at: 30),
                     clip("c2", at: 40)]
        var selection = EvidenceSelection.proposed(for: items)
        selection.includeAll()
        selection.setRole(.fix, for: "p1")
        selection.setRole(.fault, for: "c2")
        XCTAssertEqual(selection.includedItemIds, ["c2", "p1", "c1", "p2"])
    }

    func testIncludedIdsCanBeAskedForByKind() {
        let items = [photo("p1", at: 10), clip("c1", at: 20), clip("c2", at: 30)]
        var selection = EvidenceSelection.proposed(for: items)
        selection.includeAll()
        XCTAssertEqual(selection.includedItemIds(kind: .clip), ["c1", "c2"])
        XCTAssertEqual(selection.includedItemIds(kind: .photo), ["p1"])
    }

    // MARK: - The render plan

    func testThePlanCountsPicturesAndClipsApart() {
        let items = [photo("p1", task: "t"), clip("c1", task: "t")]
        var selection = EvidenceSelection.proposed(for: items)
        selection.includeAll()
        let plan = EvidenceRenderPlan.make(items: items, selection: selection,
                                           taskTitles: [(id: "t", title: "Condensate trap")])
        XCTAssertEqual(plan.entryCount, 2)
        XCTAssertEqual(plan.photoCount, 1, "the image budget must not count a clip it cannot draw")
        XCTAssertEqual(plan.clipCount, 1)
    }

    func testTheClipLineCarriesCaptionTimeLengthAndHowItTravelled() {
        let item = clip("c1", at: 3_600, length: 12)
        let entry = EvidenceRenderPlan.Entry(item: item, role: nil, caption: "compressor cycling")
        let line = SessionExporter.clipLine(entry, plan: .undecided)
        XCTAssertTrue(line.hasPrefix("Clip · compressor cycling · "), line)
        XCTAssertTrue(line.contains("12 seconds"), line)
        XCTAssertTrue(line.contains("sent separately"), line)
        XCTAssertFalse(line.contains("cut short"), line)
    }

    func testAClipCutShortSaysSoOnItsLine() {
        let entry = EvidenceRenderPlan.Entry(item: clip("c1", cutShort: true), role: nil,
                                             caption: "fan wobble")
        XCTAssertTrue(SessionExporter.clipLine(entry, plan: .undecided).contains("cut short"))
    }

    func testAnOverBudgetClipsLineNamesTheChannelAndTheLimit() {
        let big = clip("c1", bytes: 40 * 1024 * 1024)
        let plan = ClipDeliveryPlan(channel: .email,
                                    partition: AttachmentBudget.standard(for: .email)
                                        .partition(clips: [big]))
        let line = SessionExporter.clipLine(
            EvidenceRenderPlan.Entry(item: big, role: nil, caption: "arcing contactor"), plan: plan)
        XCTAssertTrue(line.contains("over the size limit for Email"), line)
        XCTAssertTrue(line.contains("shared separately"), line)
    }

    func testTheEvidenceHeadingLeadCountsBothKinds() {
        XCTAssertEqual(SessionExporter.evidenceLead(photos: 3, clips: 1),
                       "3 pictures and 1 clip selected by the technician.")
        XCTAssertEqual(SessionExporter.evidenceLead(photos: 1, clips: 0),
                       "1 picture selected by the technician.")
        XCTAssertEqual(SessionExporter.evidenceLead(photos: 0, clips: 2),
                       "2 clips selected by the technician.")
    }

    // MARK: - Words

    func testDurationLabelsReadAsAPersonWouldSayThem() {
        XCTAssertEqual(clip("c", length: 1).durationLabel, "1 second")
        XCTAssertEqual(clip("c", length: 12).durationLabel, "12 seconds")
        XCTAssertEqual(clip("c", length: 60).durationLabel, "1 minute")
        XCTAssertEqual(clip("c", length: 75).durationLabel, "1 minute 15 seconds")
        XCTAssertNil(photo("p").durationLabel, "a photograph has no length to state")
    }

    func testTheDurationBadgeIsATimecodeAndOnlyAppearsOnAClip() {
        XCTAssertEqual(clip("c", length: 12).durationBadge, "0:12")
        XCTAssertEqual(clip("c", length: 75).durationBadge, "1:15")
        XCTAssertNil(photo("p").durationBadge)
    }

    /// VoiceOver has to be told what kind of thing it is and how long it runs — the badge and the
    /// play glyph are pixels, and a screen-reader user never sees either.
    func testTheSpokenLabelLeadsWithTheKindAndTheLength() {
        let spoken = clip("c", length: 12).spoken(taskTitle: "Condensate trap", included: true,
                                                  role: .fault)
        XCTAssertTrue(spoken.hasPrefix("Clip, 12 seconds, c,"), spoken)
        XCTAssertTrue(spoken.contains("Fault"), spoken)
        XCTAssertTrue(spoken.contains("Included in the report"), spoken)
    }

    func testTheSpokenLabelSaysWhenAClipWasCutShort() {
        XCTAssertTrue(clip("c", cutShort: true)
            .spoken(taskTitle: nil, included: false, role: nil).contains("Cut short"))
    }

    /// The one-at-a-time read-out already asks "photo 2 of 5"; a clip has to be announced as a
    /// clip, or a technician says yes to a video believing it is a still.
    func testTheReadOutAnnouncesAClipAsAClip() {
        let question = EvidenceReviewVoiceState.question(for: clip("c", length: 12), number: 2,
                                                          of: 5)
        XCTAssertEqual(question, "Clip 2 of 5, c. Include it?")
    }

    func testTheSpokenWalkCanIncludeAndExcludeAClipLikeAnythingElse() {
        let items = [clip("c1"), photo("p1")]
        var state = EvidenceReviewVoiceState(selection: .proposed(for: items))
        let first = state.beginWalk(items: items)
        XCTAssertTrue(try XCTUnwrap(first.spoken).hasPrefix("Clip 1 of 2"))
        state = first.state
        let yes = state.hearing("yes", items: items)
        XCTAssertTrue(yes.consumed)
        XCTAssertEqual(try XCTUnwrap(yes.state.selection.entry(for: "c1")).included, true)
    }

    // MARK: - The preview a grid can actually draw

    func testAClipPreviewsByItsPosterFrameAndAPhotographByItself() {
        XCTAssertEqual(clip("c").previewFileName, "c.jpg")
        XCTAssertEqual(photo("p").previewFileName, "p")
        XCTAssertNil(clip("c", poster: false).previewFileName,
                     "with no poster the grid draws a placeholder rather than decoding a video")
    }

    func testTheReviewModelNamesTheSectionAfterWhatIsActuallyOnTheJob() {
        let directory = URL(fileURLWithPath: "/tmp/does-not-matter")
        let photosOnly = EvidenceReviewModel(items: [photo("p")], taskTitles: [],
                                             photosDirectory: directory, faceBlurOn: false)
        XCTAssertEqual(photosOnly.sectionTitle, "Photos")
        XCTAssertFalse(photosOnly.hasClips)

        let mixed = EvidenceReviewModel(items: [photo("p"), clip("c")], taskTitles: [],
                                        photosDirectory: directory, faceBlurOn: false)
        XCTAssertEqual(mixed.sectionTitle, "Photos and clips")
        XCTAssertEqual(mixed.clipCount, 1)
        XCTAssertEqual(mixed.photoCount, 1)
        XCTAssertEqual(mixed.previewURL(for: mixed.items.first { $0.kind == .clip }!)?
            .lastPathComponent, "c.jpg")
    }

    func testTheSummaryCountsInItemsOnceThereIsSomethingThatIsNotAPhotograph() {
        let directory = URL(fileURLWithPath: "/tmp/does-not-matter")
        let items = [photo("p"), clip("c")]
        var selection = EvidenceSelection.proposed(for: items)
        selection.includeAll()
        let model = EvidenceReviewModel(items: items, taskTitles: [],
                                        photosDirectory: directory, faceBlurOn: false)
        XCTAssertEqual(model.summary(for: selection), "2 of 2 items will go with the report.")
    }

    // MARK: - Old records

    /// A P2a session — photographs only, no duration, no poster, no clip key anywhere — has to
    /// keep loading exactly as it did, and keep its own selection defaults.
    func testAPhotoOnlyRecordWrittenBeforeClipsExistedStillDecodes() throws {
        let json = """
        {"id":"a.jpg","kind":"photo","captured_at":"2026-09-10T09:00:00Z","origin":"photo_log",
         "caption":"trap","filter_was_on":true}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(JobMediaItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.kind, .photo)
        XCTAssertNil(item.durationSeconds)
        XCTAssertNil(item.byteCount)
        XCTAssertNil(item.posterId)
        XCTAssertFalse(item.cutShort)
        XCTAssertTrue(item.isIncludedByDefault)
    }

    /// And a record written *by* this build round-trips every new field.
    func testAClipRoundTripsThroughTheRecordsOwnCoding() throws {
        let original = clip("c.mp4", at: 1_700_000_000, length: 18, bytes: 1_234_567,
                            cutShort: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(JobMediaItem.self,
                                         from: try encoder.encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// A work record that never reached the review names no clips at all — "not chosen" is the
    /// only safe reading when what is at stake is a video of a customer's plant room.
    func testAnUnreviewedRecordOffersNoClips() {
        let items = [clip("c")]
        var session = FieldSession(id: "s1", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   endedAt: nil, pausedAt: nil, resumedAt: nil,
                                   outcome: .inProgress, startLocation: nil, endLocation: nil,
                                   escalations: [], billableSeconds: 0)
        session.media = items
        XCTAssertTrue(WorkRecord(session: session, vaultName: "Refrigeration").includedClips.isEmpty)

        var selection = EvidenceSelection.proposed(for: items)
        selection.includeAll()
        session.evidenceSelection = selection.confirmed()
        XCTAssertEqual(WorkRecord(session: session, vaultName: "Refrigeration")
            .includedClips.map(\.id), ["c"])
    }
}
