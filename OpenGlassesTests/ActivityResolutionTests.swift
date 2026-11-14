import XCTest
@testable import OpenGlasses

/// Plan LE P0 §3 — held trail entries resolve. Old entries read exactly as before; a held entry
/// the wearer has since answered is no longer "waiting on you" anywhere the trail is spoken.
final class ActivityResolutionTests: XCTestCase {
    private typealias F = GoalActivityFixture

    private func decode(_ json: String) throws -> [ActivityEntry] {
        try RecordJSONCodec.decoder().decode([ActivityEntry].self, from: Data(json.utf8))
    }

    private func held(_ n: Int, at: Date, title: String = "Your OK to use the send message tool") -> ActivityEntry {
        F.entry(n, at: at, title: title, kind: .held, tool: "send_message", outcome: .waitingOnYou,
                authorisation: .heldForYou)
    }

    // MARK: On disk

    func testEntriesOfTheOldShapeDecodeUnchanged() throws {
        let entries = try decode(ActivityEntryCodecTests.fixture)
        XCTAssertEqual(entries.count, 7)
        XCTAssertTrue(entries.allSatisfy { $0.resolvedAt == nil && $0.resolution == nil })
        let held = try XCTUnwrap(entries.first { $0.kind == .held })
        XCTAssertTrue(held.isAwaitingWearer, "an old held entry is still waiting, as it always was")
        XCTAssertEqual(entries.filter(\.isAwaitingWearer).map(\.kind), [.held])
    }

    func testAnUnresolvedEntryWritesTheOldShape() throws {
        let entries = try decode(ActivityEntryCodecTests.fixture)
        let json = String(decoding: try RecordJSONCodec.encoder().encode(entries), as: UTF8.self)
        XCTAssertFalse(json.contains("resolvedAt"))
        XCTAssertFalse(json.contains("resolution"))
    }

    func testAResolutionRoundTripsWithAStableCode() throws {
        let answered = held(1, at: F.date(19, 9)).resolved(.approved, at: F.date(19, 9, 30))
        let data = try RecordJSONCodec.encoder().encode([answered])
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""resolution":"approved""#), json)
        XCTAssertTrue(json.contains(#""resolvedAt":"#), json)
        let back = try RecordJSONCodec.decoder().decode([ActivityEntry].self, from: data)
        XCTAssertEqual(back, [answered])
        XCTAssertFalse(back[0].isAwaitingWearer)
        XCTAssertEqual(back[0].outcome, .waitingOnYou, "the outcome keeps what was true when it was written")
        XCTAssertEqual(ActivityResolution.allCases.map(\.rawValue), ["approved", "declined", "expired"])
    }

    func testAResolutionFromALaterVersionStillReadsAsAnswered() throws {
        let json = #"""
        [{"id": "00000000-0000-0000-0000-000000000505", "at": "2026-10-18T21:10:00Z", "kind": "held",
          "title": "A message to the office", "tool": "send_message", "authorisation": "held_for_you",
          "origin": "agent", "outcome": "waiting_on_you", "resolvedAt": "2026-10-18T21:20:00Z",
          "resolution": "withdrawn"}]
        """#
        let entries = try decode(json)
        XCTAssertEqual(entries.count, 1, "an unknown resolution never fails the trail")
        XCTAssertNil(entries[0].resolution)
        XCTAssertFalse(entries[0].isAwaitingWearer)
    }

    // MARK: Spoken

    func testASummaryDoesNotSayAnAnsweredEntryIsWaiting() {
        let phraser = ActivityPhraser(now: F.now, timeZone: F.auckland)
        let answered = held(1, at: F.date(19, 9)).resolved(.approved, at: F.date(19, 9, 30))
        let said = phraser.summary(of: [answered], window: .today)
        XCTAssertEqual(said, "Today I held one thing for you. Your OK to use the send message tool: you said yes. "
                       + "Nothing is waiting on you.")

        let waiting = held(2, at: F.date(19, 9, 45), title: "Your OK to use the reminder tool")
        XCTAssertTrue(phraser.summary(of: [answered, waiting], window: .today)
            .hasSuffix("One thing is waiting on you: your OK to use the reminder tool."))
    }

    func testWhatsNextIgnoresAnsweredEntries() {
        let phraser = ActivityPhraser(now: F.now, timeZone: F.auckland)
        let declined = held(1, at: F.date(19, 9)).resolved(.declined, at: F.date(19, 9, 10))
        XCTAssertEqual(phraser.whatsNext(goals: [], scheduled: [], entries: [declined]),
                       "Nothing's coming up, and nothing is waiting on you.")
    }

    @MainActor
    func testTheActivityToolsNextReadsOnlyUnresolvedHeldEntries() async throws {
        let directory = F.workspace("ActivityResolutionTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let trail = ActivityStore(directory: directory, clock: { F.now }, hipaaMode: { false },
                                  hipaaRetentionDays: { nil })
        let goals = GoalStore(directory: directory, clock: { F.now }, hipaaRetentionDays: { nil })
        trail.append(held(1, at: F.date(19, 8)).resolved(.approved, at: F.date(19, 8, 30)))
        trail.append(held(2, at: F.date(19, 9), title: "Your OK to use the reminder tool"))
        let tool = ActivityTool(activity: { trail }, goals: { goals })
        tool.scheduledTasks = { [] }
        tool.clock = { F.now }
        tool.timeZone = { F.auckland }

        let said = try await tool.execute(args: ["action": "next"])
        XCTAssertEqual(said, "Nothing else is coming up. One thing is waiting on you: your OK to use the reminder tool.")
    }
}
