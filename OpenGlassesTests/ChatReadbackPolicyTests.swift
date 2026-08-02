import XCTest
@testable import OpenGlasses

/// Tests for the pure chat-readback taste layer (Plan CI P1): every rule as data — filters,
/// dedup, rate cap, bounded queue, mention priority, burst rendering, and the TTS-busy /
/// realtime-session gates.
final class ChatReadbackPolicyTests: XCTestCase {

    private func msg(_ text: String, user: String = "Sam", withoutEmotes: String? = nil) -> ChatMessage {
        ChatMessage(user: user, login: user.lowercased(), text: text, badges: [],
                    isAction: false, textWithoutEmotes: withoutEmotes ?? text)
    }

    private func makePolicy(_ tweak: (inout ChatReadbackRules) -> Void = { _ in }) -> ChatReadbackPolicy {
        var rules = ChatReadbackRules()
        rules.streamerHandle = "glassescaster"
        tweak(&rules)
        return ChatReadbackPolicy(rules: rules)
    }

    // MARK: - Filters

    func testPlainMessageQueuesAndSpeaks() {
        var p = makePolicy()
        XCTAssertTrue(p.ingest(msg("great view"), at: 0))
        let item = p.nextItem(at: 1, ttsBusy: false, realtimeSessionActive: false)
        XCTAssertEqual(item, SpokenChatItem(user: "Sam", text: "Sam says: great view", isMention: false))
    }

    func testCommandPrefixSkipped() {
        var p = makePolicy()
        XCTAssertFalse(p.ingest(msg("!so @friend"), at: 0))
        XCTAssertFalse(p.ingest(msg("!uptime"), at: 0))
    }

    func testEmoteOnlyMessageSkipped() {
        var p = makePolicy()
        XCTAssertFalse(p.ingest(msg("Kappa Kappa", withoutEmotes: ""), at: 0))
    }

    func testURLsStrippedAndURLOnlyMessageSkipped() {
        var p = makePolicy()
        XCTAssertTrue(p.ingest(msg("look at https://example.com/x?y=1 now"), at: 0))
        XCTAssertEqual(p.nextItem(at: 0, ttsBusy: false, realtimeSessionActive: false)?.text,
                       "Sam says: look at now")
        XCTAssertFalse(p.ingest(msg("https://spam.example www.also.spam"), at: 1))
    }

    func testLongTextCappedForSpeech() {
        var p = makePolicy()
        XCTAssertTrue(p.ingest(msg(String(repeating: "a", count: 500)), at: 0))
        let spoken = p.nextItem(at: 0, ttsBusy: false, realtimeSessionActive: false)!
        XCTAssertLessThanOrEqual(spoken.text.count, 200 + "Sam says: ".count)
    }

    // MARK: - Dedup

    func testQueuedDuplicateMergesWithTimesSuffix() {
        var p = makePolicy()
        XCTAssertTrue(p.ingest(msg("LOL"), at: 0))
        XCTAssertTrue(p.ingest(msg("lol", user: "Ana"), at: 1))    // case-insensitive merge
        XCTAssertTrue(p.ingest(msg("LOL", user: "Ben"), at: 2))
        XCTAssertEqual(p.nextItem(at: 3, ttsBusy: false, realtimeSessionActive: false)?.text,
                       "Sam says: LOL — times 3")
        XCTAssertNil(p.nextItem(at: 4, ttsBusy: false, realtimeSessionActive: false))   // merged, not queued thrice
    }

    func testSpokenDuplicateInsideWindowDropped() {
        var p = makePolicy()
        XCTAssertTrue(p.ingest(msg("hello"), at: 0))
        _ = p.nextItem(at: 0, ttsBusy: false, realtimeSessionActive: false)
        XCTAssertFalse(p.ingest(msg("hello", user: "Ana"), at: 10))   // within 30 s window
        XCTAssertTrue(p.ingest(msg("hello", user: "Ana"), at: 45))    // window expired
    }

    // MARK: - Rate cap + queue bound

    func testRateCapPerRollingMinute() {
        var p = makePolicy { $0.rateCapPerMinute = 2 }
        for (i, t) in ["a", "b", "c"].enumerated() { p.ingest(msg(t, user: "U\(i)"), at: Double(i)) }
        XCTAssertNotNil(p.nextItem(at: 10, ttsBusy: false, realtimeSessionActive: false))
        XCTAssertNotNil(p.nextItem(at: 20, ttsBusy: false, realtimeSessionActive: false))
        XCTAssertNil(p.nextItem(at: 30, ttsBusy: false, realtimeSessionActive: false))     // cap spent
        XCTAssertNotNil(p.nextItem(at: 71, ttsBusy: false, realtimeSessionActive: false))  // window rolled
    }

    func testQueueDropsOldestNonMentionAtCap() {
        var p = makePolicy { $0.queueCap = 2 }
        p.ingest(msg("first", user: "A"), at: 0)
        p.ingest(msg("hey @glassescaster", user: "B"), at: 1)
        p.ingest(msg("third", user: "C"), at: 2)   // over cap → "first" (oldest non-mention) drops
        XCTAssertEqual(p.queue.map(\.text), ["hey @glassescaster", "third"])
    }

    // MARK: - Mentions

    func testMentionJumpsQueue() {
        var p = makePolicy()
        p.ingest(msg("one", user: "A"), at: 0)
        p.ingest(msg("two", user: "B"), at: 1)
        p.ingest(msg("yo @GlassesCaster look left", user: "C"), at: 2)
        let first = p.nextItem(at: 3, ttsBusy: false, realtimeSessionActive: false)
        XCTAssertEqual(first?.user, "C")
        XCTAssertEqual(first?.isMention, true)
    }

    func testMentionMatchesBareHandleButNotSubstring() {
        XCTAssertTrue(ChatReadbackPolicy.mentions(handle: "glassescaster", in: "hi glassescaster!"))
        XCTAssertTrue(ChatReadbackPolicy.mentions(handle: "@glassescaster", in: "@GLASSESCASTER hi"))
        XCTAssertFalse(ChatReadbackPolicy.mentions(handle: "glassescaster", in: "glassescaster2 is fake"))
        XCTAssertFalse(ChatReadbackPolicy.mentions(handle: "", in: "anything"))
    }

    func testMentionsOnlyModeFiltersTheRest() {
        var p = makePolicy { $0.mentionsOnly = true }
        XCTAssertFalse(p.ingest(msg("nice stream"), at: 0))
        XCTAssertTrue(p.ingest(msg("@glassescaster where are you?"), at: 1))
    }

    // MARK: - Burst rendering

    func testNameSpokenOncePerBurst() {
        var p = makePolicy()
        p.ingest(msg("great view"), at: 0)
        p.ingest(msg("where is this?"), at: 1)
        XCTAssertEqual(p.nextItem(at: 2, ttsBusy: false, realtimeSessionActive: false)?.text,
                       "Sam says: great view")
        XCTAssertEqual(p.nextItem(at: 12, ttsBusy: false, realtimeSessionActive: false)?.text,
                       "And: where is this?")
    }

    func testBurstBreaksAfterWindowOrOtherSpeaker() {
        var p = makePolicy()
        p.ingest(msg("one"), at: 0)
        p.ingest(msg("hi", user: "Ana"), at: 1)
        p.ingest(msg("two"), at: 2)
        XCTAssertEqual(p.nextItem(at: 3, ttsBusy: false, realtimeSessionActive: false)?.text,
                       "Sam says: one")
        XCTAssertEqual(p.nextItem(at: 4, ttsBusy: false, realtimeSessionActive: false)?.text,
                       "Ana says: hi")
        XCTAssertEqual(p.nextItem(at: 5, ttsBusy: false, realtimeSessionActive: false)?.text,
                       "Sam says: two")   // interleaved speaker broke the burst
    }

    // MARK: - Gates

    func testTTSBusyHoldsQueue() {
        var p = makePolicy()
        p.ingest(msg("waiting"), at: 0)
        XCTAssertNil(p.nextItem(at: 1, ttsBusy: true, realtimeSessionActive: false))
        XCTAssertNotNil(p.nextItem(at: 2, ttsBusy: false, realtimeSessionActive: false))
    }

    func testRealtimeSessionSuppressesEntirely() {
        var p = makePolicy()
        p.ingest(msg("before session"), at: 0)
        XCTAssertNil(p.nextItem(at: 1, ttsBusy: false, realtimeSessionActive: true))
        // The queue flushed — stale chat must not replay when the session ends…
        XCTAssertNil(p.nextItem(at: 2, ttsBusy: false, realtimeSessionActive: false))
        // …and nothing accumulates while one is live.
        XCTAssertFalse(p.ingest(msg("during session"), at: 3, realtimeSessionActive: true))
    }

    func testResetClearsEverything() {
        var p = makePolicy()
        p.ingest(msg("pending"), at: 0)
        p.reset()
        XCTAssertNil(p.nextItem(at: 1, ttsBusy: false, realtimeSessionActive: false))
    }
}
