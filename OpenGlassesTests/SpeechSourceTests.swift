import XCTest
@testable import OpenGlasses

/// Plan KL P4 — a spoken line's source in the log and the support report, and the 94-character
/// line it named: the conversation cue's once-ever introduction, which a voice turn used to await
/// before doing anything else.
@MainActor
final class SpeechSourceTests: XCTestCase {

    // MARK: - The log line and the report

    /// The source is a token beside the length, and nothing else about the line is added.
    func testTheSpeakingLineRendersTheSourceBesideTheLength() {
        let line = PrivacyEventEncoder.encode(
            PrivacyLog.tts(.speaking, engine: PrivacyToken("elevenLabs-system"), characters: 94,
                           source: SpeechSource.disclosure.token, detail: PrivacyToken("quotaOk")))
        XCTAssertEqual(line, "[speech] tts event=speaking engine=elevenLabs-system characters=94 "
                       + "source=disclosure detail=quotaOk")
    }

    /// A streamed sentence's line says what the reply is, the same way.
    func testAStreamedSentenceRendersItsSource() {
        let line = PrivacyEventEncoder.encode(
            PrivacyLog.tts(.speaking, engine: PrivacyToken("system"), characters: 31,
                           source: SpeechSource.reply.token, detail: PrivacyToken("streamed")))
        XCTAssertTrue(line.contains("characters=31 source=reply detail=streamed"), line)
    }

    /// The support report's "App events" section is the event ring's timeline, line for line, so
    /// the source reaches the report next to the length.
    func testTheEventRingCarriesTheSourceIntoTheReport() {
        let ring = DiagnosticRing(capacity: 10)
        let event = PrivacyLog.tts(.speaking, engine: PrivacyToken("system"), characters: 94,
                                   source: SpeechSource.disclosure.token)
        ring.record(event, line: PrivacyEventEncoder.encode(event))
        let lines = ring.timeline.map(\.line)
        XCTAssertTrue(lines.contains { $0.contains("characters=94 source=disclosure") }, "\(lines)")
    }

    /// Every token is its case name: closed, content-free, and stable for a report reader.
    func testEveryTokenIsItsCaseName() {
        for source in SpeechSource.allCases {
            XCTAssertEqual(source.token.description, source.rawValue)
            XCTAssertTrue(source.rawValue.allSatisfy { $0.isLetter }, source.rawValue)
        }
        XCTAssertEqual(Set(SpeechSource.allCases.map(\.rawValue)).count, SpeechSource.allCases.count)
    }

    // MARK: - A queued notice keeps its source

    /// `TurnAnnouncement` hands each notice's source to the speaker, including a notice queued
    /// behind another: the log names the line actually spoken.
    func testAnAnnouncementPassesItsSourceToTheSpeaker() async {
        let spoken = Box<[String]>([])
        let announcement = TurnAnnouncement(
            speak: { text, source in spoken.value.append("\(source.rawValue): \(text)") },
            onFinished: {})
        announcement.announce("Connecting.", source: .disclosure)
        announcement.announce("Switching.", source: .switchNotice)
        await announcement.waitUntilSpoken()
        XCTAssertEqual(spoken.value, ["disclosure: Connecting.", "switchNotice: Switching."])
    }

    // MARK: - The 94-character line

    /// The line finding 7 could not name: 90 characters written, 94 as spoken, because the brand
    /// is said "Ah-Ven-Kin A I". The `speaking` line logs the spoken form's length.
    func testTheIntroductionIsTheNinetyFourCharacterLine() {
        let line = AIDisclosureLedger.conversationIntroduction
        XCTAssertEqual(line.count, 90)
        XCTAssertEqual(SpokenSymbolExpander.spokenForm(of: line).count, 94)
        // The launch's short cue is not it.
        XCTAssertEqual(SpokenSymbolExpander.spokenForm(of: AIDisclosureLedger.text(for: .conversation)).count, 29)
    }

    /// Holds the fake utterance "playing" until the test lets it end.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// The fix: the cue starts and the call returns while it is still playing, so the turn is
    /// classified and its model started alongside it. A reply waiting on the announcement still
    /// hears it out, and the line is logged as a disclosure.
    func testTheCueStartsWithoutHoldingTheTurn() async {
        let ledger = AIDisclosureLedger(introduction: .inMemory(given: false))
        let gate = Gate()
        let log = Box<[String]>([])
        let announcement = TurnAnnouncement(
            speak: { text, source in
                log.value.append("start \(source.rawValue) \(SpokenSymbolExpander.spokenForm(of: text).count)")
                await gate.wait()
                log.value.append("end")
            },
            onFinished: {})

        XCTAssertTrue(ledger.announceConversationCue(cueEnabled: true, through: announcement))
        // Returned before the line has finished: the turn goes on.
        XCTAssertTrue(announcement.isPending)
        log.value.append("turn classified")

        let reply = Task { @MainActor in
            await announcement.waitUntilSpoken()
            log.value.append("reply")
        }
        for _ in 0..<1_000 where !log.value.contains(where: { $0.hasPrefix("start") }) { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(log.value, ["turn classified", "start disclosure 94"],
                       "the turn did not wait for the line, and the reply has not cut it off")
        gate.open()
        await reply.value
        XCTAssertEqual(log.value, ["turn classified", "start disclosure 94", "end", "reply"])
    }

    /// Consumed as before: once per launch, the introduction once per install, nothing when it
    /// has been said, and the cue switch silences only the short line.
    func testTheCueIsSaidOnceAndRespectsTheSwitch() async {
        let spoken = Box<[String]>([])
        let announcement = TurnAnnouncement(speak: { text, _ in spoken.value.append(text) }, onFinished: {})

        let firstEver = AIDisclosureLedger(introduction: .inMemory(given: false))
        XCTAssertTrue(firstEver.announceConversationCue(cueEnabled: false, through: announcement),
                      "the introduction is said whatever the switch says")
        XCTAssertFalse(firstEver.announceConversationCue(cueEnabled: true, through: announcement))

        let laterLaunch = AIDisclosureLedger(introduction: .inMemory(given: true))
        XCTAssertFalse(laterLaunch.announceConversationCue(cueEnabled: false, through: announcement))
        XCTAssertTrue(laterLaunch.announceConversationCue(cueEnabled: true, through: announcement))
        await announcement.waitUntilSpoken()
        XCTAssertEqual(spoken.value, [AIDisclosureLedger.conversationIntroduction,
                                AIDisclosureLedger.text(for: .conversation)])
    }

    /// The voice turn starts the cue through the announcement instead of awaiting it, and each path
    /// after it that speaks waits for the announcement first.
    func testTheVoiceTurnAnnouncesTheCueAndItsSpeakersWait() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift")
        let code = try String(contentsOf: path, encoding: .utf8)
        func body(of signature: String) throws -> Substring {
            let start = try XCTUnwrap(code.range(of: signature), "missing \(signature)")
            let rest = code[start.upperBound...]
            let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
            return rest[..<end]
        }
        let turn = try body(of: "func handleTranscription(_ transcript: String) async {")
        XCTAssertTrue(turn.contains("announceConversationCueIfDue()"))
        XCTAssertFalse(turn.contains("await speakConversationCueIfDue()"),
                       "the voice turn awaits the cue again: the introduction holds the turn ~6 s")
        // After the cue: the reset, the tier-0 answer, the phone's own answer and the agent all
        // wait on the announcement before they speak.
        let afterCue = try XCTUnwrap(turn.range(of: "announceConversationCueIfDue()"))
        let rest = turn[afterCue.upperBound...]
        let reset = try XCTUnwrap(rest.range(of: "conversationReset.requestReset(source: .voiceCommand)"))
        XCTAssertTrue(rest[..<reset.lowerBound].contains("await turnAnnouncement.waitUntilSpoken()"))
        let direct = try XCTUnwrap(rest.range(of: "speechService.speak(result, source: .phoneAnswer)"))
        XCTAssertTrue(rest[reset.upperBound..<direct.lowerBound].contains("await turnAnnouncement.waitUntilSpoken()"))
        for signature in ["private func finishPhoneTurnWithoutModel(",
                          "func runAgentTurn(_ query: String, threadId: String? = nil, admissionID: UUID) async {"] {
            let function = try body(of: signature)
            let speaks = function.components(separatedBy: "await speechService.speak(").count - 1
            let waits = function.components(separatedBy: "await turnAnnouncement.waitUntilSpoken()").count - 1
            XCTAssertGreaterThan(speaks, 0, signature)
            XCTAssertEqual(waits, speaks, "\(signature): every line waits for the announcement")
        }
    }
}
