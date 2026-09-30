import SQLite3
import XCTest
@testable import OpenGlasses

/// Plan GB P5 — spend caps (warn at 80%, ask at 100%, opt-in fallback, unpriced is not
/// enforceable) and per-job cost.
final class SpendCapPolicyTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let caps = SpendCapPolicy.Caps(dailyUSD: 10, monthlyUSD: 100, fallBackToCheaperModel: false)

    private func decide(_ today: Double, _ month: Double, caps: SpendCapPolicy.Caps? = nil,
                        pricing: SpendCapPolicy.Pricing = .priced, override: String? = nil) -> SpendCapPolicy.Decision {
        SpendCapPolicy.decide(spentToday: today, spentMonth: month, caps: caps ?? self.caps, pricing: pricing,
                              overrideKey: override, now: now, calendar: calendar)
    }

    func testEachState() {
        XCTAssertEqual(decide(1, 10), .ok)
        XCTAssertEqual(decide(8, 10), .warn(.day, fraction: 0.8))
        XCTAssertEqual(decide(10, 20), .confirmToContinue(.day))
        XCTAssertEqual(decide(1, 100), .confirmToContinue(.month), "the month outranks the day")
        XCTAssertEqual(decide(13.38, 13.38, pricing: .unpriced), .notEnforceable)
        XCTAssertEqual(decide(13.38, 13.38, pricing: .free), .ok)
        XCTAssertEqual(decide(50, 500, caps: .off), .ok)
        var fallback = caps
        fallback.fallBackToCheaperModel = true
        XCTAssertEqual(decide(12, 12, caps: fallback), .fallBackToCheaperModel(.day))
    }

    func testTheHighestWarningWins() {
        XCTAssertEqual(decide(8, 90), .warn(.month, fraction: 0.9))
    }

    func testOverrideCoversTheRestOfTheWindowOnly() {
        let today = SpendCapPolicy.Window.day.key(now: now, calendar: calendar)
        XCTAssertEqual(decide(12, 20, override: today), .ok)
        let yesterday = SpendCapPolicy.Window.day.key(now: now.addingTimeInterval(-86_400), calendar: calendar)
        XCTAssertEqual(decide(12, 20, override: yesterday), .confirmToContinue(.day))
        // Past the day with override, still under 80% of the month: no warning keeps nagging.
        XCTAssertEqual(decide(12, 20, override: today), .ok)
    }

    func testWindowKeys() {
        XCTAssertTrue(SpendCapPolicy.Window.day.key(now: now, calendar: calendar).hasPrefix("day-"))
        XCTAssertTrue(SpendCapPolicy.Window.month.key(now: now, calendar: calendar).hasPrefix("month-"))
        XCTAssertLessThanOrEqual(SpendCapPolicy.Window.month.start(of: now, calendar: calendar),
                                 SpendCapPolicy.Window.day.start(of: now, calendar: calendar))
    }

    // MARK: - The conversation

    func testGateAsksThenAcceptsASpokenConfirmation() {
        var gate = SpendCapGate()
        let first = gate.evaluate(.confirmToContinue(.day), utterance: "what's the static pressure", now: now, calendar: calendar)
        XCTAssertEqual(first, .answer(SpendCapPolicy.confirmationPrompt(.day)))
        XCTAssertTrue(gate.awaitingConfirmation)
        let second = gate.evaluate(.confirmToContinue(.day), utterance: "Continue.", now: now, calendar: calendar)
        XCTAssertEqual(second, .confirmed(.day, reply: SpendCapGate.confirmedReply))
        XCTAssertFalse(gate.awaitingConfirmation)
    }

    func testAConfirmationWithoutAPromptIsNotConsent() {
        var gate = SpendCapGate()
        XCTAssertEqual(gate.evaluate(.confirmToContinue(.month), utterance: "continue", now: now, calendar: calendar),
                       .answer(SpendCapPolicy.confirmationPrompt(.month)))
    }

    func testANewRequestIsNotConsent() {
        var gate = SpendCapGate()
        _ = gate.evaluate(.confirmToContinue(.day), utterance: "hi", now: now, calendar: calendar)
        XCTAssertEqual(gate.evaluate(.confirmToContinue(.day), utterance: "continue with the heat cycle test",
                                     now: now, calendar: calendar),
                       .answer(SpendCapPolicy.confirmationPrompt(.day)))
    }

    func testWarningAndUnpricedNoticeAreSaidOncePerWindow() {
        var gate = SpendCapGate()
        XCTAssertEqual(gate.evaluate(.warn(.day, fraction: 0.85), utterance: "x", now: now, calendar: calendar),
                       .proceedWithNotice(SpendCapPolicy.warningLine(.day, fraction: 0.85)))
        XCTAssertEqual(gate.evaluate(.warn(.day, fraction: 0.9), utterance: "x", now: now, calendar: calendar), .proceed)
        XCTAssertEqual(gate.evaluate(.notEnforceable, utterance: "x", now: now, calendar: calendar),
                       .proceedWithNotice(SpendCapGate.unpricedNotice))
        XCTAssertEqual(gate.evaluate(.notEnforceable, utterance: "x", now: now, calendar: calendar), .proceed)
    }

    func testFallbackUsesACheaperSavedModelOrAsks() {
        var gate = SpendCapGate()
        var cheap = ModelConfig.defaultConfig(for: .openai)
        cheap.model = "gpt-5-mini"
        cheap.name = "Mini"
        let outcome = gate.evaluate(.fallBackToCheaperModel(.day), utterance: "x", now: now, calendar: calendar) { cheap }
        XCTAssertEqual(outcome, .useCheaperModel(cheap, notice: SpendCapPolicy.fallbackLine(.day, modelName: "Mini")))
        XCTAssertEqual(gate.evaluate(.fallBackToCheaperModel(.day), utterance: "x", now: now, calendar: calendar) { nil },
                       .answer(SpendCapPolicy.confirmationPrompt(.day)))
    }

    func testCheaperModelPicksTheCheapestPricedAlternative() {
        var current = ModelConfig.defaultConfig(for: .openai); current.model = "gpt-5.5"
        var mini = ModelConfig.defaultConfig(for: .openai); mini.model = "gpt-5-mini"
        var nano = ModelConfig.defaultConfig(for: .openai); nano.model = "gpt-5-nano"
        var unpriced = ModelConfig.defaultConfig(for: .custom); unpriced.model = "llama-local-thing"
        var dearer = ModelConfig.defaultConfig(for: .openai); dearer.model = "gpt-6-astra"
        XCTAssertEqual(SpendCapPolicy.cheaperModel(than: current, among: [current, mini, nano, unpriced, dearer])?.id, nano.id)
        XCTAssertNil(SpendCapPolicy.cheaperModel(than: nano, among: [current, mini, nano]))
    }

    func testConfirmationPhrases() {
        for yes in ["continue", "Continue anyway.", "go ahead", "Keep going!", "okay, continue"] {
            XCTAssertTrue(SpendCapConfirmation.isConfirmation(yes), yes)
        }
        for no in ["no", "stop", "what's the budget", "continue the procedure", ""] {
            XCTAssertFalse(SpendCapConfirmation.isConfirmation(no), no)
        }
    }

    @MainActor
    func testSpendPricingClassifiesModels() {
        var gpt = ModelConfig.defaultConfig(for: .openai); gpt.model = "gpt-5.5"
        XCTAssertEqual(LLMService.spendPricing(gpt), .priced)
        var odd = ModelConfig.defaultConfig(for: .openai); odd.model = "gpt-5.5-pro"
        XCTAssertEqual(LLMService.spendPricing(odd), .unpriced)
        XCTAssertEqual(LLMService.spendPricing(ModelConfig.defaultConfig(for: .chatgpt)), .free)
        XCTAssertEqual(LLMService.spendPricing(ModelConfig.defaultConfig(for: .local)), .free)
    }

    // MARK: - Per-job cost

    @MainActor
    func testUsageSplitsAcrossTwoJobsInOneAppSession() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).sqlite")
        let tracker = UsageTracker(store: UsageStore(path: url))
        tracker.record(provider: .openai, model: "gpt-5.5", tokensIn: 20_000, tokensOut: 100,
                       cacheReadTokens: 10_000, fieldSessionId: "job-1010")
        tracker.record(provider: .openai, model: "gpt-5.5", tokensIn: 20_000, tokensOut: 100,
                       cacheReadTokens: 10_000, fieldSessionId: "job-1011")
        tracker.record(provider: .openai, model: "gpt-5.5", tokensIn: 1_000, tokensOut: 50,
                       fieldSessionId: "job-1011")
        tracker.record(provider: .openai, model: "gpt-5.5-pro", tokensIn: 1_000, tokensOut: 50,
                       fieldSessionId: "job-1011")
        tracker.record(provider: .openai, model: "gpt-5.5", tokensIn: 500, tokensOut: 5)

        let first = tracker.jobUsage(fieldSessionId: "job-1010")
        XCTAssertEqual(first.requests, 1)
        XCTAssertEqual(first.cachedTokens, 10_000)
        XCTAssertEqual(try XCTUnwrap(first.estimatedUSD), 20_000 * 5e-6 + 10_000 * 0.5e-6 + 100 * 30e-6, accuracy: 1e-9)

        let second = tracker.jobUsage(fieldSessionId: "job-1011")
        XCTAssertEqual(second.requests, 3)
        XCTAssertEqual(second.inputTokens, 22_000)
        XCTAssertEqual(second.unpricedRequests, 1)
        XCTAssertNotNil(second.estimatedUSD)

        XCTAssertTrue(tracker.jobUsage(fieldSessionId: "job-none").isEmpty)
        let spend = tracker.spend()
        XCTAssertGreaterThan(spend.today, 0)
    }

    @MainActor
    func testLegacyUsageRowDecodesWithoutAJob() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-legacy-\(UUID()).sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
        CREATE TABLE usage (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, provider TEXT NOT NULL,
            model TEXT NOT NULL, tokens_in INTEGER NOT NULL, tokens_out INTEGER NOT NULL,
            cost_usd REAL, at REAL NOT NULL,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0);
        INSERT INTO usage (id, session_id, provider, model, tokens_in, tokens_out, cost_usd, at)
            VALUES ('old', 's', 'openai', 'gpt-4o', 10, 5, 0.001, \(Date().timeIntervalSince1970));
        """, nil, nil, nil)
        sqlite3_close(db)

        let store = UsageStore(path: url)
        let row = try XCTUnwrap(store.records(since: .distantPast).first)
        XCTAssertEqual(row.id, "old")
        XCTAssertNil(row.fieldSessionId)
        XCTAssertEqual(row.costUSD, 0.001)
    }

    func testJobUsageSummaryRoundTrips() throws {
        let summary = JobUsageSummary(requests: 3, inputTokens: 10, cachedTokens: 4, outputTokens: 2,
                                      estimatedUSD: nil, unpricedRequests: 3)
        XCTAssertEqual(try JSONDecoder().decode(JobUsageSummary.self, from: JSONEncoder().encode(summary)), summary)
    }
}
