import XCTest
@testable import OpenGlasses

/// Plan LA — Quiet After Actions. A turn ends with the done tone only when every call was a
/// reviewed native tool that reported `.done`, nothing was looked up, nothing was asked, and the
/// reply carries no caveat. Everything else speaks.
@MainActor
final class QuietTurnJudgeTests: XCTestCase {

    // MARK: - Fixtures

    private func call(_ tool: String, effect: ToolEffect = .localMutation,
                      outcome: QuietTurnCall.Outcome = .completed,
                      completion: ActionCompletion? = .done(summary: "Done it"),
                      native: Bool = true) -> QuietTurnCall {
        QuietTurnCall(tool: tool, effect: effect, outcome: outcome, completion: completion, isNative: native)
    }

    private let lightsOff = QuietTurnCall(tool: "smart_home", effect: .physicalActuation, outcome: .completed,
                                          completion: .done(summary: "Kitchen lights off"), isNative: true)
    private let timer = QuietTurnCall(tool: "set_timer", effect: .localMutation, outcome: .completed,
                                      completion: .done(summary: "Timer 10 minutes"), isNative: true)

    private func input(_ calls: [QuietTurnCall], utterance: String = "Turn off the kitchen lights",
                       reply: String = "Kitchen lights off.", enabled: Bool = true,
                       simpleMode: Bool = false, origin: QuietTurnInput.Origin = .spokenDirect,
                       language: String = "en", followUps: Bool = false) -> QuietTurnInput {
        QuietTurnInput(enabled: enabled, simpleMode: simpleMode, voiceOverRunning: false, origin: origin,
                       languageCode: language, utterance: utterance, calls: calls, reply: reply,
                       hasFollowUps: followUps)
    }

    private func verdict(_ input: QuietTurnInput) -> QuietTurnVerdict { QuietTurnJudge.judge(input) }

    // MARK: - Rule 1: only a spoken Direct turn with the setting on

    func testTheSettingOffSimpleModeAndOtherOriginsAlwaysSpeak() {
        XCTAssertEqual(verdict(input([lightsOff], enabled: false)), .speak(reason: .notApplicable))
        XCTAssertEqual(verdict(input([lightsOff], simpleMode: true)), .speak(reason: .notApplicable))
        for origin in [QuietTurnInput.Origin.typed, .siri, .live] {
            XCTAssertEqual(verdict(input([lightsOff], origin: origin)), .speak(reason: .notApplicable), "\(origin)")
        }
    }

    // MARK: - Rules 2–5: what the tools did

    func testAPlainAnswerSpeaks() {
        XCTAssertEqual(verdict(input([], utterance: "Tell a joke", reply: "Here's one.")),
                       .speak(reason: .noAction))
    }

    func testARefusalAFailureAnUnknownOutcomeOrARunningCallSpeaks() {
        for outcome in [QuietTurnCall.Outcome.rejected, .failedBeforeExecution, .outcomeUnknown, .running] {
            XCTAssertEqual(verdict(input([lightsOff, call("smart_home", outcome: outcome)])),
                           .speak(reason: .notAllDone), "\(outcome)")
        }
    }

    func testATimerWithAWeatherLookupSpeaks() {
        let weather = call("get_weather", effect: .readOnly, completion: nil)
        XCTAssertEqual(verdict(input([timer, weather], utterance: "Set a timer for ten minutes and get the weather",
                                     reply: "Timer set. It's sunny.")),
                       .speak(reason: .lookup))
    }

    func testAnMCPToolOrAGatewayCallSpeaksWhateverItSays() {
        let mcp = call("mcp__lights__off", effect: .externalMutation, native: false)
        XCTAssertEqual(verdict(input([mcp])), .speak(reason: .notAllDone))
    }

    func testNoReportAndAnUnreviewedToolsDoneBothSpeak() {
        XCTAssertEqual(verdict(input([call("set_timer", completion: nil)])), .speak(reason: .notAllDone))
        XCTAssertEqual(verdict(input([call("send_message", effect: .externalMutation)], utterance: "Text Sam I'm late",
                                     reply: "Sent.")),
                       .speak(reason: .notAllDone), "messages are never quiet (decision 3)")
        XCTAssertFalse(QuietActionRoster.isReviewed("send_via"))
        XCTAssertFalse(QuietActionRoster.isReviewed("phone_call"))
    }

    func testTheSpotifySearchLinkAndAQuestionBackSpeak() {
        let spotify = call("music_control", completion: .partial(reason: .handedToApp))
        XCTAssertEqual(verdict(input([spotify], utterance: "Play Bohemian Rhapsody on Spotify",
                                     reply: "Opened Spotify's search.")),
                       .speak(reason: .notAllDone))
        let which = call("music_control", completion: .awaitingWearer)
        XCTAssertEqual(verdict(input([which], utterance: "Pause the music", reply: "Paused.")),
                       .speak(reason: .notAllDone))
    }

    // MARK: - Rules 6–8: the words

    func testAQuestionFromTheWearerSpeaks() {
        XCTAssertEqual(verdict(input([timer], utterance: "Did you set the timer?", reply: "Timer set.")),
                       .speak(reason: .askedQuestion))
        XCTAssertEqual(verdict(input([timer], utterance: "is the timer set", reply: "Timer set.")),
                       .speak(reason: .askedQuestion))
    }

    func testAPoliteRequestIsARequestNotAQuestion() {
        XCTAssertEqual(verdict(input([lightsOff], utterance: "Can you turn off the kitchen lights?")),
                       .quiet(summary: "Kitchen lights off"))
        XCTAssertFalse(UtteranceQuestionCue.isQuestion("Could you pause the music", languageCode: "en"))
    }

    func testACaveatOrAQuestionInTheReplySpeaks() {
        XCTAssertEqual(verdict(input([lightsOff], reply: "Done, but the hall light didn't respond.")),
                       .speak(reason: .replyHasMore))
        XCTAssertEqual(verdict(input([lightsOff], reply: "Lights off. Want the porch too?")),
                       .speak(reason: .replyHasMore))
        XCTAssertEqual(verdict(input([lightsOff], followUps: true)), .speak(reason: .replyHasMore))
    }

    func testCaveatWordsMatchWholeWordsOnly() {
        XCTAssertFalse(ReplyCaveatCue.hasMore("Note saved.", languageCode: "en"), "'not' is not 'note'")
        XCTAssertFalse(ReplyCaveatCue.hasMore("Button pressed.", languageCode: "en"), "'but' is not 'button'")
        XCTAssertTrue(ReplyCaveatCue.hasMore("I couldn’t reach the porch light.", languageCode: "en-GB"))
    }

    func testTwoDoneActionsAreQuietWithOneSummary() {
        let music = call("music_control", completion: .done(summary: "Paused"))
        XCTAssertEqual(verdict(input([timer, music], utterance: "Set a timer for ten minutes and pause the music",
                                     reply: "Timer set and music paused.")),
                       .quiet(summary: "Timer 10 minutes · Paused"))
    }

    func testTheSummaryNamesEachThingOnce() {
        XCTAssertEqual(QuietTurnJudge.summary(of: [timer, timer, lightsOff]), "Timer 10 minutes · Kitchen lights off")
        XCTAssertEqual(QuietTurnJudge.summary(of: []), "Done")
    }

    func testALanguageWithNoWordListsSpeaks() {
        XCTAssertEqual(verdict(input([lightsOff], utterance: "Mach das Küchenlicht aus", reply: "Licht aus.",
                                     language: "de-DE")),
                       .speak(reason: .askedQuestion), "decision 8: no list, so it speaks")
        XCTAssertTrue(ReplyCaveatCue.hasMore("Licht aus.", languageCode: "de"))
        XCTAssertEqual(AppState.quietTurnLanguage(preference: "auto", preferred: ["fr-FR"]), "fr")
        XCTAssertEqual(AppState.quietTurnLanguage(preference: "en-AU", preferred: ["de-DE"]), "en")
    }

    func testTheVerdictTokensAreContentFree() {
        XCTAssertEqual(QuietTurnVerdict.quiet(summary: "Kitchen lights off").traceToken, "quiet")
        XCTAssertEqual(QuietTurnVerdict.speak(reason: .lookup).traceToken, "speak: lookup")
    }

    // MARK: - The gate's questions

    func testThePreambleIsHeldOnlyWhenEveryCallIsAReviewedAction() {
        XCTAssertTrue(QuietTurnJudge.holdsPreamble(forRound: [lightsOff, timer]))
        XCTAssertFalse(QuietTurnJudge.holdsPreamble(forRound: []))
        XCTAssertFalse(QuietTurnJudge.holdsPreamble(forRound: [lightsOff, call("get_weather", effect: .readOnly)]))
        XCTAssertFalse(QuietTurnJudge.holdsPreamble(forRound: [call("mcp__x", native: false)]))
        XCTAssertFalse(QuietTurnJudge.holdsPreamble(forRound: [call("navigate")]))
        XCTAssertTrue(QuietTurnJudge.holdsNextIteration(afterRound: [lightsOff, timer]))
        XCTAssertFalse(QuietTurnJudge.holdsNextIteration(afterRound: [lightsOff, call("set_timer", completion: nil)]))
    }
}

// MARK: - The stream gate

@MainActor
final class QuietStreamGateTests: XCTestCase {

    private let done = QuietTurnCall(tool: "smart_home", effect: .physicalActuation, outcome: .completed,
                                     completion: .done(summary: "Lights off"), isNative: true)
    private let lookup = QuietTurnCall(tool: "get_weather", effect: .readOnly, outcome: .completed,
                                       completion: nil, isNative: true)

    private var quietRules: StreamSpeechGate.Rules {
        var rules = StreamSpeechGate.Rules()
        rules.holdPreamble = QuietTurnJudge.holdsPreamble(forRound:)
        rules.holdNextIteration = QuietTurnJudge.holdsNextIteration(afterRound:)
        return rules
    }

    func testTheDefaultRulesReleaseThePreambleAsToday() {
        let gate = StreamSpeechGate()
        _ = gate.ingest("Turning off the kitchen lights now.")
        XCTAssertEqual(gate.endIteration(roundCalls: [done]), ["Turning off the kitchen lights now."])
        XCTAssertFalse(gate.isHolding)
    }

    func testAReviewedActionsPreambleIsHeldAndTheReplyAfterItIsHeldWhole() {
        let gate = StreamSpeechGate(rules: quietRules)
        _ = gate.ingest("Turning off the kitchen lights now.")
        XCTAssertEqual(gate.endIteration(roundCalls: [done]), [])
        XCTAssertEqual(gate.heldPreambles, ["Turning off the kitchen lights now."])
        XCTAssertEqual(gate.holdReason, .quietCandidate)
        XCTAssertEqual(gate.ingest("The kitchen lights are off now. Anything else at all?"), [],
                       "the final iteration waits for the verdict")
        XCTAssertTrue(gate.text.contains("kitchen lights are off"))
    }

    func testALookupsPreambleIsSaidAsToday() {
        let gate = StreamSpeechGate(rules: quietRules)
        _ = gate.ingest("Let me check the forecast for you.")
        XCTAssertEqual(gate.endIteration(roundCalls: [lookup]), ["Let me check the forecast for you."])
        XCTAssertFalse(gate.isHolding)
    }

    func testAQuietCandidateThatCallsAnotherToolEndsLikeAnyIteration() {
        let gate = StreamSpeechGate(rules: quietRules)
        _ = gate.ingest("Turning off the lights.")
        _ = gate.endIteration(roundCalls: [done])
        _ = gate.ingest("Now let me check the forecast for you.")
        XCTAssertEqual(gate.endIteration(roundCalls: [lookup]), ["Now let me check the forecast for you."])
        XCTAssertFalse(gate.isHolding)
    }

    func testAStreamedQuietTurnSaysNothingAndASpokenOneSaysOnlyTheReply() async {
        let speech = RecordingStreamedSpeech()
        var calls: [QuietTurnCall] = []
        let stream = DirectReplySpeechStream(speaker: speech, rules: quietRules, turnCalls: { calls })
        stream.streamDidReset()                       // the first request
        stream.ingest("Turning off the kitchen lights now.")
        calls = [done]
        stream.streamDidReset()                       // the tool ran; the second request
        stream.ingest("The kitchen lights are off now.")
        XCTAssertTrue(stream.isHoldingForVerdict)
        XCTAssertFalse(stream.didStream, "nothing has been said")
        await stream.finishQuietly()
        XCTAssertEqual(speech.played, [])
        XCTAssertEqual(speech.wholeReplies, [])
        XCTAssertEqual(stream.preambles, [], "a held preamble is not a transcript line")

        // The same turn judged spoken: the reply alone, said once.
        await stream.finish(reply: "The kitchen lights are off now.")
        XCTAssertEqual(speech.wholeReplies, ["The kitchen lights are off now."])
    }
}

// MARK: - Tools report

@MainActor
final class ActionCompletionReportTests: XCTestCase {

    private func report(_ work: () async throws -> String) async rethrows -> (String, ActionCompletion?) {
        try await ActionCompletionReport.collect {
            try await ActionCompletionReport.capture(isRoot: true) { try await work() }
        }
    }

    func testARootCallsReportReachesTheCollectorAndTheLastWordWins() async {
        let (_, completion) = await report {
            ActionCompletionReport.record(.done(summary: "Timer 1 minute"))
            ActionCompletionReport.record(.partial(reason: .leftNotification))
            return "ok"
        }
        XCTAssertEqual(completion, .partial(reason: .leftNotification))
    }

    func testAComposedChildsReportNeverStandsForItsParent() async {
        let (_, completion) = await report {
            await ActionCompletionReport.capture(isRoot: false) {
                ActionCompletionReport.record(.done(summary: "child"))
            }
            return "parent"
        }
        XCTAssertNil(completion)
    }

    func testOutsideANativeToolsCallARecordGoesNowhere() async {
        ActionCompletionReport.record(.done(summary: "stray"))
        let (_, completion) = await ActionCompletionReport.collect { () async -> String in
            ActionCompletionReport.record(.done(summary: "an MCP server's path has no slot"))
            return "ok"
        }
        XCTAssertNil(completion, "only the router's per-call slot accepts a report")
    }

    func testTheLedgerKeepsAReportOnlyForACompletedCall() {
        var ledger = AttemptToolLedger()
        let before = ledger.generation
        ledger.reset()
        XCTAssertEqual(ledger.generation, before + 1)
        let ok = ledger.dispatched(tool: "set_timer", arguments: "{}", effect: .localMutation, isNative: true)
        let late = ledger.dispatched(tool: "smart_home", arguments: "{}", effect: .physicalActuation, isNative: true)
        ledger.finished(ok, outcome: .completed("Timer set."), completion: .done(summary: "Timer"))
        ledger.finished(late, outcome: .outcomeUnknown(operationID: "x", message: "timed out"),
                        completion: .done(summary: "Lights off"))
        let calls = ledger.quietCalls()
        XCTAssertEqual(calls.map(\.outcome), [.completed, .outcomeUnknown])
        XCTAssertEqual(calls[0].completion, .done(summary: "Timer"))
        XCTAssertNil(calls[1].completion, "a timed-out call's 'done' was never waited for")
        XCTAssertEqual(ledger.quietCalls(from: 1).map(\.tool), ["smart_home"])
    }

    // MARK: - The starter set

    private var spotifyOpened = true

    private func music(homeAssistant: Bool = false, speakers: [HomeAssistantMediaPlayer] = []) -> MusicControlTool {
        var tool = MusicControlTool()
        let apple = RecordingMusicProvider(id: .appleMusic)
        let speaker = RecordingMusicProvider(id: .homeAssistant)
        let client = FakeHomeAssistant()
        client.players = speakers
        tool.makeEnvironment = { [unowned self] in
            MusicControlEnvironment(
                appleMusic: apple, homeAssistant: homeAssistant ? speaker : nil,
                homeAssistantClient: homeAssistant ? client : nil,
                homeAssistantUnavailableLine: homeAssistant ? nil : MusicPhraser.speakersNeedHomeAssistant,
                defaultProvider: .appleMusic, defaultSpeakerEntityId: nil, hiddenSpeakers: [],
                askWhenUnsure: true, appleMusicPlaying: { false }, postUserPlaybackRequested: {},
                openSpotifySearch: { [unowned self] _ in self.spotifyOpened })
        }
        return tool
    }

    func testMusicSpotifySearchIsHandedToTheAppNotDone() async throws {
        let (_, completion) = try await report {
            try await music().execute(args: ["action": "play", "query": "Bohemian Rhapsody on Spotify"])
        }
        XCTAssertEqual(completion, .partial(reason: .handedToApp))
    }

    func testMusicTransportAndApplePlaybackAreDoneAndReadsReportNothing() async throws {
        let (_, pause) = try await report { try await music().execute(args: ["action": "pause"]) }
        XCTAssertEqual(pause, .done(summary: "Paused"))
        let (_, play) = try await report { try await music().execute(args: ["action": "play_song", "query": "Dreams"]) }
        XCTAssertEqual(play?.isDone, true)
        let (_, now) = try await report { try await music().execute(args: ["action": "now_playing"]) }
        XCTAssertNil(now)
        let (_, missing) = try await report { try await music().execute(args: ["action": "play_song"]) }
        XCTAssertEqual(missing, .awaitingWearer, "'what song?' waits on the wearer")
    }

    func testMusicASpeakerAskedToPlayByNameIsNotVouchedFor() {
        let request = MusicToolRequest.parse(action: "play", args: ["query": "Rumours"])
        XCTAssertNil(MusicControlTool.completion(for: request, result: .done("ok"), route: .homeAssistant))
        XCTAssertEqual(MusicControlTool.completion(for: request, result: .done("ok"), route: .appleMusic)?.isDone, true)
        XCTAssertNil(MusicControlTool.completion(for: request, result: .failed("no"), route: .appleMusic))
    }

    func testHomeAssistantIsDoneOnlyWhenItReportsTheStateAskedFor() {
        func body(_ state: String, entity: String = "light.kitchen") -> Data {
            try! JSONSerialization.data(withJSONObject: [["entity_id": entity, "state": state,
                                                          "attributes": ["friendly_name": "Kitchen lights"]]])
        }
        XCTAssertEqual(HomeAssistantCompletion.completion(service: "turn_off", entityId: "light.kitchen",
                                                          responseBody: body("off")),
                       .done(summary: "Kitchen lights off"))
        XCTAssertEqual(HomeAssistantCompletion.completion(service: "turn_off", entityId: "light.kitchen",
                                                          responseBody: body("on")),
                       .partial(reason: .unverified), "the light did not go off")
        XCTAssertEqual(HomeAssistantCompletion.completion(service: "turn_off", entityId: "light.kitchen",
                                                          responseBody: Data("[]".utf8)),
                       .partial(reason: .unverified), "nothing confirmed the change")
        XCTAssertEqual(HomeAssistantCompletion.completion(service: "lock", entityId: "lock.front_door",
                                                          responseBody: body("locked", entity: "lock.front_door")),
                       .partial(reason: .unverified), "a door is never quiet")
        XCTAssertEqual(HomeAssistantCompletion.completion(service: "trigger", entityId: "automation.night",
                                                          responseBody: body("on", entity: "automation.night")),
                       .partial(reason: .unverified))
    }

    func testTheOtherStarterToolsReportDone() {
        XCTAssertEqual(TimerTool.doneSummary(label: nil, duration: "10 minutes"), "Timer 10 minutes")
        XCTAssertEqual(TimerTool.doneSummary(label: "pasta", duration: "8 minutes"), "Pasta timer 8 minutes")
        XCTAssertEqual(FlashlightTool.completion(turnedOn: false), .done(summary: "Torch off"))
        XCTAssertEqual(BrightnessTool.completion(percent: 50), .done(summary: "Brightness 50%"))
        XCTAssertEqual(SaveNoteTool.completion(title: nil), .done(summary: "Note saved"))
        XCTAssertEqual(AppleRemindersTool.addedCompletion(title: "Milk"), .done(summary: "Reminder: Milk"))
        XCTAssertEqual(PomodoroTool.startCompletion(isBreak: false, minutes: 25, notificationScheduled: true),
                       .done(summary: "Focus 25 minutes"))
        XCTAssertEqual(PomodoroTool.startCompletion(isBreak: false, minutes: 25, notificationScheduled: false),
                       .partial(reason: .unverified), "without its notification the end would go unannounced")
    }

    func testATorchTheDeviceDoesNotHaveReportsNothing() async throws {
        // The simulator has no torch: the tool says so, and nothing is vouched for.
        let (text, completion) = try await report { try await FlashlightTool().execute(args: ["action": "on"]) }
        if text.contains("doesn't have a flashlight") { XCTAssertNil(completion) }
    }
}

// MARK: - The roster

final class ActionCompletionRosterTests: XCTestCase {

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    /// Every file that reports a completion, with the tool name it declares.
    private func reporters() throws -> [(path: String, code: String)] {
        let enumerator = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        var found: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("ActionCompletionReport.record(") {
                found.append((url.path.replacingOccurrences(of: Self.sources.path + "/", with: ""), code))
            }
        }
        return found
    }

    func testOnlyNativeToolsReportAndEveryDoneComesFromAReviewedTool() throws {
        let files = try reporters()
        XCTAssertFalse(files.isEmpty, "the scan found the starter set")
        for (path, code) in files {
            XCTAssertTrue(path.hasPrefix("Services/NativeTools/"),
                          "\(path) reports a completion from outside the native tools")
            guard code.contains(".done(summary") else { continue }
            let names = code.components(separatedBy: "let name = \"").dropFirst()
                .compactMap { $0.split(separator: "\"").first.map(String.init) }
            XCTAssertFalse(names.isEmpty, "\(path) reports done without declaring a tool name")
            for name in names where !QuietActionRoster.isReviewed(name) {
                // A file may hold several tools; the one that reports must be reviewed.
                XCTAssertTrue(names.contains(where: QuietActionRoster.isReviewed),
                              "\(path): '\(name)' reports .done but is not on the reviewed list")
            }
        }
    }

    func testTheReviewedListIsTheStarterSet() {
        XCTAssertEqual(QuietActionRoster.reviewed, [
            "set_timer", "set_alarm", "reminder", "flashlight", "brightness", "music_control",
            "home_assistant", "smart_home", "save_note", "save_location", "pomodoro",
        ])
        XCTAssertTrue(QuietActionRoster.reviewed.isDisjoint(with: QuietActionRoster.neverQuiet))
    }
}

// MARK: - The tone, the words and the record

@MainActor
final class QuietDoneCueTests: XCTestCase {

    func testTheDoneToneIsUnlikeEverySoundTheAppMakes() {
        let others: [String: [Double]] = [
            "listening start": ListeningCuePolicy.start.map(\.frequency),
            "listening end": ListeningCuePolicy.end.map(\.frequency),
            "link lost": GlassesLinkCuePolicy.lostEarcon.map(\.frequency),
            "connect": [660, 990],
            "disconnect": [440, 330],
            "recovery": [523, 659, 784],
            "photo": [1200],
            "failure": [311, 311],
            "metronome": [1000],
        ]
        var all = others
        for earcon in TempleEarcon.allCases where !earcon.tones.isEmpty {
            all["temple \(earcon)"] = earcon.tones.map(\.frequency)
        }
        for (name, notes) in all {
            XCTAssertTrue(QuietDoneCue.isDistinct(QuietDoneCue.frequencies, from: notes),
                          "the done tone could be taken for the \(name) sound")
        }
        XCTAssertEqual(QuietDoneCue.contour(QuietDoneCue.frequencies), .rising)
        XCTAssertLessThan(QuietDoneCue.seconds, 0.3)
        XCTAssertEqual(QuietDoneCue.volume, 0.35, "half the other earcons' 0.7: −6 dB")
    }

    func testTheDistinctnessRuleItself() {
        XCTAssertFalse(QuietDoneCue.isDistinct([740, 1109], from: [760, 1140]), "a semitone apart is the same sound")
        XCTAssertTrue(QuietDoneCue.isDistinct([740, 1109], from: [1109, 740]), "another contour")
        XCTAssertTrue(QuietDoneCue.isDistinct([740, 1109], from: [740, 1109, 1400]), "another length")
    }

    func testVoiceOverHearsDoneOnlyWithSpokenCuesOn() {
        XCTAssertTrue(QuietDoneCue.speaksMeaning(voiceOverRunning: true, spokenCuesOn: true))
        XCTAssertFalse(QuietDoneCue.speaksMeaning(voiceOverRunning: true, spokenCuesOn: false))
        XCTAssertFalse(QuietDoneCue.speaksMeaning(voiceOverRunning: false, spokenCuesOn: true))
    }

    func testTheSoundTourTeachesIt() {
        XCTAssertTrue(AudibleLifecyclePolicy.lessons.contains { $0.earcon == .done && $0.meaning == QuietDoneCue.tourLine })
    }

    func testWhatWasThatReplaysForThirtySeconds() {
        var window = QuietReplayWindow()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(window.replay(for: "what was that", at: start))
        window.noteQuietTurn(reply: "Kitchen lights off.", at: start)
        XCTAssertEqual(window.replay(for: "What was that?", at: start.addingTimeInterval(5)), "Kitchen lights off.")
        XCTAssertEqual(window.replay(for: "say it please", at: start.addingTimeInterval(29)), "Kitchen lights off.")
        XCTAssertNil(window.replay(for: "what was that", at: start.addingTimeInterval(31)))
        XCTAssertNil(window.replay(for: "what was that song", at: start.addingTimeInterval(1)),
                     "only the phrase itself, never a new question that starts like it")
        window.close()
        XCTAssertNil(window.replay(for: "what was that", at: start.addingTimeInterval(1)))
    }

    func testAQuietReplyIsNeverCountedAsUnheard() {
        XCTAssertFalse(TurnBackgroundTime.replyWentUnheard(.quiet, appInBackground: true, routePlaysWhileAway: false))
    }

    func testTheStoredTurnCarriesItsMarkAndOldThreadsDecodeUnchanged() throws {
        let plain = ConversationMessage(role: "assistant", content: "Paused.")
        XCTAssertNil(plain.endedQuietly)
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("endedQuietly"), "an ordinary reply's file does not grow")

        let quiet = ConversationMessage(role: "assistant", content: "Paused.", toolNames: ["music_control"],
                                        endedQuietly: true)
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(quiet))
        XCTAssertTrue(decoded.isEndedQuietly)

        let legacy = Data(#"{"id":"1","role":"assistant","content":"Hi","imageAttached":false,"timestamp":0}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ConversationMessage.self, from: legacy).isEndedQuietly)
    }

    func testThePromptExceptionIsThereOnlyWithTheSettingOn() {
        XCTAssertEqual(QuietAfterActionsPrompt.exception(enabled: false, simpleMode: false), "")
        XCTAssertEqual(QuietAfterActionsPrompt.exception(enabled: true, simpleMode: true), "")
        XCTAssertTrue(QuietAfterActionsPrompt.exception(enabled: true, simpleMode: false).contains("EXCEPTION"))
    }

    func testTheWatchSpellsTheSameMessage() throws {
        let watch = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlassesWatch/WatchConnectivityService.swift")
        let code = try String(contentsOf: watch, encoding: .utf8)
        XCTAssertTrue(code.contains("message[\"\(QuietDoneWatchMessage.key)\"] as? String == \"\(QuietDoneWatchMessage.value)\""))
        XCTAssertTrue(code.contains("play(.success)"))
    }
}
