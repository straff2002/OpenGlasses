import XCTest
@testable import OpenGlasses

/// Plan FB P2 — the voice route into Scan Assist.
///
/// Two properties matter more than the individual verbs. **Nothing infers a side**: a phrase that
/// does not say left or right produces the question, never a guess. And **every answer names the
/// side**, so a misheard word is audible immediately rather than thirty seconds later when a
/// reminder points the wrong way.
@MainActor
final class ScanAssistToolTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ScanAssistSettingsStore!
    private var speech: FakeScanAssistSpeech!
    private var service: ScanAssistService!
    private var tool: ScanAssistTool!

    override func setUp() {
        super.setUp()
        suiteName = "ScanAssistToolTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ScanAssistSettingsStore(defaults: defaults)
        speech = FakeScanAssistSpeech()
        // A private service, never `.shared`: this test must not touch the app's audio path.
        service = ScanAssistService(store: store, clock: { 0 })
        service.sleeper = { _ in }
        service.configure(speech: speech)
        var built = ScanAssistTool()
        built.serviceProvider = { [service] in service }
        tool = built
    }

    override func tearDown() {
        service?.stop()
        service = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func run(_ action: String, side: String? = nil) async throws -> String {
        var args: [String: Any] = ["action": action]
        if let side { args["side"] = side }
        return try await tool.execute(args: args)
    }

    // MARK: - The side comes from the phrase, or it is asked for

    func testSettingASideStartsRemindersAndSaysWhichSide() async throws {
        let answer = try await run("set_side", side: "left")
        XCTAssertEqual(answer, "Reminders on your left are running.")
        XCTAssertEqual(service.settings.side, .left)
        XCTAssertEqual(service.state, .running)
    }

    func testSettingTheOtherSideSaysSoOutLoud() async throws {
        _ = try await run("set_side", side: "left")
        let answer = try await run("set_side", side: "right")
        XCTAssertEqual(answer, "Reminders on your right are running.")
        XCTAssertEqual(service.settings.side, .right, "the side moved, and the answer said so")
    }

    /// Ambiguity asks. Picking a side for someone is the one failure this feature cannot recover
    /// from on its own — they would practise the wrong side without knowing.
    func testASideChangeWithNoSideAsksInsteadOfGuessing() async throws {
        let answer = try await run("set_side")
        XCTAssertEqual(answer, ScanAssistCopy.whichSideQuestion)
        XCTAssertNil(service.settings.side, "nothing was chosen on the wearer's behalf")
        XCTAssertEqual(service.state, .idle)
    }

    func testAnUnrecognisedSideValueAsksRatherThanDefaulting() async throws {
        let answer = try await tool.execute(args: ["action": "set_side", "side": "the other one"])
        XCTAssertEqual(answer, ScanAssistCopy.whichSideQuestion)
        XCTAssertNil(service.settings.side)
    }

    // MARK: - The tool never starts without a side

    func testStartingWithoutAChosenSideRefusesAndAsksForOne() async throws {
        let answer = try await run("start")
        XCTAssertEqual(answer, ScanAssistCopy.needsSideChoice)
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(speech.spoken.isEmpty, "and nothing was cued")
    }

    func testStartingAfterASideWasChosenRuns() async throws {
        service.chooseSide(.right)
        let answer = try await run("start")
        XCTAssertEqual(answer, "Reminders on your right are running.")
        XCTAssertEqual(service.state, .running)
    }

    // MARK: - The session verbs

    func testPauseResumeAndStopEachNameTheSide() async throws {
        service.chooseSide(.left)
        _ = try await run("start")

        let paused = try await run("pause")
        XCTAssertEqual(paused, "Reminders on your left are paused.")
        XCTAssertEqual(service.state, .paused)

        let resumed = try await run("resume")
        XCTAssertEqual(resumed, "Reminders on your left are running.")
        XCTAssertEqual(service.state, .running)

        let stopped = try await run("stop")
        XCTAssertEqual(stopped, "Reminders on your left have stopped.")
        XCTAssertEqual(service.state, .ended(.stopped))
    }

    func testStatusReportsTheSideAndWhetherRemindersAreRunning() async throws {
        service.chooseSide(.right)
        let idle = try await run("status")
        XCTAssertEqual(idle, "Reminders are set to your right, and not running.")
        _ = try await run("start")
        let running = try await run("status")
        XCTAssertEqual(running, "Reminders on your right are running.")
    }

    func testStatusWithNoSideChosenAsksForOne() async throws {
        let answer = try await run("status")
        XCTAssertEqual(answer, ScanAssistCopy.needsSideChoice)
    }

    /// A second "start scan reminders" must not hand back a fresh session length — the same rule
    /// the buttons follow, reached by voice.
    func testASecondStartDoesNotRestartALiveSession() async throws {
        service.chooseSide(.left)
        _ = try await run("start")
        let remaining = service.remainingSeconds
        _ = try await run("start")
        XCTAssertEqual(service.remainingSeconds ?? 0, remaining ?? -1, accuracy: 0.001)
    }

    func testAnUnknownActionExplainsWhatTheToolCanDoAndChangesNothing() async throws {
        service.chooseSide(.left)
        let answer = try await run("levitate")
        XCTAssertTrue(answer.contains("start"))
        XCTAssertEqual(service.state, .idle)
    }

    // MARK: - Declaration

    func testTheToolDeclaresItsExecutionSemantics() {
        XCTAssertNotEqual(tool.executionSemantics, .conservativeDefault)
        XCTAssertEqual(tool.executionSemantics.effect, .localMutation)
    }

    /// The description feeds the generated system prompt, where it is the only thing stopping a
    /// model from inventing a side.
    func testTheDescriptionForbidsGuessingASide() {
        let description = tool.description.lowercased()
        XCTAssertTrue(description.contains("never guess a side"))
        XCTAssertTrue(description.contains("camera"),
                      "the prompt has to carry the observation boundary too")
    }
}
