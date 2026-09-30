import XCTest
@testable import OpenGlasses

/// Plan GI P2 — the `health_summary` tool against a fake Health store: each metric, permission,
/// the locked phone with and without a cache, and the speak-direct path that keeps numbers from
/// the model.
@MainActor
final class HealthSummaryToolTests: XCTestCase {

    private typealias F = HealthFixture

    private var reader: FakeHealthReader!
    private var directory: URL!
    private var cache: HealthSummaryCache!
    private var spoken: [String] = []
    private var speechOutcome: SpeechDeliveryOutcome = .completed
    private var inputs = HealthSummaryDeliveryPolicy.Inputs(activeModelIsLocal: false, shareHealthWithAI: true,
                                                            hipaaMode: false, medicalLocalOnly: false)
    private var motion: Double? = nil
    private var clock = HealthFixture.now
    private var savedFeatureSwitch = true

    override func setUp() async throws {
        try await super.setUp()
        savedFeatureSwitch = Config.healthSummariesEnabled
        Config.healthSummariesEnabled = true
        reader = FakeHealthReader()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthSummaryToolTests_\(UUID().uuidString)", isDirectory: true)
        cache = HealthSummaryCache(directory: directory)
        spoken = []
    }

    override func tearDown() async throws {
        Config.healthSummariesEnabled = savedFeatureSwitch
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeTool() -> HealthSummaryTool {
        HealthSummaryTool(
            reader: reader, cache: cache, clock: { [unowned self] in self.clock },
            calendar: F.calendar, locale: F.locale,
            deliveryInputs: { [unowned self] in self.inputs },
            speaker: { [unowned self] text in
                self.spoken.append(text)
                return self.speechOutcome
            },
            motionSteps: { [unowned self] in self.motion })
    }

    private func run(_ metric: String) async throws -> String {
        try await makeTool().execute(args: ["metric": metric])
    }

    private func seedHealth() {
        reader.latest = HeartRateReading(beatsPerMinute: 72, date: F.at(15, 8, 57))
        reader.resting = [HeartRateReading(beatsPerMinute: 58, date: F.at(15, 6))]
        reader.sleep = [F.sleep(F.at(14, 23), F.at(15, 6, 30), .asleepUnspecified, source: "phone")]
        // 400 steps an hour from 07:00 on every day; today and each history day look alike.
        reader.steps = { from, to in
            let calendar = HealthFixture.calendar
            let dayStart = calendar.startOfDay(for: from)
            let walkStart = dayStart.addingTimeInterval(7 * 3600)
            let seconds = max(0, to.timeIntervalSince(max(from, walkStart)))
            return (seconds / 3600 * 400).rounded()
        }
    }

    // MARK: - Metrics (sharing on: the sentence is the result)

    func testHeartRate() async throws {
        seedHealth()
        let result = try await run("heart_rate")
        XCTAssertEqual(result, "Your heart rate was 72 beats per minute a few minutes ago; resting 58 today.")
        XCTAssertTrue(spoken.isEmpty, "sharing is on, so the model says it, not the tool")
    }

    func testSleep() async throws {
        seedHealth()
        let result = try await run("sleep")
        XCTAssertEqual(result, "You slept 7 hours, 30 minutes last night.")
    }

    func testStepsComparesWithUsual() async throws {
        seedHealth()
        reader.steps = { from, to in
            // Today: 1,000 so far. Every earlier day: 400 by this time, 6,000 in all.
            if HealthFixture.calendar.isDate(from, inSameDayAs: HealthFixture.now) { return 1000 }
            return to.timeIntervalSince(from) >= 86_000 ? 6000 : 400
        }
        let result = try await run("steps")
        XCTAssertEqual(result, "You've taken 1,000 steps so far today, about 600 more than usual by now.")
    }

    func testOverview() async throws {
        seedHealth()
        let result = try await run("overview")
        XCTAssertEqual(result, "You slept 7 hours, 30 minutes last night. You've taken 800 steps so far "
                       + "today, and your resting heart rate was 58 today.")
    }

    func testAnUnknownMetricIsAnOverview() async throws {
        seedHealth()
        let overview = try await run("overview")
        let result = try await makeTool().execute(args: ["metric": "blood_pressure"])
        XCTAssertEqual(result, overview)
    }

    // MARK: - Speak direct

    func testWithSharingOffTheToolSpeaksAndTheModelGetsNoNumbers() async throws {
        seedHealth()
        inputs.shareHealthWithAI = false
        let result = try await run("heart_rate")
        XCTAssertEqual(result, HealthSummaryDeliveryPolicy.receipt)
        XCTAssertFalse(result.contains(where: \.isNumber))
        XCTAssertEqual(spoken, ["Your heart rate was 72 beats per minute a few minutes ago; resting 58 today."])
    }

    func testMedicalComplianceSpeaksDirectEvenWithSharingOn() async throws {
        seedHealth()
        inputs.hipaaMode = true
        let result = try await run("sleep")
        XCTAssertEqual(result, HealthSummaryDeliveryPolicy.receipt)
        XCTAssertEqual(spoken.count, 1)
    }

    func testAnOnDeviceModelGetsTheNumbersWithSharingOff() async throws {
        seedHealth()
        inputs = .init(activeModelIsLocal: true, shareHealthWithAI: false, hipaaMode: false, medicalLocalOnly: false)
        let result = try await run("sleep")
        XCTAssertTrue(result.contains("7 hours"))
        XCTAssertTrue(spoken.isEmpty)
    }

    func testASuppressedSpeechSaysItWasNotHeardAndStillWithholds() async throws {
        seedHealth()
        inputs.shareHealthWithAI = false
        speechOutcome = .suppressed(reason: .silentMode)
        let result = try await run("steps")
        XCTAssertEqual(result, HealthSummaryDeliveryPolicy.notSpokenReceipt)
        XCTAssertFalse(result.contains(where: \.isNumber))
    }

    // MARK: - Permission and availability

    func testNotAskedYetAndTheRequestCannotShowSaysWhereToAllowIt() async throws {
        reader.authorization = .notDetermined
        let result = try await run("sleep")
        XCTAssertEqual(result, HealthSummaryPhraser.needsPermission)
        XCTAssertEqual(reader.requestCount, 1)
        XCTAssertEqual(reader.readCount, 0, "nothing is read without access")
    }

    func testAGrantedRequestGoesOnToAnswer() async throws {
        seedHealth()
        reader.authorization = .notDetermined
        reader.grantsOnRequest = true
        let result = try await run("sleep")
        XCTAssertEqual(result, "You slept 7 hours, 30 minutes last night.")
    }

    func testStepsFallBackToTheMotionSensorWithoutHealth() async throws {
        reader.authorization = .unavailable
        motion = 4321
        let r1 = try await run("steps")
        XCTAssertEqual(r1, "You've taken 4,300 steps so far today.")
        let r2 = try await run("heart_rate")
        XCTAssertEqual(r2, HealthSummaryPhraser.healthUnavailable)
    }

    func testAReadThatLooksDeniedFallsBackToTheMotionSensorForSteps() async throws {
        motion = 2500   // Health returns nothing at all, today or ever
        let r3 = try await run("steps")
        XCTAssertEqual(r3, "You've taken 2,500 steps so far today.")
    }

    // MARK: - Locked phone

    func testLockedWithACacheAnswersWithItsAge() async throws {
        seedHealth()
        clock = F.at(15, 8, 10)
        _ = try await run("steps")                        // unlocked: reads Health, fills the cache
        reader.readError = .protectedDataUnavailable
        clock = F.at(15, 9, 30)
        let result = try await run("steps")
        XCTAssertTrue(result.hasPrefix("As of 8:10"), result)
        XCTAssertTrue(result.contains("you'd taken 500 steps today"), result)
    }

    func testLockedSleepFromTheCache() async throws {
        seedHealth()
        _ = try await run("sleep")
        reader.readError = .protectedDataUnavailable
        clock = F.at(15, 9, 45)
        // Read at 09:00, before the night's window closed, so the answer says when it was read.
        let result = try await run("sleep")
        XCTAssertTrue(result.hasPrefix("As of 9:00"), result)
        XCTAssertTrue(result.hasSuffix("you slept 7 hours, 30 minutes last night."), result)
    }

    func testLockedWithoutACacheSaysUnlock() async throws {
        reader.readError = .protectedDataUnavailable
        let r4 = try await run("heart_rate")
        XCTAssertEqual(r4, HealthSummaryPhraser.lockedNoCache)
        let r5 = try await run("overview")
        XCTAssertEqual(r5, HealthSummaryPhraser.lockedNoCache)
    }

    func testLockedStepsWithoutACacheUseTheMotionSensor() async throws {
        reader.readError = .protectedDataUnavailable
        motion = 1234
        let r6 = try await run("steps")
        XCTAssertEqual(r6, "You've taken 1,200 steps so far today.")
    }

    func testLockedAndSharingOffStillWithholdsTheCachedNumbers() async throws {
        seedHealth()
        _ = try await run("heart_rate")
        reader.readError = .protectedDataUnavailable
        inputs.shareHealthWithAI = false
        let result = try await run("heart_rate")
        XCTAssertEqual(result, HealthSummaryDeliveryPolicy.receipt)
        XCTAssertEqual(spoken.count, 1)
    }

    // MARK: - Cache refresh and the feature switch

    func testRefreshFillsTheCacheOnlyAfterTheWearerWasAsked() async {
        seedHealth()
        reader.authorization = .notDetermined
        await makeTool().refreshCache()
        XCTAssertFalse(cache.hasEntry)
        XCTAssertEqual(reader.requestCount, 0, "a refresh never prompts")

        reader.authorization = .requested
        await makeTool().refreshCache()
        XCTAssertNotNil(cache.load(now: clock)?.sleep)
        XCTAssertTrue(spoken.isEmpty, "a refresh never speaks")
    }

    func testTheFeatureSwitchTurnsTheToolOff() async throws {
        seedHealth()
        Config.healthSummariesEnabled = false
        let result = try await run("sleep")
        XCTAssertEqual(result, AIFeatureGate.disabledMessage(.healthSummaries))
        XCTAssertEqual(reader.readCount, 0)
    }

    func testTheToolIsARegisteredRead() {
        let tool = makeTool()
        XCTAssertEqual(tool.executionSemantics.effect, .readOnly)
        XCTAssertEqual(ToolEffectClassifier.nativeClass(name: tool.name, args: [:],
                                                        semantics: tool.executionSemantics), .readOnly)
        XCTAssertNotNil(NativeToolRegistry(locationService: LocationService()).tool(named: "health_summary"))
    }
}
