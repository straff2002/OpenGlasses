import XCTest
@testable import OpenGlasses

/// Plan MO P2: what the session does for its surfaces, headless with P1's fakes — the delivery the
/// sheet chose, "show hints", repeat and skip, a keyword added mid-session, the speaker chips, the
/// talk note's hand-over at stop, the demo's notice and the background stop.
@MainActor
final class LiveHintsSessionSurfacesTests: XCTestCase {

    private var captions: FakeHintCaptions!
    private var documents: FakeHintDocuments!
    private var model: FakeHintModel!
    private var lens: FakeHintLens!
    private var ear: FakeHintEar!
    private var voice: FakeHintVoiceActivity!
    private var list: LiveHintsPhoneList!
    private var clock: FakeHintClock!

    private let question = "What's the warranty on the compressor?"

    override func setUp() async throws {
        captions = FakeHintCaptions()
        documents = FakeHintDocuments()
        documents.passages = [HintPassage(
            documentId: "doc-1", documentName: "Service terms", chunkIndex: 3,
            text: "Parts are covered for a year. The compressor warranty runs 12 weeks from the install date.")]
        model = FakeHintModel()
        model.isAvailable = false
        lens = FakeHintLens()
        ear = FakeHintEar()
        voice = FakeHintVoiceActivity()
        list = LiveHintsPhoneList()
        clock = FakeHintClock(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        model.clock = clock
    }

    private func makeService() -> LiveHintsService {
        let service = LiveHintsService(carriers: .init(
            captions: captions, documents: documents, model: model, lens: lens, ear: ear,
            voiceActivity: voice, phoneList: list, clock: clock, allowance: FakeHintAllowance()))
        service.isEnabled = { true }
        service.firstRunAcknowledged = { true }
        service.setFirstRunAcknowledged = { _ in }
        return service
    }

    private func settings(_ build: (inout LiveHintsService.Settings) -> Void) -> LiveHintsService.Settings {
        var settings = LiveHintsService.Settings()
        build(&settings)
        return settings
    }

    // MARK: - Delivery

    func testTheEarWhenTheWearerChoseItEvenWithALens() async {
        let service = makeService()
        service.start(settings { $0.delivery = .ear })
        captions.say(question, speaker: 1)
        await service.waitUntilIdle()
        XCTAssertTrue(lens.presented.isEmpty, "the wearer chose the ear")
        XCTAssertEqual(ear.spoken.count, 1)
        XCTAssertEqual(list.hints.count, 1, "and on the phone")
        service.stop()
    }

    func testTheLensWhenChosenAndThere() async {
        let service = makeService()
        service.start(settings { $0.delivery = .lens })
        captions.say(question, speaker: 1)
        await service.waitUntilIdle()
        XCTAssertEqual(lens.presented.count, 1)
        XCTAssertTrue(ear.spoken.isEmpty)
        service.stop()
    }

    func testTheLensChoiceFallsBackToTheEarWithNoLens() async {
        lens.isAvailable = false
        let service = makeService()
        service.start(settings { $0.delivery = .lens })
        captions.say(question, speaker: 1)
        await service.waitUntilIdle()
        XCTAssertTrue(lens.presented.isEmpty)
        XCTAssertEqual(ear.spoken.count, 1)
        service.stop()
    }

    // MARK: - Show hints, repeat, skip

    func testShowHintsBringsTheLastHintBackOverADismissedLens() async {
        lens.accepts = false
        let service = makeService()
        service.start()
        XCTAssertFalse(service.showHintsAgain(), "nothing to show yet")
        captions.say(question, speaker: 1)
        await service.waitUntilIdle()
        XCTAssertTrue(lens.presented.isEmpty, "the wearer had dismissed the lens")
        XCTAssertTrue(service.hasHint)
        XCTAssertTrue(service.showHintsAgain())
        XCTAssertEqual(lens.reshown.map(\.question), [question])
        service.stop()
        XCTAssertFalse(service.showHintsAgain(), "not after stop")
    }

    func testRepeatOnTheLensShowsItAgainAndInTheEarSaysItAgain() async {
        let service = makeService()
        service.start()
        captions.say(question, speaker: 1)
        await service.waitUntilIdle()
        service.repeatLastHint()
        XCTAssertEqual(lens.reshown.count, 1)
        XCTAssertTrue(ear.spoken.isEmpty)
        service.stop()

        let earService = makeService()
        earService.start(settings { $0.delivery = .ear })
        captions.say("What is the warranty on the roof membrane?", speaker: 1)
        await earService.waitUntilIdle()
        XCTAssertEqual(ear.spoken.count, 1)
        ear.onFinishedSpeaking?()
        XCTAssertFalse(earService.isHintPlaying)
        earService.repeatLastHint()
        XCTAssertEqual(ear.spoken.count, 2, "said again")
        XCTAssertTrue(earService.isHintPlaying, "and a tap now skips it")
        earService.skipHint()
        XCTAssertFalse(earService.isHintPlaying)
        XCTAssertGreaterThanOrEqual(ear.stops, 1)
        earService.stop()
    }

    // MARK: - A keyword mid-session

    func testAKeywordAddedBySpeechFiresInKeywordModeAndJoinsTheVocabulary() async {
        documents.passages = [HintPassage(documentId: "doc-2", documentName: "Price list", chunkIndex: 0,
                                          text: "The Tecumseh compressor has a two-year cover.")]
        let service = makeService()
        service.start(settings { $0.mode = .keyword; $0.keywords = ["warranty"] })
        XCTAssertTrue(service.addKeyword("Tecumseh"))
        XCTAssertFalse(service.addKeyword("tecumseh"), "a repeat")
        XCTAssertEqual(service.settings.keywords, ["warranty", "Tecumseh"])
        XCTAssertTrue(captions.contextualStrings.contains("Tecumseh"))
        captions.say("We fitted a Tecumseh unit last spring.", speaker: 1)
        await service.waitUntilIdle()
        XCTAssertEqual(list.hints.first?.keyword, "Tecumseh")
        service.stop()
        XCTAssertFalse(service.addKeyword("roof"), "not after stop")
    }

    // MARK: - Voices

    func testTheSpeakerChipsAreTheVoicesHeardThisSessionAndGoWithIt() {
        let service = makeService()
        service.start()
        captions.say("Hello there, nice to meet you.", speaker: 2)
        captions.say("Likewise, thanks for coming.", speaker: 0)
        captions.say("Shall we start?", speaker: 2)
        captions.say("An unlabelled line from the phone.")
        XCTAssertEqual(service.heardSpeakers, [2, 0])
        service.markWearer(speaker: 0)
        XCTAssertEqual(service.wearerSpeaker, 0)
        service.stop()
        XCTAssertTrue(service.heardSpeakers.isEmpty)
        XCTAssertNil(service.wearerSpeaker)
    }

    // MARK: - The talk note's hand-over

    func testWithTheTalkNoteOnTheSessionHandsItsCaptionsOutOnceAtStop() {
        let service = makeService()
        service.speakerLabel = { "Speaker \($0 + 1)" }
        var endings: [LiveHintsService.Ending] = []
        service.onEnded = { endings.append($0) }
        service.start(settings { $0.talkNote = true })
        captions.say("Thanks for coming over.", speaker: 1)
        captions.say("[Visual: a garden]")
        captions.say("Happy to help.")
        service.stop()
        XCTAssertEqual(endings.count, 1)
        XCTAssertEqual(endings.first?.lines, ["Speaker 2: Thanks for coming over.", "Happy to help."])
        XCTAssertEqual(endings.first?.reason, .wearer)
        XCTAssertTrue(endings.first?.settings.talkNote == true)
        service.stop()
        XCTAssertEqual(endings.count, 1, "once")
    }

    func testWithTheTalkNoteOffNoCaptionIsHeld() {
        let service = makeService()
        var endings: [LiveHintsService.Ending] = []
        service.onEnded = { endings.append($0) }
        service.start()
        captions.say("Thanks for coming over.", speaker: 1)
        service.stop()
        XCTAssertEqual(endings.first?.lines, [])
    }

    func testHintsAreNeverPartOfTheTalkNote() async {
        let service = makeService()
        var endings: [LiveHintsService.Ending] = []
        service.onEnded = { endings.append($0) }
        service.start(settings { $0.talkNote = true })
        captions.say(question, speaker: 1)
        await service.waitUntilIdle()
        let hint = list.hints.first?.line ?? ""
        XCTAssertFalse(hint.isEmpty)
        service.stop()
        XCTAssertEqual(endings.first?.lines, [question])
        XCTAssertFalse(endings.first?.lines.contains(hint) ?? true)
    }

    // MARK: - Notices and stops

    func testTheDemoSaysItIsOne() {
        let service = makeService()
        service.captureNotice = LiveHintsCopy.demoNotice
        service.start()
        XCTAssertEqual(service.notice, LiveHintsCopy.demoNotice)
        service.stop(reason: .demoEnded)
        XCTAssertEqual(service.lastStopReason, .demoEnded)
    }

    func testTheBackgroundStopSaysWhy() {
        let service = makeService()
        service.start()
        service.stop(reason: .background)
        XCTAssertEqual(service.lastStopReason, .background)
        XCTAssertEqual(service.notice, LiveHintsCopy.backgroundStopped)
        XCTAssertEqual(ear.spoken.last, LiveHintsCopy.backgroundStopped, "said in the ear, never the phone speaker")
    }
}

/// Plan MO P2 (§9): the talk note is kept as a finished conversation with its note, never made the
/// open conversation, and refused where the store refuses notes.
@MainActor
final class LiveHintsTalkNoteStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mo-talk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        PolicyEnvelope.clear()
    }

    override func tearDown() async throws {
        PolicyEnvelope.clear()
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheNoteIsAFinishedConversationThatIsNotTheOpenOne() {
        let store = ConversationStore(directory: directory)
        let open = store.startThread(mode: "direct")
        let points = [ConversationDigest.Point(kind: .learned, text: "Install is three days.")]
        let saved = store.saveTalkNote(title: "Garden studio visit", text: "Garden studio visit\n• Install is three days.",
                                       points: points, endedAt: Date(), tier: .cloud)
        XCTAssertEqual(saved.outcome, .saved)
        XCTAssertEqual(store.activeThreadId, open.id, "the wearer's open conversation is untouched")
        let thread = store.threads.first { $0.id == saved.threadId }
        XCTAssertEqual(thread?.title, "Garden studio visit")
        XCTAssertEqual(thread?.mode, ConversationStore.talkNoteMode)
        XCTAssertEqual(thread?.messages.count, 1)
        XCTAssertEqual(thread?.digest?.points, points)
        XCTAssertEqual(thread?.digest?.coversThroughMessageID, thread?.messages.first?.id)

        let reopened = ConversationStore(directory: directory)
        XCTAssertEqual(reopened.threads.first { $0.id == saved.threadId }?.digest?.headline, "Garden studio visit")
    }

    func testAnOrganisationsPinOnNotesRefusesIt() {
        let store = ConversationStore(directory: directory)
        store.digestsPinnedOff = { true }
        let saved = store.saveTalkNote(title: "A", text: "A", points: [], endedAt: Date(), tier: .cloud)
        XCTAssertEqual(saved.outcome, .orgPinnedOff)
        XCTAssertNil(saved.threadId)
        XCTAssertTrue(store.threads.isEmpty)
    }
}
