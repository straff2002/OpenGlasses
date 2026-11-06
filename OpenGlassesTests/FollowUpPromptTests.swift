import XCTest
@testable import OpenGlasses

/// Plan KP P2 — when the Direct prompt asks for a follow-ups tail: only while something shows
/// answers, with its setting on (decision 5: on for the Display, off for the mirror alone); in
/// the prompt's volatile tail, so the cacheable head never moves; never in an on-device prompt or
/// in a Live mode's instructions; still allowed under HIPAA mode.
@MainActor
final class FollowUpPromptTests: XCTestCase {

    private var savedSurface: (@MainActor () -> FollowUpPrompt.Surface)!
    private var savedDisplaySetting: Any?
    private var savedMirrorSetting: Any?
    private var savedHIPAA = false
    private var savedDisplayEnabled = false
    private var savedMirrorEnabled = false

    override func setUp() {
        super.setUp()
        savedSurface = FollowUpPrompt.currentSurface
        savedDisplaySetting = UserDefaults.standard.object(forKey: "followUpsOnDisplayEnabled")
        savedMirrorSetting = UserDefaults.standard.object(forKey: "followUpsOnMirrorEnabled")
        savedHIPAA = Config.hipaaMode
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedMirrorEnabled = Config.hudMirrorEnabled
        // Decision 5's defaults: never set, so the declared defaults are what is read.
        UserDefaults.standard.removeObject(forKey: "followUpsOnDisplayEnabled")
        UserDefaults.standard.removeObject(forKey: "followUpsOnMirrorEnabled")
        Config.hipaaMode = false
    }

    override func tearDown() {
        FollowUpPrompt.currentSurface = savedSurface
        restore(savedDisplaySetting, "followUpsOnDisplayEnabled")
        restore(savedMirrorSetting, "followUpsOnMirrorEnabled")
        Config.hipaaMode = savedHIPAA
        Config.setGlassesDisplayEnabled(savedDisplayEnabled)
        Config.hudMirrorEnabled = savedMirrorEnabled
        super.tearDown()
    }

    private func restore(_ value: Any?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func showing(_ surface: FollowUpPrompt.Surface) {
        FollowUpPrompt.currentSurface = { surface }
    }

    // MARK: - The rule

    func testOnlyASurfaceThatShowsAnswersWithItsSettingOnAsks() {
        typealias P = FollowUpPrompt
        for (onDisplay, onMirror) in [(false, false), (true, false), (false, true), (true, true)] {
            XCTAssertEqual(P.wanted(surface: .display, onDisplay: onDisplay, onMirror: onMirror), onDisplay)
            XCTAssertEqual(P.wanted(surface: .mirrorOnly, onDisplay: onDisplay, onMirror: onMirror), onMirror)
            XCTAssertFalse(P.wanted(surface: .none, onDisplay: onDisplay, onMirror: onMirror),
                           "nothing shows answers: no clause, whatever the settings")
        }
    }

    func testTheDefaultsAreOnForTheDisplayAndOffForTheMirror() {
        XCTAssertTrue(Config.followUpsOnDisplayEnabled)
        XCTAssertFalse(Config.followUpsOnMirrorEnabled)
        showing(.display)
        XCTAssertEqual(FollowUpPrompt.clauseForPrompt(), FollowUpPrompt.clause)
        showing(.mirrorOnly)
        XCTAssertNil(FollowUpPrompt.clauseForPrompt())
        Config.setFollowUpsOnMirrorEnabled(true)
        XCTAssertEqual(FollowUpPrompt.clauseForPrompt(), FollowUpPrompt.clause)
        showing(.none)
        XCTAssertNil(FollowUpPrompt.clauseForPrompt())
    }

    func testTheSettingOffDropsTheClause() {
        showing(.display)
        Config.setFollowUpsOnDisplayEnabled(false)
        XCTAssertNil(FollowUpPrompt.clauseForPrompt())
    }

    func testHIPAAModeStillAllowsTheClause() {
        Config.hipaaMode = true
        showing(.display)
        XCTAssertEqual(FollowUpPrompt.clauseForPrompt(), FollowUpPrompt.clause,
                       "the follow-ups never leave the reply, so the clause is allowed")
    }

    func testTheClauseAsksForWhatTheParserReads() {
        let clause = FollowUpPrompt.clause
        XCTAssertTrue(clause.contains(FollowUpTail.openTag))
        XCTAssertTrue(clause.contains(FollowUpTail.closeTag))
        XCTAssertTrue(clause.contains("|"))
        XCTAssertTrue(clause.contains("\(FollowUpTail.maxFollowUps) short questions"))
        XCTAssertTrue(clause.contains("\(FollowUpTail.maxWords) words or fewer"))
        // Its own example parses to the questions it shows.
        let example = String(clause[clause.range(of: FollowUpTail.openTag, options: .backwards)!.lowerBound...])
        let parsed = FollowUpTail.parse("An answer.\n" + example)
        XCTAssertEqual(parsed.followUps, ["How long does it take?", "What does it cost?"])
        XCTAssertLessThan(clause.count, 700, "short: it rides on every turn while a display is up")
    }

    // MARK: - The prompt

    func testTheCloudPromptCarriesTheClauseInItsVolatileTailWhileTheDisplayShowsAnswers() async {
        showing(.none)
        let without = await LLMService.promptLayoutForTesting()
        XCTAssertFalse(without.combined.contains("FOLLOW-UPS:"))

        showing(.display)
        let with = await LLMService.promptLayoutForTesting()
        XCTAssertTrue(with.volatile.contains(FollowUpPrompt.clause))
        XCTAssertFalse(with.stable.contains("FOLLOW-UPS:"))
        XCTAssertEqual(with.stable, without.stable, "the cacheable head does not move with the display")

        showing(.mirrorOnly)
        let mirror = await LLMService.promptLayoutForTesting()
        XCTAssertFalse(mirror.combined.contains("FOLLOW-UPS:"), "off for the mirror alone by default")
    }

    func testOnDevicePromptsNeverAsk() async {
        showing(.display)
        let local = await LLMService.leanOnDevicePrompt(locationContext: nil, memoryContext: nil,
                                                        hasImage: false, turn: "where's the fuse")
        XCTAssertFalse(local.contains("FOLLOW-UPS:"))
        XCTAssertFalse(LLMService.appleOnDevicePrompt(locationContext: nil, memoryContext: nil)
            .contains("FOLLOW-UPS:"))
        XCTAssertFalse(LLMService.leanCloudPrompt(hasImage: false).contains("FOLLOW-UPS:"))
        let notOffered = await LLMService.promptLayoutForTesting(offersFollowUps: false)
        XCTAssertFalse(notOffered.combined.contains("FOLLOW-UPS:"))
    }

    /// Gemini Live and OpenAI Realtime build their own instructions and their replies never reach
    /// the HUD, so nothing there may ask for a tail. Read from the source, as
    /// `SpeechSourceGuardTests` does: the clause is reached only from the Direct prompt builder.
    func testLiveModesNeverAsk() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var callers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("FollowUpPrompt.clause") { callers.append(url.lastPathComponent) }
        }
        XCTAssertEqual(callers, ["LLMService.swift"], "only the Direct-mode prompt asks for follow-ups")
        for live in ["Services/GeminiLive", "Services/OpenAIRealtime", "Services/Realtime", "Services/DoubaoRealtime",
                     "Services/QwenRealtime", "Services/Live", "Services/LiveSession"] {
            let dir = root.appendingPathComponent(live)
            guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                XCTAssertFalse(text.contains("FollowUpPrompt") || text.contains("<next>"), url.lastPathComponent)
            }
        }
    }

    // MARK: - The surface

    func testTheSurfaceIsTheDisplayThenTheMirrorAndNeitherWithTheHUDOff() {
        let display = GlassesDisplayService()
        Config.setGlassesDisplayEnabled(false)
        display.testCapabilityOverride = true
        XCTAssertEqual(display.answerSurface, .none, "the HUD off shows nothing")

        Config.setGlassesDisplayEnabled(true)
        Config.hudMirrorEnabled = true
        XCTAssertEqual(display.answerSurface, .display, "a display wins over the mirror")

        display.testCapabilityOverride = false
        XCTAssertEqual(display.answerSurface, .mirrorOnly)
        Config.hudMirrorEnabled = false
        XCTAssertEqual(display.answerSurface, .none)
    }
}
