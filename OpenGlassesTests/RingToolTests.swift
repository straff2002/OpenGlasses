import XCTest
@testable import OpenGlasses

/// Plan MZ P3 — the `ring` tool: each action, the delivery policy's receipts in medical mode and
/// without consent, and a ring that is not paired.
@MainActor
final class RingToolTests: XCTestCase {

    private final class FakeRing: RingToolBackend {
        var isPaired = true
        var isConnected = true
        var battery: Int? = 64
        var lastSync: Date?
        var freshHeartRate: Int?
        var outcome: RingService.MeasurementOutcome = .heartRate(72)
        var lights = true
        var never = false
        private(set) var measured: [RingMeasurement] = []
        private(set) var syncs = 0

        func measure(_ measurement: RingMeasurement) async -> RingService.MeasurementOutcome {
            measured.append(measurement)
            if never { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            return outcome
        }
        func findRing() async -> Bool { lights }
        func syncNow() { syncs += 1 }
    }

    private var ring = FakeRing()
    private var spoken: [String] = []
    private var speakResult: SpeechDeliveryOutcome = .completed
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    nonisolated private static let cloudWithConsent = HealthSummaryDeliveryPolicy.Inputs(
        activeModelIsLocal: false, shareHealthWithAI: true, hipaaMode: false, medicalLocalOnly: false)
    nonisolated private static let cloudWithoutConsent = HealthSummaryDeliveryPolicy.Inputs(
        activeModelIsLocal: false, shareHealthWithAI: false, hipaaMode: false, medicalLocalOnly: false)
    nonisolated private static let medical = HealthSummaryDeliveryPolicy.Inputs(
        activeModelIsLocal: true, shareHealthWithAI: true, hipaaMode: true, medicalLocalOnly: false)

    override func setUp() {
        super.setUp()
        ring = FakeRing()
        spoken = []
        speakResult = .completed
    }

    private func tool(delivery: HealthSummaryDeliveryPolicy.Inputs = RingToolTests.cloudWithConsent, enabled: Bool = true,
                      backend: RingToolBackend?? = nil, wait: TimeInterval = 55) -> RingTool {
        let fake = ring
        let chosen: RingToolBackend? = backend ?? fake
        return RingTool(backend: { chosen }, enabled: { enabled }, deliveryInputs: { delivery },
                        speaker: { [unowned self] text in
                            self.spoken.append(text)
                            return self.speakResult
                        },
                        clock: { [now] in now }, locale: Locale(identifier: "en_US"), measurementWait: wait)
    }

    private func run(_ action: String, _ tool: RingTool) async throws -> String {
        try await tool.execute(args: ["action": action])
    }

    // MARK: - Not available

    func testNoRingPairedSaysSoAndNamesTheSetting() async throws {
        ring.isPaired = false
        let result = try await run("battery", tool())
        XCTAssertEqual(result, RingTool.notPaired)
        XCTAssertTrue(result.contains("Devices & Privacy"))
        let none = try await run("heart_rate", tool(backend: .some(nil)))
        XCTAssertEqual(none, RingTool.notPaired, "no ring service at all reads the same")
    }

    func testOffWhileTheRingSupportIsOff() async throws {
        let off = tool(enabled: false)
        XCTAssertFalse(off.isOfferedNow)
        let result = try await run("battery", off)
        XCTAssertEqual(result, RingTool.notOn)
        XCTAssertTrue(tool().isOfferedNow)
    }

    func testAnUnknownActionListsTheRealOnes() async throws {
        let result = try await run("blood_pressure", tool())
        XCTAssertTrue(result.contains("heart_rate, oxygen, battery, find, last_sync, sync"))
    }

    // MARK: - Not health data

    func testBatteryAndLastSyncAreReturned() async throws {
        let battery = try await run("battery", tool(delivery: Self.medical))
        XCTAssertEqual(battery, "The ring's battery is at 64 percent.")
        ring.isConnected = false
        let away = try await run("battery", tool())
        XCTAssertTrue(away.contains("64 percent"))
        XCTAssertTrue(away.contains("isn't connected"))

        let never = try await run("last_sync", tool())
        XCTAssertEqual(never, "The ring hasn't synced to Apple Health yet.")
        ring.lastSync = now.addingTimeInterval(-2 * 3600)
        let synced = try await run("last_sync", tool())
        XCTAssertTrue(synced.hasPrefix("The ring last synced to Apple Health"))
        XCTAssertTrue(synced.contains("2 hours ago"), synced)
        XCTAssertTrue(spoken.isEmpty, "nothing here is spoken for the model")
    }

    func testSyncAndFind() async throws {
        let sync = try await run("sync", tool())
        XCTAssertTrue(sync.hasPrefix("Syncing the ring now"))
        XCTAssertEqual(ring.syncs, 1)

        let found = try await run("find", tool())
        XCTAssertEqual(found, "The ring is lit up for a few seconds.")
        ring.lights = false
        let silent = try await run("find", tool())
        XCTAssertTrue(silent.hasPrefix("The ring didn't answer"))

        ring.isConnected = false
        let away = try await run("sync", tool())
        XCTAssertEqual(away, RingTool.notConnected)
        XCTAssertEqual(ring.syncs, 1)
    }

    // MARK: - Measurements and who hears them

    func testAHeartRateReachesTheModelWithConsent() async throws {
        let result = try await run("heart_rate", tool(delivery: Self.cloudWithConsent))
        XCTAssertEqual(result, RingTool.heartRateSentence(72))
        XCTAssertTrue(result.contains("estimate"))
        XCTAssertEqual(ring.measured, [.spotHeartRate])
        XCTAssertTrue(spoken.isEmpty)
    }

    func testWithoutConsentTheNumberIsSpokenAndTheModelGetsTheReceipt() async throws {
        let result = try await run("heart_rate", tool(delivery: Self.cloudWithoutConsent))
        XCTAssertEqual(result, HealthSummaryDeliveryPolicy.receipt)
        XCTAssertFalse(result.contains("72"))
        XCTAssertEqual(spoken, [RingTool.heartRateSentence(72)])
    }

    func testInMedicalModeTheNumberNeverReachesTheModel() async throws {
        ring.outcome = .oxygen(97)
        let result = try await run("oxygen", tool(delivery: Self.medical))
        XCTAssertEqual(result, HealthSummaryDeliveryPolicy.receipt)
        XCTAssertFalse(result.contains("97"))
        XCTAssertEqual(spoken, [RingTool.holdStill, RingTool.oxygenSentence(97)])
    }

    func testAnUnspokenMeasurementGetsTheNotSpokenReceipt() async throws {
        speakResult = .failed(reason: "muted")
        let result = try await run("heart_rate", tool(delivery: Self.medical))
        XCTAssertEqual(result, HealthSummaryDeliveryPolicy.notSpokenReceipt)
    }

    func testOxygenAsksForAStillHandAndReturnsTheReading() async throws {
        ring.outcome = .oxygen(96)
        let result = try await run("oxygen", tool())
        XCTAssertEqual(result, RingTool.oxygenSentence(96))
        XCTAssertEqual(spoken, [RingTool.holdStill])
        XCTAssertEqual(ring.measured, [.oxygen])
    }

    func testAWorkoutsFreshReadingAnswersWithoutANewMeasurement() async throws {
        ring.freshHeartRate = 131
        let result = try await run("heart_rate", tool())
        XCTAssertEqual(result, RingTool.heartRateSentence(131))
        XCTAssertTrue(ring.measured.isEmpty)
    }

    func testOutcomesWithoutANumberAreSaidPlainly() async throws {
        for (outcome, line) in [(RingService.MeasurementOutcome.busy, RingTool.busy),
                                (.interrupted, RingTool.interrupted),
                                (.notConnected, RingTool.notConnected)] {
            ring.outcome = outcome
            let result = try await run("heart_rate", tool(delivery: Self.medical))
            XCTAssertEqual(result, line)
        }
        ring.outcome = .noReading
        let none = try await run("heart_rate", tool(delivery: Self.medical))
        XCTAssertTrue(none.hasPrefix("The ring finished without a reading"))
        XCTAssertTrue(spoken.isEmpty, "nothing with a number to speak")

        ring.isConnected = false
        let away = try await run("oxygen", tool())
        XCTAssertEqual(away, RingTool.notConnected)
    }

    func testAMeasurementThatNeverEndsAnswersInsideTheBudget() async throws {
        ring.never = true
        let started = Date()
        let result = try await run("heart_rate", tool(wait: 0.1))
        XCTAssertTrue(result.hasPrefix("The ring finished without a reading"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    // MARK: - The declaration

    func testTheDeclarationReadsWellAndBudgetsForOxygen() {
        let ringTool = tool()
        XCTAssertEqual(ringTool.name, "ring")
        XCTAssertEqual(ringTool.executionSemantics.timeout, .seconds(60))
        XCTAssertEqual(ringTool.executionSemantics.effect, .localMutation)
        let schema = ringTool.parametersSchema["properties"] as? [String: Any]
        let action = schema?["action"] as? [String: Any]
        XCTAssertEqual(action?["enum"] as? [String], ["heart_rate", "oxygen", "battery", "find", "last_sync", "sync"])
        for banned in ["SMART_RING", "Plan ", "(beta)", "glasses"] {
            XCTAssertFalse(ringTool.description.contains(banned), banned)
        }
        XCTAssertTrue(ringTool.description.contains("not medical measurements"))
        XCTAssertTrue(ringTool.description.contains("health_summary"))
    }

    func testTheRegistryHoldsTheToolButOffersItOnlyWithTheRingSupportOn() {
        let saved = UserDefaults.standard.object(forKey: "ringSupportEnabled")
        defer { UserDefaults.standard.set(saved, forKey: "ringSupportEnabled") }

        UserDefaults.standard.set(false, forKey: "ringSupportEnabled")
        let registry = NativeToolRegistry(locationService: LocationService())
        XCTAssertTrue(registry.hasTool(named: "ring"))
        XCTAssertFalse(registry.toolNames.contains("ring"))
        XCTAssertNil(registry.tool(named: "ring"))
        XCTAssertTrue(registry.toolDescriptions(for: ["ring"]).isEmpty, "not in the system prompt's tool list")

        UserDefaults.standard.set(true, forKey: "ringSupportEnabled")
        XCTAssertTrue(registry.toolNames.contains("ring"))
        XCTAssertNotNil(registry.tool(named: "ring"))
        XCTAssertEqual(registry.toolDescriptions(for: ["ring"]).first?.description, tool().description)
    }

    func testTheToolIsClassifiedWhereverToolsAreListed() {
        // The source guards read the literal `let name = "ring"`; the static must say the same.
        XCTAssertEqual(tool().name, RingTool.toolName)
        XCTAssertEqual(PrivateToolRule.kind(of: "ring"), .wearerDirected)
        XCTAssertEqual(OfflineToolPolicy.availability(of: "ring"), .local)
        XCTAssertTrue(ActivityTitler.hasTemplate(for: "ring"))
        XCTAssertNil(ActivityTitler.title(tool: "ring", actionKey: "battery", effectClass: .write),
                     "reading the battery is not an action")
    }
}
