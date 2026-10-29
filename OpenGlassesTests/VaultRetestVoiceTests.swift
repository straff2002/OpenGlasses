import XCTest
import AVFoundation
@testable import OpenGlasses

// Plan KD P1 — the voice findings of the build 581 vault retest: the app answering its own voice
// over the glasses' speakers, a mic that reopened after every answer, cues that sounded alike, and
// a listener failure that said the wrong thing and never went away.

// MARK: - Item 1: routes with no echo cancellation

final class NoEchoPathRouteTests: XCTestCase {

    /// The build 581 route: the phone's mic chosen, the reply on the glasses' A2DP speakers.
    func testThePhonesMicUnderBluetoothSpeakersHasNoEchoPath() {
        XCTAssertTrue(MicRoutePolicy.hasNoEchoPath(inputs: [.builtInMic], outputs: [.bluetoothA2DP]))
        XCTAssertTrue(MicRoutePolicy.hasNoEchoPath(inputs: [.builtInMic], outputs: [.bluetoothLE]))
    }

    /// Every other device that plays into the room the phone is in.
    func testThePhonesMicUnderAnyRoomSpeakerHasNoEchoPath() {
        for output: AVAudioSession.Port in [.airPlay, .carAudio, .usbAudio, .HDMI, .lineOut,
                                            .bluetoothHFP] {
            XCTAssertTrue(MicRoutePolicy.hasNoEchoPath(inputs: [.builtInMic], outputs: [output]),
                          output.rawValue)
        }
    }

    /// The loudspeaker is still the loudspeaker, whatever the input says.
    func testTheLoudspeakerHasNoEchoPathOnAnyInput() {
        for inputs: [AVAudioSession.Port] in [[.builtInMic], [.bluetoothHFP], [.headsetMic], []] {
            XCTAssertTrue(MicRoutePolicy.hasNoEchoPath(inputs: inputs, outputs: [.builtInSpeaker]))
        }
    }

    /// Mic and speaker on one device cancel their own playback; the earpiece and wired headphones
    /// are not in the room.
    func testRoutesThatKeepTheOverlapTest() {
        XCTAssertFalse(MicRoutePolicy.hasNoEchoPath(inputs: [.bluetoothHFP], outputs: [.bluetoothHFP]))
        XCTAssertFalse(MicRoutePolicy.hasNoEchoPath(inputs: [.bluetoothLE], outputs: [.bluetoothLE]))
        XCTAssertFalse(MicRoutePolicy.hasNoEchoPath(inputs: [.headsetMic], outputs: [.headphones]))
        XCTAssertFalse(MicRoutePolicy.hasNoEchoPath(inputs: [.builtInMic], outputs: [.builtInReceiver]))
        XCTAssertFalse(MicRoutePolicy.hasNoEchoPath(inputs: [.builtInMic], outputs: [.headphones]))
    }

    /// With no input reported only the loudspeaker can be judged — as before this change.
    func testWithNoInputOnlyTheLoudspeakerCounts() {
        XCTAssertFalse(MicRoutePolicy.hasNoEchoPath(inputs: [], outputs: [.bluetoothA2DP]))
        XCTAssertFalse(MicRoutePolicy.hasNoEchoPath(inputs: [], outputs: []))
    }

    /// End to end: on the build 581 route the two field transcripts are refused, and so is a real
    /// interruption — but stop and the wake phrase still cut through.
    func testOnTheGlassesA2DPRouteOnlyStopAndTheWakePhraseInterrupt() {
        let route = MicRoutePolicy.hasNoEchoPath(inputs: [.builtInMic], outputs: [.bluetoothA2DP])
        let speech = BargeInPolicy.AssistantSpeech.speaking(text: VaultRetestTranscripts.ampacityReply,
                                                            openSpeaker: route)
        for heard in [VaultRetestTranscripts.ampacityEcho, "wait what about copper instead"] {
            XCTAssertEqual(BargeInPolicy.decide(transcript: heard, isStopPhrase: false,
                                                matchedWakePhrase: nil, generalBargeInEnabled: true,
                                                assistantSpeech: speech), .ignore, heard)
        }
        XCTAssertEqual(BargeInPolicy.decide(transcript: "stop", isStopPhrase: true,
                                            matchedWakePhrase: nil, generalBargeInEnabled: true,
                                            assistantSpeech: speech), .stop)
        XCTAssertEqual(BargeInPolicy.decide(transcript: "hey claude", isStopPhrase: false,
                                            matchedWakePhrase: "hey claude", generalBargeInEnabled: true,
                                            assistantSpeech: speech),
                       .newConversation(phrase: "hey claude"))
    }

    /// The caller passes the route's inputs, not just its outputs.
    func testTheSpeechContextReadsBothDirectionsOfTheRoute() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("MicRoutePolicy.hasNoEchoPath("))
        XCTAssertTrue(source.contains("inputs: route.inputs.map(\\.portType)"))
        XCTAssertFalse(source.contains("openSpeaker: MicRoutePolicy.isOpenSpeaker("))
    }
}

/// The two transcripts from the field log, and the replies they were heard over.
enum VaultRetestTranscripts {
    static let ampacityReply = "Number 7 AWG aluminum has an ampacity of 47 amperes in the 90 °C column."
    static let ampacityEcho = "aluminum capacity of 42"
    static let vaultReply = "A new job is open in the 2030–29 code vault."
    static let vaultEcho = "in 2000 3029"
}

// MARK: - Item 2: a sturdier echo test

final class NumberAndLongWordEchoTests: XCTestCase {

    private func decide(_ heard: String, over spoken: String) -> BargeInPolicy.Decision {
        BargeInPolicy.decide(transcript: heard, isStopPhrase: false, matchedWakePhrase: nil,
                             generalBargeInEnabled: true,
                             assistantSpeech: .speaking(text: spoken, openSpeaker: false))
    }

    func testTheAmpacityEchoReadsAsTheReply() {
        XCTAssertTrue(BargeInPolicy.echoesSpokenText(VaultRetestTranscripts.ampacityEcho,
                                                     spoken: VaultRetestTranscripts.ampacityReply))
        XCTAssertFalse(BargeInPolicy.readsAsWearer(VaultRetestTranscripts.ampacityEcho,
                                                   spoken: VaultRetestTranscripts.ampacityReply))
        XCTAssertEqual(decide(VaultRetestTranscripts.ampacityEcho,
                              over: VaultRetestTranscripts.ampacityReply), .ignore)
    }

    func testTheVaultNameEchoReadsAsTheReply() {
        XCTAssertTrue(BargeInPolicy.echoesSpokenText(VaultRetestTranscripts.vaultEcho,
                                                     spoken: VaultRetestTranscripts.vaultReply))
        XCTAssertEqual(decide(VaultRetestTranscripts.vaultEcho,
                              over: VaultRetestTranscripts.vaultReply), .ignore)
    }

    /// The wearer cutting in over the same reply is still the wearer.
    func testAGenuineInterruptionOverTheAmpacityReplyStillInterrupts() {
        let heard = "wait what about copper instead"
        XCTAssertEqual(decide(heard, over: VaultRetestTranscripts.ampacityReply),
                       .interrupt(text: heard))
    }

    /// A number of the wearer's own, in a sentence of their own, still counts.
    func testAWearerSentenceWithANumberStillInterrupts() {
        let heard = "what about 90 degrees for copper"
        XCTAssertEqual(decide(heard, over: VaultRetestTranscripts.ampacityReply),
                       .interrupt(text: heard))
    }

    /// Numbers are neutral only while the reply has a number in it. Over a reply with none, the
    /// wearer's digits are as much theirs as any other word.
    func testNumbersAreEvidenceOverAReplyWithNoNumbers() {
        let spoken = "Check the suction line for frost near the compressor."
        XCTAssertTrue(BargeInPolicy.readsAsWearer("2000 3029", spoken: spoken))
        XCTAssertFalse(BargeInPolicy.readsAsWearer("2000 3029", spoken: VaultRetestTranscripts.vaultReply))
    }

    func testNumberTokensAreDigitsWithSeparators() {
        for token in ["42", "3029", "3,029", "2030–29", "4/0", "75.5", "٦٠", "二十"] {
            XCTAssertTrue(BargeInPolicy.isNumberToken(token), token)
        }
        for token in ["", "4th", "awg", "-", "capacity", "2a"] {
            XCTAssertFalse(BargeInPolicy.isNumberToken(token), token)
        }
    }

    func testAReplyMentionsANumberInDigitsOrInWords() {
        XCTAssertTrue(BargeInPolicy.mentionsNumber("Use the 75 °C column."))
        XCTAssertTrue(BargeInPolicy.mentionsNumber("It is rated sixty-five amperes."))
        XCTAssertTrue(BargeInPolicy.mentionsNumber("Il faut quatre conducteurs."))
        XCTAssertTrue(BargeInPolicy.mentionsNumber("気温は二十度です。"))
        XCTAssertFalse(BargeInPolicy.mentionsNumber("Check the suction line for frost."))
    }

    /// Two letters wrong is the reply for a long word, never for a short one.
    func testALongWordMayBeTwoEditsFromTheReply() {
        let vocabulary = BargeInPolicy.spokenVocabulary(VaultRetestTranscripts.ampacityReply)
        XCTAssertTrue(BargeInPolicy.isEcho("capacity", of: vocabulary))
        XCTAssertTrue(BargeInPolicy.isEcho("ampercity", of: vocabulary))
        let short = BargeInPolicy.spokenVocabulary("Check the motor.")
        XCTAssertFalse(BargeInPolicy.isEcho("matar", of: short), "five letters: one edit only")
        XCTAssertTrue(BargeInPolicy.isEcho("moter", of: short))
    }

    func testTheEditAllowanceGrowsWithTheShorterWord() {
        XCTAssertEqual(BargeInPolicy.echoEditAllowance(heardUnits: 3, saidUnits: 9), 0)
        XCTAssertEqual(BargeInPolicy.echoEditAllowance(heardUnits: 4, saidUnits: 4), 1)
        XCTAssertEqual(BargeInPolicy.echoEditAllowance(heardUnits: 6, saidUnits: 9), 1)
        XCTAssertEqual(BargeInPolicy.echoEditAllowance(heardUnits: 7, saidUnits: 7), 2)
        XCTAssertEqual(BargeInPolicy.echoEditAllowance(heardUnits: 9, saidUnits: 8), 2)
    }

    /// The policy stays language-neutral: no locale is read anywhere in it.
    func testThePolicyReadsNoLocale() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/Audio/BargeInPolicy.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["Locale.current", "preferredLanguages", "NLLanguageRecognizer",
                          "languageCode"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}

// MARK: - Item 3: one question per activation

final class SingleQuestionFinishTests: XCTestCase {

    private let key = Config.singleQuestionPerActivationKey
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    func testAnAnswerEndsTheConversationWhenTheSettingIsOn() {
        XCTAssertEqual(FinishStagePolicy.action(listeningEnabled: true, inConversation: true,
                                                singleQuestion: true, answerOwed: false),
                       .endConversation)
    }

    func testAQuestionBackStillGetsItsAnswer() {
        XCTAssertEqual(FinishStagePolicy.action(listeningEnabled: true, inConversation: true,
                                                singleQuestion: true, answerOwed: true),
                       .resumeDictation)
    }

    /// Off is today's conversation, whatever was said.
    func testOffKeepsTheFollowUp() {
        for owed in [true, false] {
            XCTAssertEqual(FinishStagePolicy.action(listeningEnabled: true, inConversation: true,
                                                    singleQuestion: false, answerOwed: owed),
                           .resumeDictation)
        }
    }

    /// An owed answer never reopens a mic the master switch shut, or a conversation that ended.
    func testAnOwedAnswerNeverOverridesTheSwitchOrAClosedConversation() {
        for single in [true, false] {
            XCTAssertEqual(FinishStagePolicy.action(listeningEnabled: false, inConversation: true,
                                                    singleQuestion: single, answerOwed: true),
                           .endConversation)
            XCTAssertEqual(FinishStagePolicy.action(listeningEnabled: true, inConversation: false,
                                                    singleQuestion: single, answerOwed: true),
                           .endConversation)
        }
    }

    func testTheAnswerIsOwedOnAQuestionMarkTheAppsQuestionOrAHandsFreeMode() {
        XCTAssertTrue(FinishStagePolicy.answerOwed(lastSpoken: "Which size did you mean?",
                                                   appAskedQuestion: false, handsFreeModeRunning: false))
        XCTAssertTrue(FinishStagePolicy.answerOwed(lastSpoken: "The breaker is 40 amps.",
                                                   appAskedQuestion: true, handsFreeModeRunning: false))
        XCTAssertTrue(FinishStagePolicy.answerOwed(lastSpoken: nil,
                                                   appAskedQuestion: false, handsFreeModeRunning: true))
        XCTAssertFalse(FinishStagePolicy.answerOwed(
            lastSpoken: "Number 7 aluminum is rated 47 amperes in the 90 °C column.",
            appAskedQuestion: false, handsFreeModeRunning: false))
    }

    /// Punctuation only, in the scripts the app speaks, past closing quotes and brackets.
    func testAQuestionMarkIsReadInEveryScriptAndPastClosingMarks() {
        for text in ["What is the next value?", "Say \"yes\"?\" ", "下一个值是多少？",
                     "ما القيمة التالية؟", "(Which conductor?)", "Ready?\n"] {
            XCTAssertTrue(FinishStagePolicy.endsWithQuestionMark(text), text)
        }
        for text in ["", "Done.", "What happened? It was the fan.", "Is it?.", nil] as [String?] {
            XCTAssertFalse(FinishStagePolicy.endsWithQuestionMark(text), text ?? "nil")
        }
    }

    /// The wording is not read: an answer phrased as a question but ending in a full stop is a
    /// statement, so the rule is the same in every language.
    func testTheRuleReadsNoWording() {
        XCTAssertFalse(FinishStagePolicy.answerOwed(lastSpoken: "What you need is a 4/0 conductor.",
                                                    appAskedQuestion: false, handsFreeModeRunning: false))
    }

    func testTheDefaultFollowsFieldAssistUntilTheWearerChooses() {
        XCTAssertTrue(SingleQuestionDefault.resolve(stored: nil, fieldAssistActive: true))
        XCTAssertFalse(SingleQuestionDefault.resolve(stored: nil, fieldAssistActive: false))
        XCTAssertFalse(SingleQuestionDefault.resolve(stored: false, fieldAssistActive: true))
        XCTAssertTrue(SingleQuestionDefault.resolve(stored: true, fieldAssistActive: false))
    }

    func testTheConfigSettingStoresTheWearersChoice() {
        XCTAssertEqual(Config.singleQuestionPerActivation, Config.fieldAssistActive,
                       "unset, it follows Field Assist")
        Config.singleQuestionPerActivation = true
        XCTAssertTrue(Config.singleQuestionPerActivation)
        Config.singleQuestionPerActivation = false
        XCTAssertFalse(Config.singleQuestionPerActivation)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: key))
    }

    /// The finish stage passes the setting and the owed answer, and the switch sits next to
    /// "Interrupt When You Speak".
    func testTheFinishStageAndSettingsAreWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift"),
                             encoding: .utf8)
        XCTAssertTrue(app.contains("singleQuestion: singleQuestion"))
        XCTAssertTrue(app.contains("let appAskedQuestion = await guidedJobFlow.speakPendingQuestionIfDue()"))
        let settings = try String(contentsOf: root.appendingPathComponent("OpenGlasses/Sources/App/Views/SettingsScreens.swift"),
                                  encoding: .utf8)
        let interrupt = try XCTUnwrap(settings.range(of: "title: \"Interrupt When You Speak\""))
        let single = try XCTUnwrap(settings.range(of: "title: \"One Question at a Time\""))
        XCTAssertLessThan(interrupt.lowerBound, single.lowerBound)
        XCTAssertLessThan(settings.distance(from: interrupt.lowerBound, to: single.lowerBound), 1600)
    }
}

// MARK: - Item 4: distinct cues

final class ListeningCuePolicyTests: XCTestCase {

    private typealias Cues = ListeningCuePolicy

    func testTheStartCueRisesAndTheEndCueFalls() {
        XCTAssertEqual(Cues.start.count, 2)
        XCTAssertEqual(Cues.end.count, 2)
        XCTAssertLessThan(Cues.start[0].frequency, Cues.start[1].frequency)
        XCTAssertGreaterThan(Cues.end[0].frequency, Cues.end[1].frequency)
    }

    func testBothCuesAreBriefAndTheirNotesDoNotOverlap() {
        for cue in [Cues.start, Cues.end] {
            XCTAssertLessThan(Cues.seconds(cue), 0.3)
            for (earlier, later) in zip(cue, cue.dropFirst()) {
                XCTAssertGreaterThanOrEqual(later.start, earlier.end)
            }
        }
    }

    /// The other pairs the app plays: connect, unmute and mute (temple), end of conversation.
    func testNeitherCueSharesAPitchWithAnotherPairOrTheLinkLostFall() {
        // Connect, end of conversation, the session-restored triad, the held and rejected blips.
        let others = Set<Double>([660, 990, 440, 330, 523, 659, 784, 311, 1200])
            .union(GlassesLinkCuePolicy.lostEarcon.map(\.frequency))
            .union(TempleEarcon.allCases.flatMap { $0.tones.map(\.frequency) })
        for cue in [Cues.start, Cues.end] {
            XCTAssertTrue(Set(cue.map(\.frequency)).isDisjoint(with: others))
        }
        XCTAssertTrue(Set(Cues.start.map(\.frequency)).isDisjoint(with: Cues.end.map(\.frequency)))
    }

    func testTheEarconRendersAsOneWAVOfTheRightLength() throws {
        let rate = 44_100.0
        let data = try TextToSpeechService.generateEarconData(notes: Cues.start, sampleRate: rate)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(data.count, 44 + Int(rate * Cues.seconds(Cues.start)) * 2)
    }
}

// MARK: - Item 5: the mic message and the status

final class WakeListenerFailurePolicyTests: XCTestCase {

    private typealias Policy = WakeListenerFailurePolicy

    func testTheMessageNamesTapAndTalkAndOnlyShowsInFront() {
        XCTAssertEqual(Policy.message(appActive: true), Policy.messageText)
        XCTAssertNil(Policy.message(appActive: false), "no tap instruction for a phone in a pocket")
        XCTAssertTrue(Policy.messageText.contains(TalkEntryPolicy.tapAndTalk))
        XCTAssertTrue(Policy.headline.contains(TalkEntryPolicy.tapAndTalk))
        XCTAssertFalse(Policy.messageText.contains("Test Microphone"))
    }

    func testTheListenerIsDownOnlyWhenItIsExpectedAndNotRunning() {
        XCTAssertTrue(Policy.isDown(failed: true, listeningEnabled: true, pushToTalk: false,
                                    micMuted: false, inConversation: false, listenerRunning: false))
        XCTAssertFalse(Policy.isDown(failed: false, listeningEnabled: true, pushToTalk: false,
                                     micMuted: false, inConversation: false, listenerRunning: false))
        XCTAssertFalse(Policy.isDown(failed: true, listeningEnabled: true, pushToTalk: false,
                                     micMuted: false, inConversation: false, listenerRunning: true))
    }

    /// Off by the wearer's choice, or held by a conversation, is not "down".
    func testAListenerMeantToBeOffIsNotDown() {
        XCTAssertFalse(Policy.isDown(failed: true, listeningEnabled: false, pushToTalk: false,
                                     micMuted: false, inConversation: false, listenerRunning: false))
        XCTAssertFalse(Policy.isDown(failed: true, listeningEnabled: true, pushToTalk: true,
                                     micMuted: false, inConversation: false, listenerRunning: false))
        XCTAssertFalse(Policy.isDown(failed: true, listeningEnabled: true, pushToTalk: false,
                                     micMuted: true, inConversation: false, listenerRunning: false))
        XCTAssertFalse(Policy.isDown(failed: true, listeningEnabled: true, pushToTalk: false,
                                     micMuted: false, inConversation: true, listenerRunning: false))
    }

    func testTheHeadlineIsNotReadyWhileTheListenerIsDown() {
        XCTAssertEqual(Policy.directHeadline(isListening: false, isSpeaking: false, listenerDown: true),
                       .notListening)
        XCTAssertEqual(Policy.directHeadline(isListening: false, isSpeaking: false, listenerDown: false),
                       .ready)
        XCTAssertEqual(Policy.directHeadline(isListening: true, isSpeaking: false, listenerDown: true),
                       .listening)
        XCTAssertEqual(Policy.directHeadline(isListening: false, isSpeaking: true, listenerDown: true),
                       .speaking)
    }

    /// The wiring: the old message is gone, a background failure shows no instruction, a running
    /// listener clears only its own message, and the foreground restart reports through the same
    /// path rather than dropping the error.
    func testTheAppWiresTheFailureThroughThePolicy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift"),
                             encoding: .utf8)
        XCTAssertFalse(app.contains("Tap Test Microphone to restart"))
        XCTAssertTrue(app.contains("WakeListenerFailurePolicy.message(appActive: appActive)"))
        XCTAssertTrue(app.contains("if errorMessageIsListenerFailure { errorMessage = nil }"))
        XCTAssertTrue(app.contains("await appState.restartWakeWordOnForeground()"))
        let card = try String(contentsOf: root.appendingPathComponent("OpenGlasses/Sources/App/Views/StatusIndicator.swift"),
                              encoding: .utf8)
        XCTAssertTrue(card.contains("WakeListenerFailurePolicy.directHeadline("))
    }
}
