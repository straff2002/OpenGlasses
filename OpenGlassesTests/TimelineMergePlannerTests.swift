import XCTest
@testable import OpenGlasses

/// Plan KK P1 — which entries become one, and that a merge never claims a gap.
final class TimelineMergePlannerTests: XCTestCase {

    private typealias F = TimelineFixtures

    /// `count` back-to-back chunks of two exchanges each over a long conversation.
    private func chunks(_ count: Int, tier: TimelineEntry.Tier = .chunk,
                        in messages: [TimelineMessage], from offset: Int = 0) -> [TimelineEntry] {
        (0..<count).map { index in
            let first = offset + index * 4
            return F.entry("\(tier.rawValue)\(index)", messages, first...(first + 3), tier: tier)
        }
    }

    func testNothingIsMergedBelowTheThreshold() {
        let messages = F.conversation(20)
        XCTAssertNil(TimelineMergePlanner.nextMerge(entries: chunks(5, in: messages),
                                                    messageIDs: messages.map(\.id)))
    }

    func testSixChunksMergeTheOldestFourAndKeepTwo() throws {
        let messages = F.conversation(20)
        let entries = chunks(6, in: messages)
        let plan = try XCTUnwrap(TimelineMergePlanner.nextMerge(entries: entries,
                                                                messageIDs: messages.map(\.id)))
        XCTAssertEqual(plan.sourceIDs, ["chunk0", "chunk1", "chunk2", "chunk3"])
        XCTAssertEqual(plan.sourceTier, .chunk)
        XCTAssertEqual(plan.firstMessageID, "u0")
        XCTAssertEqual(plan.lastMessageID, "a7")
        XCTAssertEqual(plan.startedAt, messages[0].timestamp)
        XCTAssertEqual(plan.endedAt, messages[15].timestamp)

        let merged = plan.entry(id: "m0", text: "merged notes")
        XCTAssertEqual(merged.tier, .merged)
        let after = plan.applying(merged, to: entries)
        XCTAssertEqual(after.map(\.id), ["m0", "chunk4", "chunk5"])
    }

    func testEntriesAreOrderedByWhereTheirMessagesSitNotByListOrder() throws {
        let messages = F.conversation(20)
        let plan = try XCTUnwrap(TimelineMergePlanner.nextMerge(
            entries: Array(chunks(6, in: messages).reversed()), messageIDs: messages.map(\.id)))
        XCTAssertEqual(plan.sourceIDs, ["chunk0", "chunk1", "chunk2", "chunk3"])
    }

    /// A merged entry's span claims every message inside it. Merging across a hole would hide the
    /// hole from coverage for good, so the oldest run of four that meets end to start is taken.
    func testAMergeNeverSpansAHole() throws {
        let messages = F.conversation(20)
        var entries = chunks(2, in: messages)                  // u0…a3
        entries += chunks(4, in: messages, from: 12).enumerated().map { index, entry in
            TimelineEntry(id: "late\(index)", firstMessageID: entry.firstMessageID,
                          lastMessageID: entry.lastMessageID, startedAt: entry.startedAt,
                          endedAt: entry.endedAt, tier: .chunk, text: entry.text)
        }                                                      // u6…a13, after a hole at u4…a5
        let plan = try XCTUnwrap(TimelineMergePlanner.nextMerge(entries: entries,
                                                                messageIDs: messages.map(\.id)))
        XCTAssertEqual(plan.sourceIDs, ["late0", "late1", "late2", "late3"])
        XCTAssertEqual(plan.firstMessageID, "u6")
    }

    func testOverlappingChunksStillMerge() throws {
        let messages = F.conversation(20)
        let entries = (0..<6).map { F.entry("c\($0)", messages, ($0 * 3)...($0 * 3 + 4)) }
        let plan = try XCTUnwrap(TimelineMergePlanner.nextMerge(entries: entries,
                                                                messageIDs: messages.map(\.id)))
        XCTAssertEqual(plan.sourceIDs, ["c0", "c1", "c2", "c3"])
        XCTAssertEqual(plan.lastMessageID, messages[13].id)
    }

    func testAnEntryWhoseSpanNoLongerResolvesIsNeverMerged() {
        let messages = F.conversation(20)
        var entries = chunks(6, in: messages)
        entries[2] = TimelineEntry(id: "stale", firstMessageID: "gone", lastMessageID: "a5",
                                   startedAt: F.start, endedAt: F.start, tier: .chunk, text: "notes")
        XCTAssertNil(TimelineMergePlanner.nextMerge(entries: entries, messageIDs: messages.map(\.id)),
                     "five resolvable chunks are under the threshold")
    }

    func testSixMergedEntriesMergeTheOldestFour() throws {
        let messages = F.conversation(20)
        let entries = chunks(6, tier: .merged, in: messages) + chunks(2, in: messages, from: 24)
        let plan = try XCTUnwrap(TimelineMergePlanner.nextMerge(entries: entries,
                                                                messageIDs: messages.map(\.id)))
        XCTAssertEqual(plan.sourceTier, .merged)
        XCTAssertEqual(plan.sourceIDs, ["merged0", "merged1", "merged2", "merged3"])
    }

    func testChunksAreMergedBeforeMergedEntries() throws {
        let messages = F.conversation(40)
        let entries = chunks(6, tier: .merged, in: messages) + chunks(6, in: messages, from: 24)
        let plan = try XCTUnwrap(TimelineMergePlanner.nextMerge(entries: entries,
                                                                messageIDs: messages.map(\.id)))
        XCTAssertEqual(plan.sourceTier, .chunk)
    }
}
