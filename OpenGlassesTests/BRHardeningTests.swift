import XCTest
import MWDATCore
@testable import OpenGlasses

/// Plan BR — realtime & stream hardening: tool-call breaker, connection-generation gate,
/// stream-recovery tiering, DAT compatibility messaging, gateway session hygiene.
final class BRHardeningTests: XCTestCase {

    // MARK: P1 — ToolCallBreaker

    func testBreakerAllowsUnderThreshold() {
        var breaker = ToolCallBreaker(config: .init(maxConsecutiveCalls: 3, maxIdenticalFailures: 3))
        XCTAssertEqual(breaker.admit(toolName: "weather"), .allowed)
        XCTAssertEqual(breaker.admit(toolName: "notes"), .allowed)
        XCTAssertEqual(breaker.admit(toolName: "weather"), .allowed)
        XCTAssertTrue(breaker.suspendedTools.isEmpty)
    }

    func testBreakerTripsOnRunawayConsecutiveCalls() {
        var breaker = ToolCallBreaker(config: .init(maxConsecutiveCalls: 3, maxIdenticalFailures: 3))
        for _ in 0..<3 { XCTAssertEqual(breaker.admit(toolName: "weather"), .allowed) }
        guard case .suspended(let message) = breaker.admit(toolName: "weather") else {
            return XCTFail("4th consecutive call should trip the breaker")
        }
        XCTAssertTrue(message.contains("weather"))
        XCTAssertTrue(breaker.suspendedTools.contains("weather"))
        // And it stays refused.
        guard case .suspended = breaker.admit(toolName: "weather") else {
            return XCTFail("suspended tool must stay refused")
        }
    }

    func testUserTurnResetsConsecutiveWindow() {
        var breaker = ToolCallBreaker(config: .init(maxConsecutiveCalls: 2, maxIdenticalFailures: 3))
        XCTAssertEqual(breaker.admit(toolName: "a"), .allowed)
        XCTAssertEqual(breaker.admit(toolName: "b"), .allowed)
        breaker.recordUserTurn()
        XCTAssertEqual(breaker.admit(toolName: "c"), .allowed, "user turn must reset the window")
    }

    func testIdenticalFailuresSuspendOnlyThatTool() {
        var breaker = ToolCallBreaker(config: .init(maxConsecutiveCalls: 100, maxIdenticalFailures: 3))
        let key = ToolCallBreaker.argsKey(["city": "Wellington"])
        XCTAssertNil(breaker.recordOutcome(toolName: "weather", argsKey: key, success: false))
        XCTAssertNil(breaker.recordOutcome(toolName: "weather", argsKey: key, success: false))
        let notice = breaker.recordOutcome(toolName: "weather", argsKey: key, success: false)
        XCTAssertNotNil(notice, "3rd identical failure must suspend")
        XCTAssertEqual(breaker.suspendedTools, ["weather"])
        XCTAssertEqual(breaker.admit(toolName: "notes"), .allowed, "other tools unaffected")
    }

    func testDifferentArgsFailuresDoNotAccumulate() {
        var breaker = ToolCallBreaker(config: .init(maxConsecutiveCalls: 100, maxIdenticalFailures: 3))
        for city in ["a", "b", "c", "d"] {
            let key = ToolCallBreaker.argsKey(["city": city])
            XCTAssertNil(breaker.recordOutcome(toolName: "weather", argsKey: key, success: false))
        }
        XCTAssertTrue(breaker.suspendedTools.isEmpty)
    }

    func testSuccessClearsFailureStreak() {
        var breaker = ToolCallBreaker(config: .init(maxConsecutiveCalls: 100, maxIdenticalFailures: 2))
        let key = ToolCallBreaker.argsKey(["q": "x"])
        XCTAssertNil(breaker.recordOutcome(toolName: "search", argsKey: key, success: false))
        XCTAssertNil(breaker.recordOutcome(toolName: "search", argsKey: key, success: true))
        XCTAssertNil(breaker.recordOutcome(toolName: "search", argsKey: key, success: false),
                     "streak must restart after a success")
    }

    func testArgsKeyStableAndOrderInsensitive() {
        let a = ToolCallBreaker.argsKey(["x": 1, "y": "two"])
        let b = ToolCallBreaker.argsKey(["y": "two", "x": 1])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ToolCallBreaker.argsKey(["x": 2, "y": "two"]))
    }

    // MARK: P3 — ConnectionGenerationGate

    func testGenerationGateSupersedesOlderGenerations() {
        var gate = ConnectionGenerationGate()
        let g1 = gate.advance()
        XCTAssertTrue(gate.isCurrent(g1))
        let g2 = gate.advance()
        XCTAssertFalse(gate.isCurrent(g1), "stale close/error/timeout must no-op")
        XCTAssertTrue(gate.isCurrent(g2))
        _ = gate.advance()   // disconnect() — everything outstanding goes stale
        XCTAssertFalse(gate.isCurrent(g2))
    }

    // MARK: P2 — StreamRecoveryPolicy + compatibility messages

    func testRecoveryTieringRebuildsStreamFirst() {
        XCTAssertEqual(StreamRecoveryPolicy.action(consecutiveFailures: 0), .rebuildStream)
        XCTAssertEqual(StreamRecoveryPolicy.action(consecutiveFailures: 1), .rebuildStream)
        XCTAssertEqual(StreamRecoveryPolicy.action(consecutiveFailures: 2), .resetSession)
        XCTAssertEqual(StreamRecoveryPolicy.action(consecutiveFailures: 5), .resetSession)
    }

    /// The reconnect ladder that runs after a wanted stream drops. Its shape is a promise: fast
    /// enough that a hiccup is invisible, slow enough not to hammer a radio mid-handshake, and
    /// finite — because past a certain point the glasses are off, flat or out of range, and the
    /// honest move is to say so rather than retry forever.
    func testReconnectCadenceStartsFastThenBacksOff() {
        let first = StreamRecoveryPolicy.reconnectDelay(attempt: 0)
        XCTAssertEqual(first, 1.5, "a hiccup should be covered before the wearer notices")

        var previous: TimeInterval = 0
        var attempt = 0
        while let delay = StreamRecoveryPolicy.reconnectDelay(attempt: attempt) {
            XCTAssertGreaterThanOrEqual(delay, previous,
                                        "the cadence must never speed back up at attempt \(attempt)")
            XCTAssertLessThanOrEqual(delay, 5, "a slow poll, not a stall")
            previous = delay
            attempt += 1
            XCTAssertLessThan(attempt, 200, "the ladder must terminate")
        }
        XCTAssertGreaterThan(attempt, 5, "a couple of tries is not a reconnect")
    }

    func testReconnectBudgetIsBoundedAndRoughlyAWakePlusHandshake() {
        XCTAssertNil(StreamRecoveryPolicy.reconnectDelay(attempt: 21),
                     "past the budget the ladder must stop, not keep climbing")
        XCTAssertNil(StreamRecoveryPolicy.reconnectDelay(attempt: -1))
        let budget = StreamRecoveryPolicy.reconnectBudget
        XCTAssertGreaterThan(budget, 60, "a glasses wake plus a BT handshake can take most of a minute")
        XCTAssertLessThan(budget, 120, "past ~90s more retries fix nothing")
    }

    /// The first notice promises a reconnect. When the ladder runs out, something has to retract
    /// that promise, or the wearer keeps waiting on a camera that stopped trying.
    func testGiveUpNoticeRetractsThePromise() {
        let notice = StreamRecoveryPolicy.reconnectGaveUpNotice.lowercased()
        XCTAssertTrue(notice.contains("glasses"))
        XCTAssertFalse(notice.contains("reconnecting"),
                       "the give-up notice must not repeat the promise it is retracting")
    }

    func testCompatibilityMessages() {
        XCTAssertNotNil(DATCompatibilityMessage.message(for: .datAppOnTheGlassesUpdateRequired))
        XCTAssertNil(DATCompatibilityMessage.message(for: .thermalCritical),
                     "non-compat device errors are not update messaging")
        XCTAssertNotNil(DATCompatibilityMessage.message(for: Compatibility.deviceUpdateRequired))
        XCTAssertNotNil(DATCompatibilityMessage.message(for: Compatibility.sdkUpdateRequired))
        XCTAssertNil(DATCompatibilityMessage.message(for: Compatibility.compatible))
    }

    // MARK: P4 — gateway session hygiene

    private let generationKey = "openClawSessionGeneration"
    private var savedGeneration: Any?

    override func setUp() {
        super.setUp()
        savedGeneration = UserDefaults.standard.object(forKey: generationKey)
        UserDefaults.standard.removeObject(forKey: generationKey)
    }

    override func tearDown() {
        if let saved = savedGeneration as? Int {
            UserDefaults.standard.set(saved, forKey: generationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: generationKey)
        }
        super.tearDown()
    }

    @MainActor
    func testSessionKeyStableByDefaultAndRotatesOnlyOnExplicitReset() {
        let bridge = OpenClawBridge()
        XCTAssertEqual(bridge.currentSessionKey, "agent:main:glass",
                       "default key must be stable — no timestamp fragmentation")
        // A second bridge (≈ next Live session) sees the SAME key.
        XCTAssertEqual(OpenClawBridge().currentSessionKey, "agent:main:glass")

        bridge.resetSession()
        XCTAssertEqual(bridge.currentSessionKey, "agent:main:glass:1")
        // Deliberate resets persist: a fresh bridge continues at the rotated generation.
        XCTAssertEqual(OpenClawBridge().currentSessionKey, "agent:main:glass:1")
    }

    func testMessageChannelConstant() {
        XCTAssertEqual(OpenClawBridge.messageChannel, "glass")
    }
}
