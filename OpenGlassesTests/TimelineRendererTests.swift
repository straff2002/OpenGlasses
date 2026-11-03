import XCTest
@testable import OpenGlasses

/// Plan KK P1 — the block the model reads: dated, oldest first, labelled as notes, bounded, and
/// honest about what it is missing.
final class TimelineRendererTests: XCTestCase {

    private typealias F = TimelineFixtures

    private func entry(_ id: String, from start: Double, to end: Double, text: String,
                       tier: TimelineEntry.Tier = .chunk) -> TimelineEntry {
        TimelineEntry(id: id, firstMessageID: "\(id)-first", lastMessageID: "\(id)-last",
                      startedAt: F.minutes(start), endedAt: F.minutes(end), tier: tier, text: text)
    }

    func testNothingToRenderIsNil() {
        let rendered = TimelineRenderer.render(entries: [], coverageHasGaps: true, timeZone: F.utc)
        XCTAssertNil(rendered.text)
        XCTAssertEqual(rendered.renderedCount, 0)
        XCTAssertTrue(rendered.hasGap, "the coverage gap is passed through, so the note stays")
    }

    func testEntriesRenderOldestFirstUnderTheLabelWithTheirTimes() {
        let rendered = TimelineRenderer.render(
            entries: [entry("e2", from: 30, to: 41, text: "Swapped the capacitor."),
                      entry("e1", from: 0, to: 12, text: "Arrived; unit short-cycling.")],
            coverageHasGaps: false, timeZone: F.utc)
        XCTAssertEqual(rendered.text, """
            Earlier in this conversation: notes written as older messages left this request. The \
            saved conversation is unchanged. Lines under "Said word for word:" are the wearer's exact \
            words. Current job state takes precedence over older conversation.

            [Tue 3 Nov 2026, 09:00–09:12]
            Arrived; unit short-cycling.

            [Tue 3 Nov 2026, 09:30–09:41]
            Swapped the capacitor.
            """)
        XCTAssertEqual(rendered.renderedCount, 2)
        XCTAssertEqual(rendered.droppedCount, 0)
        XCTAssertFalse(rendered.hasGap)
    }

    /// P3: P0 found "notes, not a record" made the model distrust its own correct recall results.
    /// The label describes and never instructs; it names recall only when `brain` can be called.
    func testTheLabelNamesRecallOnlyWhenOfferedAndNeverDisownsTheNotes() throws {
        let entries = [entry("e1", from: 0, to: 5, text: "notes")]
        let offered = try XCTUnwrap(TimelineRenderer.render(entries: entries, coverageHasGaps: false,
                                                            timeZone: F.utc, recallOffered: true).text)
        let withheld = try XCTUnwrap(TimelineRenderer.render(entries: entries, coverageHasGaps: false,
                                                             timeZone: F.utc).text)
        XCTAssertTrue(offered.hasPrefix(TimelineRenderer.label(recallOffered: true)))
        XCTAssertTrue(offered.contains("Exact wording can be looked up with brain, action recall."))
        XCTAssertFalse(withheld.contains("brain"))
        for text in [offered, withheld] {
            XCTAssertFalse(text.lowercased().contains("not a record"))
            XCTAssertTrue(text.contains(TimelineDetailCheck.heading), "the restored lines are named")
        }
    }

    func testTheTimeZoneIsTheOneInjected() {
        let auckland = TimeZone(identifier: "Pacific/Auckland")!
        let rendered = TimelineRenderer.render(entries: [entry("e1", from: 0, to: 5, text: "notes")],
                                               coverageHasGaps: false, timeZone: auckland)
        XCTAssertTrue(rendered.text?.contains("[Tue 3 Nov 2026, 22:00–22:05]") == true,
                      rendered.text ?? "")
    }

    func testARangeAcrossMidnightNamesBothDays() {
        let label = TimelineRenderer.DateRangeLabel(timeZone: F.utc)
        XCTAssertEqual(label.label(from: F.minutes(14 * 60 + 50), to: F.minutes(15 * 60 + 10)),
                       "Tue 3 Nov 2026, 23:50 – Wed 4 Nov 2026, 00:10")
        XCTAssertEqual(label.label(from: F.start, to: F.start), "Tue 3 Nov 2026, 09:00")
    }

    func testEntriesBeforeTheFloorAreNeverRenderedAndAreNotAGap() {
        let rendered = TimelineRenderer.render(
            entries: [entry("old", from: 0, to: 10, text: "The previous job's notes."),
                      entry("new", from: 60, to: 70, text: "This job's notes.")],
            floor: F.minutes(60), coverageHasGaps: false, timeZone: F.utc)
        XCTAssertFalse(rendered.text?.contains("previous job") ?? true)
        XCTAssertTrue(rendered.text?.contains("This job's notes.") == true)
        XCTAssertEqual(rendered.droppedCount, 0)
        XCTAssertFalse(rendered.hasGap)
    }

    func testTheCapDropsTheOldestEntriesFirstAndReportsTheGap() {
        let entries = [entry("e1", from: 0, to: 10, text: "first " + String(repeating: "a", count: 2_000)),
                       entry("e2", from: 20, to: 30, text: "second " + String(repeating: "b", count: 2_000)),
                       entry("e3", from: 40, to: 50, text: "third " + String(repeating: "c", count: 2_000))]
        let rendered = TimelineRenderer.render(entries: entries, coverageHasGaps: false, timeZone: F.utc)
        XCTAssertEqual(rendered.droppedCount, 1)
        XCTAssertEqual(rendered.renderedCount, 2)
        XCTAssertTrue(rendered.hasGap, "a dropped entry is a gap: the omission note must stay")
        XCTAssertFalse(rendered.text?.contains("first ") ?? true)
        XCTAssertTrue(rendered.text?.contains("third ") == true)
        XCTAssertLessThanOrEqual(rendered.estimatedTokens, TimelineRenderer.defaultTokenCap)
        XCTAssertEqual(rendered.estimatedTokens, TimelineRenderer.estimatedTokens(rendered.text ?? ""))
    }

    func testAnEntryTooLargeForTheCapOnItsOwnLeavesNothing() {
        let rendered = TimelineRenderer.render(
            entries: [entry("e1", from: 0, to: 10, text: String(repeating: "a", count: 4_000))],
            coverageHasGaps: false, timeZone: F.utc, tokenCap: 500)
        XCTAssertNil(rendered.text)
        XCTAssertEqual(rendered.droppedCount, 1)
        XCTAssertTrue(rendered.hasGap)
    }
}
