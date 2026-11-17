import XCTest
@testable import OpenGlasses

/// The Inputs probe's record and rules (Plan JV P2), without the SDK. Compiled in every build.
@MainActor
final class InputsProbeLedgerTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger() -> InputsProbeLedger {
        InputsProbeLedger(now: { [unowned self] in self.clock })
    }

    private func advance(_ milliseconds: Int) {
        clock = clock.addingTimeInterval(Double(milliseconds) / 1000)
    }

    private let select = GlassesInput(kind: .select, origin: .captouch)

    // MARK: - The rules

    func testStartIsRefusedFirstConditionFirst() {
        typealias Policy = InputsProbePolicy
        XCTAssertNil(Policy.refusal(verdict: .runs, connected: true, running: false))
        XCTAssertEqual(Policy.refusal(verdict: .notInThisBuild, connected: false, running: true), .notInThisBuild)
        XCTAssertEqual(Policy.refusal(verdict: .heldOnThisChannel, connected: true, running: false), .heldOnThisChannel)
        XCTAssertEqual(Policy.refusal(verdict: .glassesNotSupported, connected: true, running: false),
                       .glassesNotSupported)
        XCTAssertEqual(Policy.refusal(verdict: .runs, connected: false, running: true), .alreadyRunning)
        XCTAssertEqual(Policy.refusal(verdict: .runs, connected: false, running: false), .notConnected)
    }

    /// The probe has no switch: its verdict is asked with the switch on, so a diagnostics verdict
    /// is never `switchedOff`, and an unflagged build is never let through.
    func testTheDiagnosticsVerdictIgnoresNoConditionButTheSwitch() {
        let verdict = DATExperimentalPolicy.currentForDiagnostics()
        XCTAssertNotEqual(verdict, .switchedOff)
        if !DATExperimentalPolicy.isCompiledIn {
            XCTAssertEqual(verdict, .notInThisBuild)
            XCTAssertEqual(InputsProbePolicy.refusal(verdict: verdict, connected: true, running: false),
                           .notInThisBuild)
        }
    }

    func testTheInputsCapabilityHoldsTheSharedSessionLikeAnyOther() throws {
        XCTAssertTrue(DeviceSessionOwnership.Capability.allCases.contains(.inputs))
        var ownership = DeviceSessionOwnership()
        XCTAssertTrue(ownership.acquire(.inputs))
        XCTAssertFalse(ownership.acquire(.camera))
        XCTAssertFalse(ownership.release(.inputs))
        XCTAssertTrue(ownership.release(.camera))
    }

    // MARK: - The record

    func testNothingIsReportedUntilARunStarts() {
        let ledger = ledger()
        ledger.recordInput(select, userAudioPlaying: false)
        ledger.recordState(.active)
        ledger.end(.wearerStopped, battery: 80)
        XCTAssertEqual(ledger.reportLines, [])
        XCTAssertNil(ledger.current)
    }

    func testARunRecordsInputsStatesErrorsAndHowItEnded() {
        let ledger = ledger()
        ledger.begin(battery: 80)
        advance(1200)
        ledger.recordState(.activating)
        advance(800)
        ledger.recordState(.active)
        advance(500)
        ledger.recordInput(select, userAudioPlaying: false)
        advance(250)
        ledger.recordInput(GlassesInput(kind: .nav(.left), origin: .captouch), userAudioPlaying: true)
        ledger.recordInput(select, userAudioPlaying: true)
        advance(100)
        ledger.recordError(.communicationError)
        advance(300_000 - 2850)
        ledger.end(.timeLimit, battery: 78)

        XCTAssertNil(ledger.current)
        XCTAssertEqual(ledger.runs.count, 1)
        XCTAssertEqual(ledger.reportLines, [
            "Glasses inputs probe: 1 run since launch (sources captouch, Back left to Meta)",
            "  run 1 · \(time(of: Date(timeIntervalSince1970: 1_800_000_000))) · started, battery 80 %",
            "  run 1 · +1200 ms · state activating",
            "  run 1 · +2000 ms · state active",
            "  run 1 · +2500 ms · select (captouch)",
            "  run 1 · +2750 ms · nav-left (captouch), audio playing",
            "  run 1 · +2750 ms · select (captouch), audio playing",
            "  run 1 · +2850 ms · error communicationError",
            "  run 1 · 3 inputs: select (captouch) 2, nav-left (captouch) 1 · 2 with audio playing",
            "  run 1 · stopped (timeLimit) after 300 s, battery 78 % (24.0 points per hour)",
        ])
    }

    func testEveryKindHasItsReportToken() {
        let kinds: [(GlassesInputKind, String)] = [
            (.nav(.up), "nav-up"), (.nav(.down), "nav-down"), (.nav(.right), "nav-right"),
            (.select, "select"), (.back, "back"), (.actionButton, "button-action"),
            (.capture(.shortPress), "capture-shortPress"), (.capture(.hold), "capture-hold"),
            (.capture(.doublePress), "capture-doublePress"),
            (.drag(.down), "drag-down"), (.drag(.move), "drag-move"), (.drag(.up), "drag-up"),
            (.unknown, "unknown"),
        ]
        for (kind, token) in kinds { XCTAssertEqual(kind.reportToken, token) }
    }

    func testInputsAreCappedAndTheReportSaysSo() throws {
        let ledger = ledger()
        ledger.begin(battery: nil)
        for _ in 0..<(InputsProbeLedger.inputCapacity + 20) {
            ledger.recordInput(select, userAudioPlaying: false)
        }
        let run = try XCTUnwrap(ledger.current)
        XCTAssertEqual(run.inputCount, InputsProbeLedger.inputCapacity + 20)
        XCTAssertEqual(run.keptInputs, InputsProbeLedger.inputCapacity)
        XCTAssertTrue(run.isTruncated)
        // States still arrive after the inputs' cap.
        ledger.recordState(.inactive)
        ledger.end(.wearerStopped, battery: nil)
        let lines = ledger.reportLines
        XCTAssertTrue(lines.contains("  run 1 · truncated: 520 inputs, the first 500 kept"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasSuffix("· state inactive") })
        XCTAssertTrue(lines.contains("  run 1 · 520 inputs: select (captouch) 500 · 0 with audio playing"))
        XCTAssertTrue(lines.last?.hasPrefix("  run 1 · stopped (wearerStopped) after 0 s, battery not known") == true)
    }

    func testStatesAndErrorsAreCappedToo() {
        let ledger = ledger()
        ledger.begin(battery: 50)
        for _ in 0..<(InputsProbeLedger.otherCapacity + 3) { ledger.recordError(.connectionClosed) }
        XCTAssertEqual(ledger.current?.droppedOther, 3)
        XCTAssertTrue(ledger.reportLines.contains("  run 1 · truncated: 3 more state changes and errors not kept"))
    }

    func testOnlyTheLastRunsAreKeptAndNumberedFromLaunch() {
        let ledger = ledger()
        for _ in 0..<(InputsProbeLedger.runCapacity + 1) {
            ledger.begin(battery: 90)
            ledger.end(.linkDown, battery: 90)
        }
        XCTAssertEqual(ledger.runs.count, InputsProbeLedger.runCapacity)
        let lines = ledger.reportLines
        XCTAssertEqual(lines.first, "Glasses inputs probe: 4 runs since launch (sources captouch, Back left to Meta)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("  run 1 ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("  run 4 ") })
    }

    func testARunStillGoingSaysSo() {
        let ledger = ledger()
        ledger.begin(battery: 70)
        XCTAssertEqual(ledger.reportLines.last, "  run 1 · still running")
        XCTAssertEqual(ledger.reportLines[ledger.reportLines.count - 2], "  run 1 · 0 inputs")
    }

    func testARefusalIsKeptUntilTheNextRun() {
        let ledger = ledger()
        ledger.refused(.notConnected)
        XCTAssertEqual(ledger.lastRefusal, .notConnected)
        XCTAssertEqual(ledger.reportLines, [], "a refusal alone is not a run")
        ledger.begin(battery: nil)
        XCTAssertNil(ledger.lastRefusal)
    }

    func testTheBatteryRateNeedsBothReadingsAndAMinute() {
        XCTAssertNil(InputsProbeLedger.batteryPerHour(from: nil, to: 70, milliseconds: 300_000))
        XCTAssertNil(InputsProbeLedger.batteryPerHour(from: 80, to: nil, milliseconds: 300_000))
        XCTAssertNil(InputsProbeLedger.batteryPerHour(from: 80, to: 79, milliseconds: 59_999))
        XCTAssertEqual(InputsProbeLedger.batteryPerHour(from: 80, to: 79, milliseconds: 120_000), "30.0 points per hour")
        XCTAssertEqual(InputsProbeLedger.batteryPerHour(from: 80, to: 80, milliseconds: 300_000), "0.0 points per hour")
    }

    /// Case names and numbers only: no coordinates, no SDK module names.
    func testTheReportCarriesNoCoordinatesOrModuleNames() {
        let ledger = ledger()
        ledger.begin(battery: 60)
        ledger.recordInput(GlassesInput(kind: .drag(.move), origin: .captouch), userAudioPlaying: false)
        ledger.end(.sessionEnded, battery: 60)
        for line in ledger.reportLines {
            XCTAssertNil(line.range(of: "mwdat", options: .caseInsensitive), line)
            XCTAssertNil(line.range(of: #"\bx\b|\bdx\b|\by\b|\bdy\b"#, options: .regularExpression), line)
        }
    }

    private func time(of date: Date) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"
        return clock.string(from: date)
    }
}
