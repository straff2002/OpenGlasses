import AVFoundation
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan LC P4 (§5): live-mode answers on the lens and the picture behind a vision answer.
/// Headless: the pure tracker, routing, mic and thumbnail pieces directly; the feed, the card and the
/// display through `testRenderSink` and the controllers' scheduling seams (the Display-dependent
/// part is not built in the phone-only lane, where no display exists).
@MainActor
final class LensLiveAndVisionTests: XCTestCase {

    // MARK: - The live turn tracker

    func testATurnIsOneAnswerAtItsEndWithTheWearersWords() {
        var tracker = LiveAnswerTurnTracker()
        XCTAssertFalse(tracker.wearerSpeechStarted())
        tracker.wearerSaid("what size")
        tracker.wearerSaid("what size breaker")
        tracker.assistantSaid("A 20")
        tracker.assistantSaid(" amp breaker.")
        XCTAssertNil(tracker.take(), "nothing is published before the turn ends")
        tracker.turnComplete(publishes: true)
        XCTAssertEqual(tracker.take(), LiveAnswer(text: "A 20 amp breaker.", question: "what size breaker",
                                                  wearerLed: true))
        XCTAssertEqual(tracker, LiveAnswerTurnTracker(), "the next turn starts clean")
    }

    func testATurnTheModelStartedIsNotWearerLed() {
        var tracker = LiveAnswerTurnTracker()
        tracker.assistantSaid("You have a message from Sam.")
        tracker.turnComplete(publishes: true)
        XCTAssertEqual(tracker.take(), LiveAnswer(text: "You have a message from Sam.", question: nil,
                                                  wearerLed: false))
    }

    func testAnOpenTurnTheWearerSpeaksOverIsDropped() {
        var tracker = LiveAnswerTurnTracker()
        tracker.wearerSaid("what's the torque")
        tracker.assistantSaid("The torque for")
        XCTAssertFalse(tracker.interrupted(), "an open turn's fragment is not published")
        tracker.turnComplete(publishes: true)
        XCTAssertNil(tracker.take(), "the fragment is gone")
    }

    func testACompletedTurnCutShortInPlaybackIsWholeAndPublished() {
        var tracker = LiveAnswerTurnTracker()
        tracker.assistantSaid("Forty newton metres.")
        tracker.turnComplete(publishes: true)
        XCTAssertTrue(tracker.interrupted(), "the text is whole: publish it now")
        XCTAssertEqual(tracker.take()?.text, "Forty newton metres.")
    }

    func testAToolCallTurnCarriesTheQuestionToTheAnswerAfterIt() {
        var tracker = LiveAnswerTurnTracker()
        tracker.wearerSaid("what's on my calendar")
        tracker.turnComplete(publishes: true)      // a function call: nothing said
        XCTAssertNil(tracker.take())
        tracker.assistantSaid("Two meetings today.")
        tracker.turnComplete(publishes: true)
        XCTAssertEqual(tracker.take(), LiveAnswer(text: "Two meetings today.", question: "what's on my calendar",
                                                  wearerLed: true))
    }

    func testTheIdleWarningIsNotAnAnswer() {
        var tracker = LiveAnswerTurnTracker()
        tracker.assistantSaid("Are you still there?")
        tracker.turnComplete(publishes: false)
        XCTAssertNil(tracker.take())
        XCTAssertEqual(tracker, LiveAnswerTurnTracker())
    }

    func testLateWordsAreTheCompletedTurnsAndNewSpeechClosesIt() {
        var tracker = LiveAnswerTurnTracker()
        tracker.assistantSaid("It's 3 pm.")
        tracker.turnComplete(publishes: true)
        tracker.wearerSaid("what time is it")       // a JSON provider's transcript, landing late
        XCTAssertTrue(tracker.wearerSpeechStarted(), "new speech publishes the waiting turn first")
        XCTAssertEqual(tracker.take(), LiveAnswer(text: "It's 3 pm.", question: "what time is it", wearerLed: true))
    }

    // MARK: - Where a live card's presses go

    func testDirectModePressesKeepTheirPaths() {
        XCTAssertEqual(LiveAnswerCardRouting.submit(realtimeMode: false, canInject: false, textTurns: false), .direct)
        XCTAssertEqual(LiveAnswerCardRouting.repeatAnswer(realtimeMode: false, canInject: true, textTurns: true,
                                                          suppliedSpeech: true), .direct)
    }

    func testLiveModePressesGoToTheLiveSession() {
        XCTAssertEqual(LiveAnswerCardRouting.submit(realtimeMode: true, canInject: true, textTurns: true), .liveTurn)
        XCTAssertEqual(LiveAnswerCardRouting.submit(realtimeMode: true, canInject: true, textTurns: false), .unavailable,
                       "a protocol with no text lane cannot take More, and Direct is not the wearer's model")
        XCTAssertEqual(LiveAnswerCardRouting.submit(realtimeMode: true, canInject: false, textTurns: true), .unavailable)
        XCTAssertEqual(LiveAnswerCardRouting.repeatAnswer(realtimeMode: true, canInject: true, textTurns: true,
                                                          suppliedSpeech: true), .liveSpeech)
        XCTAssertEqual(LiveAnswerCardRouting.repeatAnswer(realtimeMode: true, canInject: true, textTurns: true,
                                                          suppliedSpeech: false), .liveTurn)
        XCTAssertEqual(LiveAnswerCardRouting.repeatAnswer(realtimeMode: true, canInject: false, textTurns: true,
                                                          suppliedSpeech: true), .unavailable)
    }

    // MARK: - The live session's mic (§2.5 for live modes)

    func testWithTheLensOnALiveSessionCapturesOnThePhoneAndPlaysOnTheGlasses() {
        let lens = LensMicPolicy.liveAudio(cameraOnGlasses: true, interpreting: false, lensOn: true, keepPhoneMic: true)
        XCTAssertEqual(lens, .init(route: .lensPhoneMic, useIPhoneMode: true))
        let noCamera = LensMicPolicy.liveAudio(cameraOnGlasses: false, interpreting: false, lensOn: true, keepPhoneMic: true)
        XCTAssertEqual(noCamera.route, .lensPhoneMic)

        let options = RealtimeAudioRoute.lensPhoneMic.sessionOptions()
        XCTAssertFalse(options.contains(.allowBluetoothHFP), "nothing asks for the glasses' hands-free link")
        XCTAssertTrue(options.contains(.allowBluetoothA2DP), "the answer still plays on the glasses")
        for useIPhoneMode in [true, false] {
            XCTAssertEqual(RealtimeAudioRoute.lensPhoneMic.sessionMode(useIPhoneMode: useIPhoneMode), .default,
                           ".voiceChat and .videoChat both imply HFP")
        }
        XCTAssertTrue(RealtimeAudioRoute.lensPhoneMic.keepsMicOnPhone)
        XCTAssertFalse(RealtimeAudioRoute.standard.keepsMicOnPhone)
    }

    func testWithoutTheLensOrWithTheRollbackLiveAudioIsAsBefore() {
        XCTAssertEqual(LensMicPolicy.liveAudio(cameraOnGlasses: true, interpreting: false, lensOn: false, keepPhoneMic: true),
                       .init(route: .standard, useIPhoneMode: false))
        XCTAssertEqual(LensMicPolicy.liveAudio(cameraOnGlasses: false, interpreting: false, lensOn: false, keepPhoneMic: true),
                       .init(route: .standard, useIPhoneMode: true))
        XCTAssertEqual(LensMicPolicy.liveAudio(cameraOnGlasses: true, interpreting: false, lensOn: true, keepPhoneMic: false),
                       .init(route: .standard, useIPhoneMode: false), "the rollback keeps the glasses mic")
        XCTAssertEqual(LensMicPolicy.liveAudio(cameraOnGlasses: true, interpreting: true, lensOn: true, keepPhoneMic: true),
                       .init(route: .interpreter, useIPhoneMode: false), "the interpreter keeps its own route")
    }

    // MARK: - The thumbnail

    func testTheStripIs552WideAtMost200TallAndKeepsTheFramesAspect() throws {
        let landscape = try XCTUnwrap(HUDAnswerThumbnail.layout(source: CGSize(width: 1440, height: 1080)))
        XCTAssertEqual(landscape.canvas, CGSize(width: 552, height: 200))
        XCTAssertEqual(landscape.image.width, 267)
        XCTAssertEqual(landscape.image.midX, 276, accuracy: 1, "centred")

        let portrait = try XCTUnwrap(HUDAnswerThumbnail.layout(source: CGSize(width: 1080, height: 1440)))
        XCTAssertEqual(portrait.canvas, CGSize(width: 552, height: 200))
        XCTAssertEqual(portrait.image.width, 150)
        XCTAssertEqual(portrait.image.width / portrait.image.height, 0.75, accuracy: 0.01)

        let panorama = try XCTUnwrap(HUDAnswerThumbnail.layout(source: CGSize(width: 3000, height: 1000)))
        XCTAssertEqual(panorama.canvas, CGSize(width: 552, height: 184), "a wide frame gets a shorter strip")
        XCTAssertEqual(panorama.image.width, 552)

        XCTAssertNil(HUDAnswerThumbnail.layout(source: .zero))
    }

    func testTheContentKeyNamesTheFrameWithoutItsPixels() {
        let at = Date(timeIntervalSince1970: 1_000)
        let key = HUDAnswerThumbnail.contentKey(capturedAt: at, byteCount: 4096, pixelSize: CGSize(width: 552, height: 414))
        XCTAssertEqual(key, "lc.answer.frame:1000000:4096:552x414")
        XCTAssertNotEqual(key, HUDAnswerThumbnail.contentKey(capturedAt: at.addingTimeInterval(1), byteCount: 4096,
                                                             pixelSize: CGSize(width: 552, height: 414)))
    }

    func testTheLiftRaisesShadowsAndKeepsBlackClear() {
        XCTAssertEqual(HUDAnswerThumbnail.lift(0), 0, "black stays clear on the lens")
        XCTAssertEqual(HUDAnswerThumbnail.lift(255), 255)
        XCTAssertGreaterThan(HUDAnswerThumbnail.lift(40), 40)
        XCTAssertGreaterThan(HUDAnswerThumbnail.lift(128), 128)
        for value in 1...255 {
            XCTAssertGreaterThanOrEqual(HUDAnswerThumbnail.lift(UInt8(value)), HUDAnswerThumbnail.lift(UInt8(value - 1)))
        }
    }

    func testAFrameDecodesToALiftedStripWithClearPillars() throws {
        let data = try XCTUnwrap(Self.frameJPEG(CGSize(width: 1440, height: 1080), grey: 0.25))
        let picture = try XCTUnwrap(HUDAnswerThumbnail.picture(fromImageData: data, capturedAt: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(picture.pixelSize, CGSize(width: 552, height: 200))
        XCTAssertTrue(picture.contentKey.hasPrefix("lc.answer.frame:5000:\(data.count):"))
        let pillar = try XCTUnwrap(LensPageFixtures.pixel(picture.image, x: 4, y: 100))
        XCTAssertEqual(pillar.r, 0, "past the frame is black, clear on the lens")
        let middle = try XCTUnwrap(LensPageFixtures.pixel(picture.image, x: 276, y: 100))
        XCTAssertGreaterThan(middle.r, 70, "a dark frame is lifted (0.25 grey is about 64 before the lift)")
        XCTAssertNil(HUDAnswerThumbnail.picture(fromImageData: Data([1, 2, 3]), capturedAt: Date()))
    }

    // MARK: - The card's first page carries it, and fits

    private func thumbnail(_ key: String = "lc.answer.frame:1", height: CGFloat = 200) -> HUDPicture {
        HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 552, height: height), contentKey: key)
    }

    func testTheFirstPageCarriesThePictureAndLaterPagesDoNot() throws {
        let long = String(repeating: "Check the breaker panel label before you reset anything here. ", count: 6)
        let pages = HUDAnswerPager.pages(for: long, geometry: .raybanDisplay, firstPageReservedLines: 1)
        XCTAssertGreaterThan(pages.count, 1)
        let question = HUDAnswerCardBuilder.questionLine(for: "what is this", maxChars: 32)
        let first = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: [], question: question,
                                                            picture: thumbnail(), onAction: { _ in }))
        XCTAssertEqual(first.picture?.contentKey, "lc.answer.frame:1")
        XCTAssertTrue(first.renderKey.contains("pic:lc.answer.frame:1"))
        let second = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 1, followUps: [], picture: thumbnail(),
                                                             onAction: { _ in }))
        XCTAssertNil(second.picture)
        let actions = HUDAnswerCardBuilder.actions(pages, followUps: [], onAction: { _ in })
        XCTAssertNil(actions.picture)
    }

    func testEveryFullestFirstPageFitsTheLensWithThePicture() throws {
        let picture = thumbnail()
        XCTAssertEqual(HUDAnswerThumbnail.drawnHeight(of: picture), 209, ".fill across the 576 px column")
        let shapes: [(String, String?)] = [
            (String(repeating: "word ", count: 24), nil),                       // a single page, four lines
            (String(repeating: "word ", count: 18), "what is this"),            // the question and three lines
            (String(repeating: "word ", count: 80), "what is this"),            // paged: question, two lines, footer
            (String(repeating: "word ", count: 80), nil),                       // paged: three lines and footer
        ]
        for (text, asked) in shapes {
            let question = HUDAnswerCardBuilder.questionLine(for: asked, maxChars: 32)
            let pages = HUDAnswerPager.pages(for: text, geometry: .raybanDisplay,
                                             firstPageReservedLines: question == nil ? 0 : 1)
            let page = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: ["Why?", "How?"],
                                                               question: question, picture: picture, onAction: { _ in }))
            XCTAssertNotNil(page.picture, "fits: \(pages.count) page(s), question \(question != nil)")
            let height = LensPageFrame.height(HUDAnswerThumbnail.frameContent(of: page),
                                              pictureHeight: HUDAnswerThumbnail.drawnHeight(of: picture))
            XCTAssertLessThanOrEqual(height, 600)
        }
    }

    func testAPictureThatWouldNotFitIsLeftOff() throws {
        let pages = HUDAnswerPager.pages(for: String(repeating: "word ", count: 24), geometry: .raybanDisplay)
        let tall = thumbnail(height: 400)
        let page = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: [], picture: tall,
                                                           onAction: { _ in }))
        XCTAssertNil(page.picture, "drawn without it rather than scrolled")
        XCTAssertFalse(page.lines.isEmpty)
    }

    // MARK: - The first page at the lens's budget (Plan MG P0)

    /// The first page gives up a line for the question and, at the lens's 10 lines, the picture's
    /// 5; the teleprompter's 4 lines already left the picture room, and Even draws none. A picture
    /// too tall to leave a line of text is never drawn, so nothing is reserved for it.
    func testTheFirstPageReservesTheQuestionAndThePicture() {
        let lens = LensPageFrame.answerGeometry
        let strip = thumbnail()
        func reserved(_ question: Bool, _ picture: HUDPicture?, _ geometry: TeleprompterPaginator.Geometry) -> Int {
            HUDAnswerCard.firstPageReservedLines(hasQuestion: question, picture: picture, geometry: geometry)
        }
        XCTAssertEqual(reserved(false, nil, lens), 0)
        XCTAssertEqual(reserved(true, nil, lens), 1)
        XCTAssertEqual(reserved(false, strip, lens), 5)
        XCTAssertEqual(reserved(true, strip, lens), 6)
        XCTAssertEqual(reserved(true, thumbnail(height: 100), lens), 1 + 3, "a shorter strip, fewer lines")
        XCTAssertEqual(reserved(true, thumbnail(height: 400), lens), 1, "too tall to draw: the text keeps its room")
        XCTAssertEqual(reserved(false, strip, .raybanDisplay), 0, "4 lines leave the strip its room")
        XCTAssertEqual(reserved(true, strip, .raybanDisplay), 1)
        XCTAssertEqual(reserved(true, strip, .evenG2), 1)
        XCTAssertEqual(reserved(false, nil, .evenG2), 0)
    }

    /// Every first page the lens geometry lays out with its reservation — single or paged, with or
    /// without the question, at every length — carries the picture and fits the 600 px lens with the
    /// fullest button row: `fits` never drops it.
    func testEveryFirstPageAtTheLensGeometryFitsWithThePicture() throws {
        let lens = LensPageFrame.answerGeometry
        let picture = thumbnail()
        let sentence = "Check the breaker panel label before you reset anything here."
        var texts = (1...140).map { String(repeating: "word ", count: $0) }
        texts += (1...12).map { Array(repeating: sentence, count: $0).joined(separator: " ") }
        texts.append(Array(repeating: "abcdefghijklmnopqrstuvwxyz12345", count: 4).joined(separator: " "))
        var shapes = Set<String>()
        for text in texts {
            for asked in [nil, "what is this"] as [String?] {
                let question = HUDAnswerCardBuilder.questionLine(for: asked, maxChars: lens.maxChars)
                let reserved = HUDAnswerCard.firstPageReservedLines(hasQuestion: question != nil, picture: picture,
                                                                    geometry: lens)
                let pages = HUDAnswerPager.pages(for: text, geometry: lens, firstPageReservedLines: reserved)
                let page = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: ["Why?", "How?"],
                                                                   question: question, picture: picture,
                                                                   hasPage: true, onAction: { _ in }))
                XCTAssertNotNil(page.picture, "\(text.count) characters, question \(question != nil)")
                let content = HUDAnswerThumbnail.frameContent(of: page)
                XCTAssertLessThanOrEqual(LensPageFrame.height(content, pictureHeight: HUDAnswerThumbnail.drawnHeight(of: picture)),
                                         600)
                shapes.insert("\(pages.count > 1)-\(question != nil)-\(pages[0].lines.count)")
            }
        }
        // The fullest shapes were all laid out: paged with the question and three lines, paged
        // without it and four, and single pages of four lines.
        XCTAssertTrue(shapes.contains("true-true-3"), "\(shapes)")
        XCTAssertTrue(shapes.contains("true-false-4"), "\(shapes)")
        XCTAssertTrue(shapes.contains("false-false-4"), "\(shapes)")
        XCTAssertTrue(shapes.contains("false-true-4"), "\(shapes)")
    }

    /// A page longer than one shaped body line goes to the lens line by line, so no backend cuts it
    /// at `HUDTextShaper.maxBodyLength`; a single page within it is still today's one line.
    func testAOnePageAnswerOverTheBodyLimitGoesLineByLine() throws {
        let lens = LensPageFrame.answerGeometry
        let text = (1...6).map { "Invented step \($0) of the purge." }.joined(separator: " ")
        XCTAssertGreaterThan(text.count, HUDTextShaper.maxBodyLength)
        let pages = HUDAnswerPager.pages(for: text, geometry: lens)
        XCTAssertEqual(pages.count, 1)
        let screen = try XCTUnwrap(HUDAnswerCardBuilder.page(pages, index: 0, followUps: [], onAction: { _ in }))
        XCTAssertEqual(screen.lines.map(\.text), pages[0].lines)
        XCTAssertTrue(screen.lines.allSatisfy { $0.text.count <= lens.maxChars })
        XCTAssertEqual(screen.lines.map(\.text).joined(separator: " "), text, "every word, uncut")
    }

    // MARK: - Helpers

    static func frameJPEG(_ size: CGSize, grey: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: grey, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.9)
    }
}

#if !AVENKIN_PHONE_ONLY
/// The live feed, the card and the vision picture through a real `GlassesDisplayService`.
@MainActor
final class LensLiveAndVisionDisplayTests: XCTestCase {

    private var savedDisplayEnabled = false
    private var savedBackend: String?

    override func setUp() async throws {
        try await super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedBackend = UserDefaults.standard.string(forKey: "displayBackend")
        Config.glassesDisplayEnabled = true
        Config.displayBackend = .metaRayBan
    }

    override func tearDown() async throws {
        Config.glassesDisplayEnabled = savedDisplayEnabled
        UserDefaults.standard.set(savedBackend, forKey: "displayBackend")
        LensMicPolicy.metaDisplayPresent = false
        try await super.tearDown()
    }

    @MainActor
    private final class Timers {
        var fires: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
        func fireAll() {
            let pending = fires
            fires = []
            pending.forEach { $0.fire() }
        }
    }

    private func makeRig(drawsPictures: Bool = true) -> (GlassesDisplayService, HUDAnswerCard, LiveAnswerCardFeed, Timers) {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = drawsPictures
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let card = HUDAnswerCard(display: display)
        card.geometry = { .raybanDisplay }
        card.scheduleIdleTimer = { _, _ in }
        let feed = LiveAnswerCardFeed(card: card)
        let timers = Timers()
        feed.schedule = { delay, fire in timers.fires.append((delay, fire)) }
        return (display, card, feed, timers)
    }

    private func liveTurn(_ feed: LiveAnswerCardFeed, wearer: String?, answer: [String]) {
        if let wearer {
            feed.handle(.wearerSpeechStarted)
            feed.handle(.wearerWords(wearer))
        }
        answer.forEach { feed.handle(.assistantText($0)) }
        feed.handle(.turnComplete(publishes: true))
    }

    func testALiveTurnBecomesAnAnswerCardAtItsEndNotWordByWord() {
        let (display, card, feed, timers) = makeRig()
        feed.handle(.wearerSpeechStarted)
        feed.handle(.wearerWords("what size breaker"))
        feed.handle(.assistantText("A 20"))
        XCTAssertFalse(display.showsAnswerCard, "nothing while the model speaks")
        feed.handle(.assistantText(" amp breaker."))
        feed.handle(.turnComplete(publishes: true))
        XCTAssertFalse(display.showsAnswerCard, "the settle waits for trailing transcript")
        XCTAssertEqual(timers.fires.first?.delay, LiveAnswerCardFeed.defaultSettle)
        feed.handle(.assistantText(" Check the label."))       // trailing transcript joins
        timers.fireAll()
        XCTAssertTrue(display.showsAnswerCard)
        XCTAssertEqual(card.answer, "A 20 amp breaker. Check the label.")
        XCTAssertEqual(card.question, "You: what size breaker")
        XCTAssertTrue(card.followUps.isEmpty, "a live card has no follow-ups")
        XCTAssertTrue(card.screenOnLens?.items.contains { $0.id == HUDAnswerCardBuilder.ItemID.actions } ?? false,
                      "paged with Actions, as any card")
    }

    func testNewSpeechPublishesTheWaitingAnswerAtOnce() {
        let (display, card, feed, timers) = makeRig()
        liveTurn(feed, wearer: "what time is it", answer: ["It's 3 pm."])
        feed.handle(.wearerSpeechStarted)
        XCTAssertTrue(display.showsAnswerCard)
        XCTAssertEqual(card.answer, "It's 3 pm.")
        timers.fireAll()                                  // the old settle finds nothing left
        XCTAssertEqual(card.answer, "It's 3 pm.")
    }

    func testALiveAnswerNeverGoesOverATaskCard() {
        let (display, card, feed, timers) = makeRig()
        let task = HUDScreen(title: "Torque the bolts",
                             items: [HUDItem(id: "done", label: "Done", style: .primary) {},
                                     HUDItem(id: "back", label: "Back", style: .outline) {}])
        display.present(screen: task, onSelect: { _ in })
        liveTurn(feed, wearer: "what's next", answer: ["Torque to forty."])
        timers.fireAll()
        XCTAssertFalse(display.showsAnswerCard)
        XCTAssertEqual(display.heldScreenRenderKey, task.renderKey, "the task card stays")
        XCTAssertNil(card.screenOnLens)
    }

    func testOnADismissedLensOnlyAWearerLedLiveAnswerReopensIt() {
        let (display, card, feed, timers) = makeRig()
        display.lensEndedByDevice()

        liveTurn(feed, wearer: nil, answer: ["You have a message from Sam."])
        timers.fireAll()
        XCTAssertTrue(display.lensDismissed, "the model volunteered it: the lens stays dismissed")
        XCTAssertFalse(display.showsAnswerCard)

        liveTurn(feed, wearer: "what did Sam say", answer: ["Sam is running late."])
        timers.fireAll()
        XCTAssertFalse(display.lensDismissed, "the wearer asked: the lens opens")
        XCTAssertTrue(display.showsAnswerCard)
        XCTAssertEqual(card.answer, "Sam is running late.")
    }

    func testAPressOnTheCardMakesTheNextLiveAnswerWearerLed() {
        let (display, _, feed, timers) = makeRig()
        display.lensEndedByDevice()
        feed.wearerAsked()
        liveTurn(feed, wearer: nil, answer: ["More about that."])
        timers.fireAll()
        XCTAssertTrue(display.showsAnswerCard)
    }

    func testTheHUDSwitchOffShowsNothing() {
        let (display, _, feed, timers) = makeRig()
        Config.glassesDisplayEnabled = false
        liveTurn(feed, wearer: "hello", answer: ["Hi there."])
        timers.fireAll()
        XCTAssertFalse(display.showsAnswerCard)
    }

    func testASessionEndingDropsAWaitingTurn() {
        let (display, _, feed, timers) = makeRig()
        liveTurn(feed, wearer: "hello", answer: ["Hi there."])
        feed.handle(.sessionEnded)
        timers.fireAll()
        XCTAssertFalse(display.showsAnswerCard)
        XCTAssertEqual(feed.tracker, LiveAnswerTurnTracker())
    }

    // MARK: - The picture on a vision answer's card

    func testAStagedFrameGoesOnTheNextCardsFirstPage() {
        let (_, card, _, _) = makeRig()
        let ticket = card.expectPicture()
        card.stagePicture(HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 552, height: 200),
                                     contentKey: "lc.answer.frame:7"), ticket: ticket)
        XCTAssertTrue(card.absorb("A red pressure relief valve.", streamed: false))
        XCTAssertEqual(card.screenOnLens?.picture?.contentKey, "lc.answer.frame:7")

        XCTAssertTrue(card.absorb("Something else.", streamed: false))
        XCTAssertNil(card.screenOnLens?.picture, "the frame belongs to one answer")
    }

    func testAStaleOrUnwantedPictureIsIgnored() {
        let (_, card, _, _) = makeRig()
        let picture = HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 552, height: 200),
                                 contentKey: "lc.answer.frame:8")
        let old = card.expectPicture()
        _ = card.expectPicture()                          // a newer frame went to the model
        card.stagePicture(picture, ticket: old)
        XCTAssertTrue(card.absorb("An answer.", streamed: false))
        XCTAssertNil(card.screenOnLens?.picture, "a late decode of an older frame is dropped")

        let ticket = card.expectPicture()
        card.beginTurn(question: "what is this")
        card.stagePicture(picture, ticket: ticket)
        card.endTurn()                                    // the turn ended without a card
        XCTAssertTrue(card.absorb("A later, unrelated answer.", streamed: false))
        XCTAssertNil(card.screenOnLens?.picture)
    }

    func testABackendThatDrawsNoPicturesNeverGetsOne() {
        let (_, card, _, _) = makeRig(drawsPictures: false)
        let ticket = card.expectPicture()
        card.stagePicture(HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 552, height: 200),
                                     contentKey: "lc.answer.frame:9"), ticket: ticket)
        XCTAssertTrue(card.absorb("A valve.", streamed: false))
        XCTAssertNil(card.screenOnLens?.picture)
    }

    func testAStreamedVisionTurnsCardCarriesTheFrameAsItGrows() {
        let (_, card, _, _) = makeRig()
        card.beginTurn(question: "what is this")
        let ticket = card.expectPicture()
        card.stagePicture(HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 552, height: 200),
                                     contentKey: "lc.answer.frame:10"), ticket: ticket)
        card.finishTurn(reply: "That's a thermostatic mixing valve. Turn it clockwise to cool the water.")
        XCTAssertEqual(card.screenOnLens?.picture?.contentKey, "lc.answer.frame:10")
        card.endTurn()
        XCTAssertEqual(card.screenOnLens?.picture?.contentKey, "lc.answer.frame:10", "the card keeps its picture")
        card.close()
        XCTAssertNil(card.picture)
    }

    // MARK: - The lens's budget on the card (Plan MG P0)

    /// A streamed vision answer at the lens geometry: the first page reserves the question and the
    /// picture from its first layout, keeps the same lines as the answer grows, and keeps the
    /// picture to the end.
    func testAVisionAnswerAtTheLensGeometryKeepsItsPictureAndItsFirstPage() throws {
        let (_, card, _, _) = makeRig()
        card.geometry = { LensPageFrame.answerGeometry }
        card.beginTurn(question: "what is this")
        let ticket = card.expectPicture()
        card.stagePicture(HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 552, height: 200),
                                     contentKey: "lc.answer.frame:11"), ticket: ticket)
        let sentences = (1...30).map { "Invented step \($0) of checking the mixing valve here." }
        var firstLines: [String]?
        for sentence in sentences {
            card.absorb(sentence, streamed: true)
            guard card.isShowing else { continue }
            let lines = card.pages[0].lines
            if let firstLines { XCTAssertEqual(lines, firstLines, "page 1 is settled") } else { firstLines = lines }
            XCTAssertEqual(card.screenOnLens?.pageSet?.pages.first?.picture?.contentKey, "lc.answer.frame:11")
        }
        XCTAssertEqual(firstLines?.count, 3, "9 lines less the question and the picture's 5")
        card.finishTurn(reply: sentences.joined(separator: " "))
        card.endTurn()
        XCTAssertEqual(card.pages[0].lines, firstLines)
        XCTAssertTrue(card.pages.dropFirst().dropLast().allSatisfy { $0.lines.count <= 9 })
        XCTAssertEqual(card.pages[1].lines.count, 9)
        XCTAssertEqual(card.screenOnLens?.picture?.contentKey, "lc.answer.frame:11", "the card keeps its picture")
        let first = try XCTUnwrap(card.screenOnLens)
        XCTAssertTrue(HUDAnswerThumbnail.fits(first, picture: try XCTUnwrap(card.picture)))
    }

    /// Without a picture the first page holds 8 lines under the question and the rest 9; a backend
    /// that draws none reserves nothing for a picture.
    func testWithoutAPictureTheFirstPageHoldsEightLines() {
        for drawsPictures in [true, false] {
            let (_, card, _, _) = makeRig(drawsPictures: drawsPictures)
            card.geometry = { LensPageFrame.answerGeometry }
            card.beginTurn(question: "what is this")
            if !drawsPictures {
                let ticket = card.expectPicture()
                card.stagePicture(HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 552, height: 200),
                                             contentKey: "lc.answer.frame:12"), ticket: ticket)
            }
            card.finishTurn(reply: String(repeating: "word ", count: 120))
            card.endTurn()
            XCTAssertEqual(card.pages.map(\.lines.count), [8, 9, 3], "draws pictures \(drawsPictures)")
            XCTAssertNil(card.picture)
        }
    }

    /// The answer card takes the lens's budget on the Meta Display, Even keeps
    /// its own; the teleprompter-shaped screens (prepared cards, the Thinking card) stay on 4 × 32.
    func testTheActiveGeometriesByBackend() {
        let display = GlassesDisplayService()
        Config.displayBackend = .metaRayBan
        XCTAssertEqual(HUDAnswerCard.activeGeometry().maxLines, 10)
        XCTAssertEqual(HUDAnswerCard.activeGeometry().maxChars, 32)
        XCTAssertEqual(HUDAnswerCard(display: display).geometry().maxLines, 10)
        XCTAssertEqual(HUDAnswerCard.activeTeleprompterGeometry().maxLines, 4)
        XCTAssertEqual(HUDRouter(display: display).cardGeometry().maxLines, 4, "prepared-card stack")
        XCTAssertEqual(HUDTurnState(display: display).geometry().maxLines, 4, "the Thinking card")
        let glances = PreparedCardGlances(display: display, router: HUDRouter(display: display),
                                          defaults: UserDefaults(suiteName: "mg-p0-\(UUID().uuidString)")!)
        XCTAssertEqual(glances.geometry().maxLines, 4, "prepared-card glance")

        Config.displayBackend = .evenG2
        XCTAssertEqual(HUDAnswerCard.activeGeometry().maxLines, 3)
        XCTAssertEqual(HUDAnswerCard.activeGeometry().maxChars, 40)
        XCTAssertEqual(HUDAnswerCard.activeTeleprompterGeometry().maxLines, 3)
        XCTAssertEqual(HUDAnswerCard.activeTeleprompterGeometry().maxChars, 40)
    }
}
#endif
