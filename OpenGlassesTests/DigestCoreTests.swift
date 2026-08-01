import XCTest
@testable import OpenGlasses

/// Plan BZ — the deterministic digest core: shared priority semantics, the ranking ladder,
/// dedup, staleness/retirement, composition, and the line builder's fallback + rewrite clamp.
final class DigestCoreTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func item(source: DigestSource = .agent, title: String = "Item",
                      body: String = "", age: TimeInterval = 60,
                      priority: NotificationPriority = .medium, threadKey: String? = nil,
                      eventIn: TimeInterval? = nil, awaitingReply: Bool = false,
                      seenCount: Int = 0) -> DigestItem {
        DigestItem(source: source, title: title, rawBody: body,
                   createdAt: now.addingTimeInterval(-age), priority: priority,
                   threadKey: threadKey, eventDate: eventIn.map { now.addingTimeInterval($0) },
                   awaitingReply: awaitingReply, seenCount: seenCount)
    }

    // MARK: - Shared priority

    func testPriorityOrderingAndStaleness() {
        XCTAssertTrue(NotificationPriority.low < .medium)
        XCTAssertTrue(NotificationPriority.medium < .high)
        // The exact numbers AgentNotificationQueue shipped with.
        XCTAssertFalse(NotificationPriority.low.isStale(age: 1800))
        XCTAssertTrue(NotificationPriority.low.isStale(age: 1801))
        XCTAssertFalse(NotificationPriority.medium.isStale(age: 7200))
        XCTAssertTrue(NotificationPriority.medium.isStale(age: 7201))
        XCTAssertFalse(NotificationPriority.high.isStale(age: 1_000_000))
    }

    // MARK: - Ranking ladder

    func testTierLadder() {
        XCTAssertEqual(DigestRanker.tier(of: item(priority: .high), now: now), .urgent)
        XCTAssertEqual(DigestRanker.tier(of: item(source: .calendar, eventIn: 8 * 60), now: now), .timeSensitive)
        XCTAssertEqual(DigestRanker.tier(of: item(source: .geofence), now: now), .timeSensitive)
        XCTAssertEqual(DigestRanker.tier(of: item(awaitingReply: true), now: now), .actionable)
        XCTAssertEqual(DigestRanker.tier(of: item(priority: .medium), now: now), .informational)
        XCTAssertEqual(DigestRanker.tier(of: item(priority: .low), now: now), .routine)
    }

    func testDistantEventIsNotTimeSensitive() {
        let distant = item(source: .calendar, eventIn: 3600)
        XCTAssertEqual(DigestRanker.tier(of: distant, now: now), .informational)
    }

    func testRankOrdersAcrossLadderThenRecency() {
        let routine = item(title: "routine", age: 10, priority: .low)
        let urgent = item(title: "urgent", age: 500, priority: .high)
        let imminent = item(source: .calendar, title: "standup", age: 300, eventIn: 5 * 60)
        let actionableOld = item(title: "reply-old", age: 400, awaitingReply: true)
        let actionableNew = item(title: "reply-new", age: 100, awaitingReply: true)

        let ranked = DigestRanker.ranked([routine, actionableOld, imminent, urgent, actionableNew], now: now)
        XCTAssertEqual(ranked.map(\.title), ["urgent", "standup", "reply-new", "reply-old", "routine"])
    }

    // MARK: - Dedup

    func testThreadKeyCollapsesToLatest() {
        let older = item(title: "arrived", age: 500, threadKey: "geo:home")
        let newer = item(title: "left", age: 10, threadKey: "geo:home")
        let out = DigestDeduper.deduped([older, newer])
        XCTAssertEqual(out.map(\.title), ["left"])
    }

    func testNearDuplicateBodiesCollapseWithinWindow() {
        let a = item(source: .proactive, title: "Standup starts in 10 minutes.", age: 300)
        let b = item(source: .proactive, title: "Standup starts in 10 minutes", age: 100)
        XCTAssertEqual(DigestDeduper.deduped([a, b]).count, 1)
    }

    func testSameBodyDifferentSourceSurvives() {
        let a = item(source: .proactive, title: "Front door", age: 100)
        let b = item(source: .geofence, title: "Front door", age: 100)
        XCTAssertEqual(DigestDeduper.deduped([a, b]).count, 2)
    }

    func testSameBodyOutsideWindowSurvives() {
        let a = item(source: .proactive, title: "Hourly check", age: 700)
        let b = item(source: .proactive, title: "Hourly check", age: 10)
        XCTAssertEqual(DigestDeduper.deduped([a, b]).count, 2)
    }

    // MARK: - Staleness / retirement

    func testRetirementRules() {
        XCTAssertTrue(DigestStaleness.isRetired(item(age: 7300, priority: .medium), now: now))
        XCTAssertFalse(DigestStaleness.isRetired(item(age: 7300, priority: .high), now: now))
        XCTAssertTrue(DigestStaleness.isRetired(item(seenCount: 3), now: now))
        XCTAssertFalse(DigestStaleness.isRetired(item(seenCount: 2), now: now))
        // An event underway for >5 min is over as news — even at high priority.
        XCTAssertTrue(DigestStaleness.isRetired(item(priority: .high, eventIn: -400), now: now))
        XCTAssertFalse(DigestStaleness.isRetired(item(priority: .high, eventIn: -200), now: now))
    }

    // MARK: - Composition

    func testComposeDedupesDropsRetiredRanksAndCaps() {
        let urgent = item(title: "urgent", priority: .high)
        let stale = item(title: "stale", age: 7300, priority: .medium)
        let dupA = item(title: "dup", age: 200, threadKey: "t")
        let dupB = item(title: "dup latest", age: 20, threadKey: "t")
        let seen = item(title: "seen out", seenCount: 5)
        let info = item(title: "info", priority: .medium)
        let low = item(title: "low", priority: .low)

        let digest = DigestComposer.compose([urgent, stale, dupA, dupB, seen, info, low],
                                            now: now, topN: 3)
        XCTAssertEqual(digest.items.map(\.title).first, "urgent")
        XCTAssertEqual(digest.items.count, 3)
        XCTAssertEqual(digest.overflowCount, 1)   // 4 live after dedup/retire, top-3 shown
        XCTAssertFalse(digest.items.contains { $0.title == "stale" || $0.title == "seen out" })
    }

    func testEmptyComposeIsEmpty() {
        XCTAssertTrue(DigestComposer.compose([], now: now).isEmpty)
    }

    // MARK: - Line builder

    func testFallbackLineFormatting() {
        let calendar = item(source: .calendar, title: "Standup", eventIn: 8 * 60)
        XCTAssertEqual(DigestLineBuilder.fallbackLine(for: calendar, now: now), "[Calendar] Standup in 8 min")
        let geofence = item(source: .geofence, title: "Left home")
        XCTAssertEqual(DigestLineBuilder.fallbackLine(for: geofence, now: now), "[Location] Left home")
    }

    func testRelativePhraseBoundaries() {
        XCTAssertEqual(DigestLineBuilder.relativePhrase(from: now, to: now.addingTimeInterval(30)), "now")
        XCTAssertEqual(DigestLineBuilder.relativePhrase(from: now, to: now.addingTimeInterval(8 * 60)), "in 8 min")
        XCTAssertEqual(DigestLineBuilder.relativePhrase(from: now, to: now.addingTimeInterval(2 * 3600)), "in 2 h")
        XCTAssertEqual(DigestLineBuilder.relativePhrase(from: now, to: now.addingTimeInterval(-300)), "(started)")
    }

    func testOverlongFallbackLineIsClamped() {
        let long = item(title: String(repeating: "a", count: 100))
        let line = DigestLineBuilder.fallbackLine(for: long, now: now)
        XCTAssertLessThanOrEqual(line.count, DigestLineBuilder.maxLineLength)
        XCTAssertTrue(line.hasSuffix("…"))
    }

    func testRewriteClampFallsBackOnBadLines() {
        let fallback = "[Agent] Result ready"
        XCTAssertEqual(DigestLineBuilder.clampRewrite(nil, fallback: fallback), fallback)
        XCTAssertEqual(DigestLineBuilder.clampRewrite("   ", fallback: fallback), fallback)
        XCTAssertEqual(DigestLineBuilder.clampRewrite("bad\u{07}line", fallback: fallback), fallback)
        XCTAssertEqual(DigestLineBuilder.clampRewrite(String(repeating: "x", count: 60), fallback: fallback), fallback)
        XCTAssertEqual(DigestLineBuilder.clampRewrite("Reply to Sam", fallback: fallback), "Reply to Sam")
    }

    func testWrongLineCountFallsBackWholesale() {
        let digest = DigestComposer.compose([item(title: "one"), item(title: "two", age: 30)], now: now)
        let lines = DigestLineBuilder.lines(for: digest, rewritten: ["only one line"], now: now)
        XCTAssertEqual(lines, digest.items.map { DigestLineBuilder.fallbackLine(for: $0, now: now) })
    }

    func testSpokenDigestStripsTagsAndAddsOverflow() {
        let spoken = DigestLineBuilder.spokenDigest(
            lines: ["[Calendar] Standup in 8 min", "[Agent] Result ready"], overflowCount: 2)
        XCTAssertEqual(spoken, "Standup in 8 min. Result ready. And 2 more.")
        XCTAssertNil(DigestLineBuilder.spokenDigest(lines: [], overflowCount: 3))
    }

    // MARK: - Voice + gates

    func testBriefingVoiceCommandParsing() {
        for phrase in ["what's new", "What's new?", "catch me up", "briefing", "anything for me",
                       "ok what's new"] {
            XCTAssertEqual(HUDVoiceCommand.parse(phrase), .briefing, phrase)
        }
        // Conversational mentions must NOT fire — strict whole-phrase discipline.
        for phrase in ["what's new in swift 6", "tell me what's new with you", "the briefing was long"] {
            XCTAssertNotEqual(HUDVoiceCommand.parse(phrase), .briefing, phrase)
        }
    }

    func testRewriteGateSkipsOfflineAndReserve() {
        XCTAssertTrue(NotificationDigestService.shouldRewrite(posture: .normal, offline: false))
        XCTAssertTrue(NotificationDigestService.shouldRewrite(posture: .conserve, offline: false))
        XCTAssertFalse(NotificationDigestService.shouldRewrite(posture: .reserve, offline: false))
        XCTAssertFalse(NotificationDigestService.shouldRewrite(posture: .normal, offline: true))
    }

    @MainActor
    func testGlanceScreenShape() {
        var dismissed = false
        let screen = NotificationDigestService.glanceScreen(
            lines: ["[Calendar] Standup in 8 min", "[Agent] Result ready"],
            overflowCount: 2) { dismissed = true }
        XCTAssertEqual(screen.title, "What's new")
        XCTAssertEqual(screen.lines.count, 3)   // 2 items + "+2 more"
        XCTAssertEqual(screen.lines.last?.text, "+2 more")
        XCTAssertEqual(screen.items.map(\.id), ["dismiss"])
        screen.items[0].action()
        XCTAssertTrue(dismissed)
    }
}
