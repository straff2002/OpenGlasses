import XCTest
@testable import OpenGlasses

/// Plan KK P2 — the pure parts of the summary pass: the gate and its named reasons, the spend-cap
/// reading, the backoff, the user-turn count the coverage depends on, and the job floor's date.
final class TimelinePassPolicyTests: XCTestCase {

    private typealias Policy = TimelinePassPolicy

    private func conditions(enabled: Bool = true, hipaa: Bool = false,
                            provider: LLMProvider? = .anthropic, reading: Bool = true,
                            writable: Bool = true, active: Bool = true, running: Bool = false,
                            backingOff: Bool = false, atCap: Bool = false) -> Policy.Conditions {
        Policy.Conditions(enabled: enabled, hipaaMode: hipaa, provider: provider,
                          hasRequestReading: reading, storeWritable: writable, threadIsActive: active,
                          passRunning: running, backingOff: backingOff, atSpendCap: atCap)
    }

    // MARK: - The setting

    /// Owner decision 1: on for everyone, with a setting to turn it off.
    @MainActor
    func testTheSettingIsOnByDefault() {
        let key = "conversationTimelineEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(Config.conversationTimelineEnabled)
        Config.setConversationTimelineEnabled(false)
        XCTAssertFalse(Config.conversationTimelineEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
    }

    // MARK: - The gate

    func testEveryConditionHasItsOwnReason() {
        let cases: [(Policy.Conditions, Policy.Outcome)] = [
            (conditions(), .run),
            (conditions(enabled: false), .skip(.settingOff)),
            (conditions(hipaa: true), .skip(.hipaaMode)),
            (conditions(provider: nil), .skip(.noModel)),
            (conditions(provider: .local), .skip(.onDeviceModel)),
            (conditions(provider: .appleOnDevice), .skip(.onDeviceModel)),
            (conditions(reading: false), .skip(.noRequestReading)),
            (conditions(writable: false), .skip(.storeUnavailable)),
            (conditions(active: false), .skip(.threadNotActive)),
            (conditions(running: true), .skip(.passRunning)),
            (conditions(backingOff: true), .skip(.backingOff)),
            (conditions(atCap: true), .skip(.spendCap)),
        ]
        for (index, (input, expected)) in cases.enumerated() {
            XCTAssertEqual(Policy.decide(input), expected, "case \(index)")
        }
    }

    func testTheWearersChoicesComeFirst() {
        // Off and HIPAA name themselves even when everything else is wrong too.
        XCTAssertEqual(Policy.decide(conditions(enabled: false, hipaa: true, provider: nil, writable: false)),
                       .skip(.settingOff))
        XCTAssertEqual(Policy.decide(conditions(hipaa: true, provider: .local, atCap: true)),
                       .skip(.hipaaMode))
    }

    func testEveryCloudProviderRuns() {
        for provider in LLMProvider.allCases where provider != .local && provider != .appleOnDevice {
            XCTAssertEqual(Policy.decide(conditions(provider: provider)), .run, provider.rawValue)
        }
    }

    func testOnlyAPassThatWantedToRunAndCouldNotIsLogged() {
        let quiet: [Policy.SkipReason] = [.settingOff, .hipaaMode, .noModel, .onDeviceModel,
                                          .noRequestReading, .nothingEligible]
        let logged: [Policy.SkipReason] = [.storeUnavailable, .threadNotActive, .passRunning,
                                           .backingOff, .spendCap]
        XCTAssertTrue(quiet.allSatisfy { !$0.isWorthLogging })
        XCTAssertTrue(logged.allSatisfy(\.isWorthLogging))
    }

    // MARK: - Spend caps

    func testAReachedCapStopsThePassAndAWarningDoesNot() {
        XCTAssertTrue(Policy.isAtSpendCap(.confirmToContinue(.day)))
        XCTAssertTrue(Policy.isAtSpendCap(.fallBackToCheaperModel(.month)),
                      "never moved to a cheaper model: that would be a new destination")
        XCTAssertFalse(Policy.isAtSpendCap(.ok))
        XCTAssertFalse(Policy.isAtSpendCap(.warn(.day, fraction: 0.9)))
        XCTAssertFalse(Policy.isAtSpendCap(.notEnforceable))
    }

    // MARK: - Backoff

    func testBackoffDoublesAndASuccessClearsIt() {
        var backoff = TimelinePassBackoff()
        XCTAssertFalse(backoff.shouldSkip())

        backoff.recordFailure()
        XCTAssertEqual(backoff.passesToSkip, 1)
        XCTAssertTrue(backoff.shouldSkip())
        XCTAssertFalse(backoff.shouldSkip(), "one skipped, then it tries again")

        backoff.recordFailure()
        XCTAssertEqual(backoff.passesToSkip, 2)
        backoff.recordFailure()
        XCTAssertEqual(backoff.passesToSkip, 4)
        for _ in 0..<10 { backoff.recordFailure() }
        XCTAssertEqual(backoff.passesToSkip, TimelinePassBackoff.maximumSkip)

        backoff.recordSuccess()
        XCTAssertEqual(backoff, TimelinePassBackoff())
    }

    // MARK: - Counting the wearer's turns

    func testOnlyTheWearersOwnTurnsCount() {
        var history: [[String: Any]] = []
        history.append(["role": "user", "content": "[Prior conversation context]\nearlier notes"])
        history.append(["role": "user", "content": "the unit is short-cycling"])
        history.append(["role": "assistant", "content": "Check the filter first."])
        history.append(["role": "user", "content": "[SYSTEM: Memory Review — automated check]"])
        history.append(["role": "user", "content": "what's the pressure spec?"])
        let toolCall: [String: Any] = ["type": "tool_use", "id": "t1", "name": "lookup"]
        history.append(["role": "assistant", "content": [toolCall]])
        let toolResult: [String: Any] = ["type": "tool_result", "tool_use_id": "t1", "content": "52 psi"]
        history.append(["role": "user", "content": [toolResult]])
        history.append(["role": "tool", "tool_call_id": "t2", "content": "result"])
        history.append(["role": "function", "parts": [["text": "result"]]])
        history.append(["role": "user", "content": StallReplyPolicy.nudge])
        history.append(["role": "user", "content": StallReplyPolicy.silenceNudge])
        history.append(["role": "user", "content": "   "])
        history.append(["role": "assistant", "content": "It is 52 psi."])
        history.append(["role": "user", "content": "thanks"])

        XCTAssertEqual(TimelineRequestReading.realUserTurns(in: history), 3)
    }

    func testAPhotoTurnIsNotCountedSoItCanOnlyOverlap() {
        let photo: [[String: Any]] = [["type": "image", "source": ["data": "…"]], ["type": "text", "text": "what's this?"]]
        let history: [[String: Any]] = [["role": "user", "content": photo]]
        XCTAssertEqual(TimelineRequestReading.realUserTurns(in: history), 0,
                       "counting low reads it as gone: summarised while still held, never a gap")
    }

    // MARK: - The job floor's date

    func testTheFloorDateIsTheTurnThatSetIt() {
        let early = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        var floor = JobHistoryFloor()
        XCTAssertNil(floor.floorDate)

        floor.turnStarted(at: 4, sessionId: "job-1", now: early)
        XCTAssertEqual(floor.floor, 4)
        XCTAssertEqual(floor.floorDate, early)

        floor.turnStarted(at: 8, sessionId: "job-1", now: later)
        XCTAssertEqual(floor.floorDate, early, "the same job does not move it")

        floor.turnFinished(startedAt: 8, sessionId: "job-2", turnStartedAt: later)
        XCTAssertEqual(floor.floor, 8)
        XCTAssertEqual(floor.floorDate, later, "a spoken start dates from the turn that said it")

        floor.historyCompacted(before: 12, after: 3, insertedSummary: 1)
        XCTAssertEqual(floor.floor, 0)
        XCTAssertNil(floor.floorDate, "a summary mixing both sides leaves no floor")

        floor.turnStarted(at: 0, sessionId: "job-3", now: early)
        floor.historyCompacted(before: 12, after: 3, insertedSummary: 1)
        XCTAssertEqual(floor.floorDate, early, "a floor at the start has nothing before it to mix in")

        floor.historyReplaced(sessionId: "job-3")
        XCTAssertNil(floor.floorDate)
    }

    func testTheFloorMovesBackToTheQuestionThatOpenedTheJob() {
        let messages = TimelineFixtures.conversation(4)
        // The turn that opened the job started a moment after its question (u2) was saved.
        let turnStart = TimelineFixtures.minutes(4.5)
        XCTAssertEqual(TimelineSummaryPass.effectiveFloor(turnStart, in: messages), messages[4].timestamp)
        XCTAssertNil(TimelineSummaryPass.effectiveFloor(nil, in: messages))
        let beforeEverything = TimelineFixtures.minutes(-1)
        XCTAssertEqual(TimelineSummaryPass.effectiveFloor(beforeEverything, in: messages), beforeEverything)
    }
}
