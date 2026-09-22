import XCTest
@testable import OpenGlasses

/// What each channel will carry, and what happens to a clip that does not fit (Plan FO P2b).
///
/// The whole point of the type is that the answer is decided **before** a composer opens, so the
/// technician is told rather than discovering it from a report that never arrived. These are the
/// table: exactly at the cap, one byte over, everything over, nothing to partition at all.
@MainActor
final class AttachmentBudgetTests: XCTestCase {

    private func clip(_ id: String, bytes: Int?, seconds: TimeInterval = 12) -> JobMediaItem {
        JobMediaItem(id: id, kind: .clip, capturedAt: Date(timeIntervalSince1970: 1_000),
                     origin: .clipRecord, caption: id, filterWasOn: false,
                     durationSeconds: seconds, byteCount: bytes, posterId: id + ".jpg")
    }

    // MARK: - The channels

    func testEmailAndMessagesCarryFilesAndTheUrlSchemeChannelsDoNot() {
        XCTAssertTrue(AttachmentBudget.standard(for: .email).carriesFiles)
        XCTAssertTrue(AttachmentBudget.standard(for: .messages).carriesFiles)
        XCTAssertTrue(AttachmentBudget.standard(for: .shareSheet).carriesFiles)
        XCTAssertFalse(AttachmentBudget.standard(for: .whatsapp).carriesFiles)
        XCTAssertFalse(AttachmentBudget.standard(for: .telegram).carriesFiles)
        // The unattended route posts JSON to an endpoint that has never been handed a file.
        XCTAssertFalse(AttachmentBudget.standard(for: .endpoint).carriesFiles)
    }

    func testMessagesCarriesNothingWhenTheDeviceSaysItCannotAttach() {
        let budget = AttachmentBudget.standard(for: .messages, canSendAttachments: false)
        XCTAssertFalse(budget.carriesFiles)
        let partition = budget.partition(clips: [clip("a", bytes: 1_000)])
        XCTAssertTrue(partition.attached.isEmpty)
        XCTAssertEqual(partition.overBudgetIds, ["a"])
    }

    func testTheShareSheetHasNoStatedCeiling() {
        let budget = AttachmentBudget.standard(for: .shareSheet)
        XCTAssertNil(budget.perFileBytes)
        XCTAssertNil(budget.totalBytes)
        let huge = clip("a", bytes: 400 * 1024 * 1024)
        XCTAssertEqual(budget.partition(clips: [huge]).attached, ["a"])
    }

    // MARK: - The edges

    func testAClipExactlyAtTheCeilingIsAttachedAndOneByteOverIsNot() {
        let budget = AttachmentBudget.standard(for: .email)
        let ceiling = try! XCTUnwrap(budget.perFileBytes)
        XCTAssertEqual(budget.partition(clips: [clip("exact", bytes: ceiling)]).attached, ["exact"])

        let over = budget.partition(clips: [clip("over", bytes: ceiling + 1)])
        XCTAssertTrue(over.attached.isEmpty)
        XCTAssertEqual(over.overBudgetIds, ["over"])
        XCTAssertTrue(try XCTUnwrap(over.overBudget.first).reason.contains("Email"),
                      "the reason must name the channel the technician chose")
    }

    func testTheReserveForTheReportItselfComesOffTheTotal() {
        let budget = AttachmentBudget.standard(for: .email)
        let total = try! XCTUnwrap(budget.totalBytes)
        // Alone it fits; with the report's own allowance taken first it does not.
        XCTAssertEqual(budget.partition(clips: [clip("a", bytes: total - 10)]).attached, ["a"])
        let squeezed = budget.partition(clips: [clip("a", bytes: total - 10)], reservedBytes: 1_000)
        XCTAssertTrue(squeezed.attached.isEmpty)
        XCTAssertEqual(squeezed.overBudgetIds, ["a"])
    }

    /// One oversized clip must not consume the room a later small one could have used.
    func testAnOversizedClipDoesNotPushASmallOneOut() {
        let budget = AttachmentBudget.standard(for: .messages)
        let ceiling = try! XCTUnwrap(budget.perFileBytes)
        let partition = budget.partition(clips: [clip("big", bytes: ceiling * 2),
                                                 clip("small", bytes: 1_000)])
        XCTAssertEqual(partition.attached, ["small"])
        XCTAssertEqual(partition.overBudgetIds, ["big"])
    }

    func testEverythingOverBudgetLeavesNothingAttached() {
        let budget = AttachmentBudget.standard(for: .messages)
        let ceiling = try! XCTUnwrap(budget.perFileBytes)
        let partition = budget.partition(clips: [clip("a", bytes: ceiling + 1),
                                                 clip("b", bytes: ceiling + 2)])
        XCTAssertTrue(partition.attached.isEmpty)
        XCTAssertEqual(partition.overBudgetIds, ["a", "b"])
    }

    func testNoClipsPartitionsToNothingAtAll() {
        let partition = AttachmentBudget.standard(for: .email).partition(clips: [])
        XCTAssertTrue(partition.isEmpty)
    }

    /// An unmeasured clip is never attached on trust: the honest answer is the route with no limit.
    func testAClipWithNoMeasuredSizeIsNeverAttached() {
        let partition = AttachmentBudget.standard(for: .email)
            .partition(clips: [clip("a", bytes: nil), clip("b", bytes: 0)])
        XCTAssertTrue(partition.attached.isEmpty)
        XCTAssertEqual(partition.overBudgetIds, ["a", "b"])
    }

    /// The same clips and the same channel must partition identically every time, or a re-send
    /// from a past job is not a re-send.
    func testThePartitionIsDeterministic() {
        let clips = [clip("a", bytes: 2_000_000), clip("b", bytes: 9_000_000),
                     clip("c", bytes: 500_000)]
        let first = AttachmentBudget.standard(for: .messages).partition(clips: clips)
        let second = AttachmentBudget.standard(for: .messages).partition(clips: clips)
        XCTAssertEqual(first, second)
    }

    // MARK: - What the plan says

    func testTheTravelNoteNamesTheChannelForAnOverBudgetClipAndNotForAnAttachedOne() {
        let budget = AttachmentBudget.standard(for: .messages)
        let ceiling = try! XCTUnwrap(budget.perFileBytes)
        let clips = [clip("small", bytes: 1_000), clip("big", bytes: ceiling + 1)]
        let plan = ClipDeliveryPlan(channel: .messages, partition: budget.partition(clips: clips))

        XCTAssertEqual(plan.travelNote(for: "small"), "sent separately")
        let note = plan.travelNote(for: "big")
        XCTAssertTrue(note.contains("Messages"), note)
        XCTAssertTrue(note.contains("shared separately"), note)
    }

    func testTheBodyNoteNamesEveryClipThatCouldNotRideAlong() {
        let budget = AttachmentBudget.standard(for: .messages)
        let ceiling = try! XCTUnwrap(budget.perFileBytes)
        let clips = [clip("a", bytes: ceiling + 1, seconds: 12),
                     clip("b", bytes: ceiling + 2, seconds: 30)]
        let plan = ClipDeliveryPlan(channel: .messages, partition: budget.partition(clips: clips))
        let note = try! XCTUnwrap(plan.bodyNote(items: clips))
        XCTAssertTrue(note.contains("2 clips"), note)
        XCTAssertTrue(note.contains("12 seconds"), note)
        XCTAssertTrue(note.contains("30 seconds"), note)
    }

    func testThereIsNoBodyNoteWhenEverythingFitted() {
        let clips = [clip("a", bytes: 1_000)]
        let plan = ClipDeliveryPlan(channel: .email,
                                    partition: AttachmentBudget.standard(for: .email)
                                        .partition(clips: clips))
        XCTAssertNil(plan.bodyNote(items: clips))
    }

    /// An export taken for the archive has no channel, so it claims nothing about one.
    func testAnUndecidedPlanStillSaysAClipTravelsSeparately() {
        XCTAssertEqual(ClipDeliveryPlan.undecided.travelNote(for: "anything"), "sent separately")
        XCTAssertNil(ClipDeliveryPlan.undecided.reason(for: "anything"))
        XCTAssertTrue(ClipDeliveryPlan.undecided.isEmpty)
    }

    // MARK: - The endpoint

    /// The unattended route cannot take a file, and says so rather than marking one delivered.
    func testTheEndpointRecordsAClipAsPendingWithAReasonRatherThanLosingIt() {
        guard case .permanent(let reason) = EndpointSyncSink.clipOutcome(carriesFiles: false) else {
            return XCTFail("a sink that cannot carry files must not report a clip delivered")
        }
        XCTAssertTrue(reason.contains("stays on the device"), reason)
        XCTAssertEqual(EndpointSyncSink.clipOutcome(carriesFiles: true), .done)
        XCTAssertFalse(EndpointSyncSink.carriesFiles)
    }

    /// A clip's queued op must never be the kind whose delivered files get evicted under disk
    /// pressure — it belongs to a record the store already refuses to delete.
    func testAClipIsNotQueuedUnderThePrunablePhotoKind() {
        XCTAssertNotEqual(OpKind.clipUpload, OpKind.photoUpload)
    }
}
