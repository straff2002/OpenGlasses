#if !AVENKIN_PHONE_ONLY
import Combine
import MWDATDisplay
import XCTest
@testable import OpenGlasses

/// Plan KX P5: captions, the turn arrow, the timer and Now Playing cards, the Home Assistant list,
/// teleprompter voice-follow and Field Assist clips. Headless: the builders and policies directly,
/// the service through `testRenderSink`, the band by firing the rendered buttons.
@MainActor
final class LensRefinementsTests: XCTestCase {

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

    // MARK: - Rig

    private final class Frames {
        var frames: [GlassesDisplayService.HUDFrame] = []
    }

    private func makeDisplay() -> (GlassesDisplayService, Frames) {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        let frames = Frames()
        display.testRenderSink = { frames.frames.append($0) }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        return (display, frames)
    }

    private func drain() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func item(_ id: String, _ style: HUDButtonStyle) -> HUDItem {
        HUDItem(id: id, label: id, style: style) {}
    }

    private func press(_ id: String, on screen: HUDScreen?, _ display: GlassesDisplayService) {
        guard let screen, let index = screen.items.firstIndex(where: { $0.id == id }) else {
            return XCTFail("no item '\(id)' on the screen")
        }
        display.testInteractiveButtonActions(for: screen)[index]()
    }

    // MARK: - Captions

    func testALongCaptionKeepsTheNewestWordsInThreeRowsWithinTheBudget() {
        let words = (1...120).map { "word\($0)" }
        let rows = HUDCaptionBuilder.rows(words.joined(separator: " "))
        XCTAssertEqual(rows.count, HUDCaptionBuilder.rowCount)
        XCTAssertLessThanOrEqual(rows.map(\.count).reduce(0, +), HUDCaptionBuilder.budget)
        for row in rows {
            XCTAssertLessThanOrEqual(row.count, HUDCaptionBuilder.rowLength)
            XCTAssertLessThanOrEqual(row.count, HUDTextShaper.maxBodyLength, "the backend's condense never cuts a row")
        }
        XCTAssertTrue(rows.last?.hasSuffix("word120") ?? false, "the newest word is kept")
        XCTAssertTrue(rows.first?.hasPrefix("… ") ?? false, "dropped text is marked")
        XCTAssertFalse(rows.joined(separator: " ").contains("word1 "), "the oldest words go first")
        // Cut at word boundaries: every row is whole words of the original.
        let kept = rows.joined(separator: " ").replacingOccurrences(of: "… ", with: "").split(separator: " ")
        XCTAssertTrue(kept.allSatisfy { words.contains(String($0)) })
    }

    func testAShortCaptionIsOneRowWithNoMark() {
        XCTAssertEqual(HUDCaptionBuilder.rows("  hello   there  "), ["hello there"])
        XCTAssertEqual(HUDCaptionBuilder.rows("   "), [])
    }

    func testRecentFinalsOfTheSameSpeakerAreCarriedInFrontOfTheLiveText() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recent = [
            HUDCaptionBuilder.Final(text: "too old", at: now.addingTimeInterval(-60), speaker: nil),
            HUDCaptionBuilder.Final(text: "someone else", at: now.addingTimeInterval(-3), speaker: "Bob"),
            HUDCaptionBuilder.Final(text: "first sentence.", at: now.addingTimeInterval(-4), speaker: nil),
        ]
        XCTAssertEqual(HUDCaptionBuilder.text(live: "and the next", speaker: nil, recent: recent, now: now),
                       "first sentence. and the next")
        // A live text that already carries the final (compaction) does not repeat it.
        XCTAssertEqual(HUDCaptionBuilder.text(live: "first sentence. more", speaker: nil, recent: recent, now: now),
                       "first sentence. more")
        XCTAssertEqual(HUDCaptionBuilder.text(live: "hi", speaker: "Bob", recent: recent, now: now),
                       "someone else hi")
    }

    func testTheSpeakerIsAMetaLineAndTheMicMarksLiveCapture() throws {
        let now = Date()
        let labelled = try XCTUnwrap(HUDCaptionBuilder.caption(live: "hello", speaker: "Alice", recent: [], now: now,
                                                                listening: true))
        let lines = HUDCaptionBuilder.lines(labelled)
        XCTAssertEqual(lines.first, HUDLine("Alice", icon: .microphone, emphasis: .meta))
        XCTAssertEqual(lines.last, HUDLine("hello"))

        let plain = try XCTUnwrap(HUDCaptionBuilder.caption(live: "hello", speaker: nil, recent: [], now: now,
                                                             listening: true))
        XCTAssertEqual(HUDCaptionBuilder.lines(plain), [HUDLine("hello", icon: .microphone)])
        let quiet = HUDCaptionBuilder.caption(live: "hello", speaker: nil, recent: [], now: now, listening: false)
        XCTAssertEqual(quiet.map(HUDCaptionBuilder.lines), [HUDLine("hello")])
        XCTAssertNil(HUDCaptionBuilder.caption(live: " ", speaker: nil, recent: [], now: now, listening: true))
        XCTAssertTrue(HUDCaptionBuilder.screen(labelled).items.isEmpty, "a caption is never interactive")
    }

    func testCaptionsAreAmbientFramesSuppressedUnderAScreenAndADismissal() async {
        let (display, frames) = makeDisplay()
        let caption = HUDCaption(rows: ["one", "two"], speaker: "Alice", listening: true)
        display.showCaption(caption)
        await drain()
        XCTAssertEqual(frames.frames.last, .caption(rows: ["one", "two"], speaker: "Alice"))
        XCTAssertEqual(display.mirrorScreen?.lines.first?.emphasis, .meta)

        display.present(screen: HUDScreen(title: "Task", items: [item("back", .outline)])) { _ in }
        await drain()
        let count = frames.frames.count
        display.showCaption(HUDCaption(rows: ["three"], speaker: nil, listening: true))
        await drain()
        XCTAssertEqual(frames.frames.count, count, "a caption never covers a held screen")

        display.endInteractive()
        await drain()
        display.lensEndedByDevice()
        let afterDismissal = frames.frames.count
        display.showCaption(HUDCaption(rows: ["four"], speaker: nil, listening: true))
        await drain()
        XCTAssertEqual(frames.frames.count, afterDismissal, "a caption does not reopen a dismissed lens")
    }

    func testTheMetaBackendDrawsTheCaptionWithoutButtons() {
        let caption = HUDCaption(rows: ["one", "two", "three"], speaker: "Alice", listening: true)
        let view = MetaDisplayBackend().makeScreenView(HUDCaptionBuilder.screen(caption))
        XCTAssertEqual(view.children.count, 4, "the speaker and three rows")
        XCTAssertFalse(view.children.contains { $0 is ButtonGroup })
        XCTAssertEqual(HUDCaptionBuilder.body(caption), "one two three", "a text-cell backend wraps one body")
    }

    // MARK: - Turn arrow

    func testTheArrowPointsTheWayTheManeuverTurns() {
        XCTAssertEqual(HUDTurnArrow.angle(for: .continueStraight), 0)
        XCTAssertEqual(HUDTurnArrow.angle(for: .depart), 0)
        XCTAssertEqual(HUDTurnArrow.angle(for: .slightLeft), -45)
        XCTAssertEqual(HUDTurnArrow.angle(for: .slightRight), 45)
        XCTAssertEqual(HUDTurnArrow.angle(for: .turnLeft), -90)
        XCTAssertEqual(HUDTurnArrow.angle(for: .turnRight), 90)
        XCTAssertEqual(HUDTurnArrow.angle(for: .uTurn), 180)
        XCTAssertNil(HUDTurnArrow.angle(for: .roundabout))
        XCTAssertNil(HUDTurnArrow.angle(for: .arrive))
        XCTAssertNil(HUDTurnArrow.picture(for: .arrive))

        let centre = HUDTurnArrow.arrowSide / 2
        let right = HUDTurnArrow.points(angle: 90)[0]
        XCTAssertGreaterThan(right.x, centre + 40)
        XCTAssertEqual(right.y, centre, accuracy: 0.5)
        let left = HUDTurnArrow.points(angle: -90)[0]
        XCTAssertLessThan(left.x, centre - 40)
        let ahead = HUDTurnArrow.points(angle: 0)[0]
        XCTAssertLessThan(ahead.y, centre - 40, "straight ahead points up")
    }

    func testTheArrowIsASmallWhiteOnBlackStripAboveTheLine() throws {
        let picture = try XCTUnwrap(HUDTurnArrow.picture(for: .turnLeft))
        XCTAssertEqual(picture.pixelSize, CGSize(width: 552, height: 120))
        XCTAssertEqual(picture.placement, .aboveLines)
        XCTAssertEqual(picture.contentKey, "kx.nav.arrow:-90")
        XCTAssertEqual(HUDTurnArrow.picture(for: .turnLeft)?.contentKey, picture.contentKey)
        let ahead = try XCTUnwrap(HUDTurnArrow.picture(for: .continueStraight))
        XCTAssertGreaterThan(red(ahead.image, x: 60, y: 80), 200, "the shaft is white")
        XCTAssertLessThan(red(ahead.image, x: 400, y: 60), 10, "the rest is black, clear on the lens")
        XCTAssertLessThan(red(ahead.image, x: 2, y: 2), 10)
    }

    func testTheMetaBackendLeadsWithTheArrow() throws {
        let arrow = try XCTUnwrap(HUDTurnArrow.picture(for: .turnRight))
        var screen = HUDScreen(lines: [HUDLine("→ 40 m · King St", icon: .navigation)])
        screen.picture = arrow
        let view = MetaDisplayBackend().makeScreenView(screen)
        XCTAssertTrue(view.children.first is Image, "the arrow is drawn above the line")
        XCTAssertTrue(screen.renderKey.contains("pic:kx.nav.arrow:90^"))
    }

    func testGuidanceCarriesTheArrowOnlyOnABackendThatDrawsPictures() async throws {
        let arrow = try XCTUnwrap(HUDTurnArrow.picture(for: .turnLeft))
        let (display, frames) = makeDisplay()
        display.testDrawsPicturesOverride = true
        XCTAssertTrue(display.wantsGuidancePictures)
        display.showNavigation("← 40 m · King St", arrow: arrow)
        await drain()
        guard case .screen(let key)? = frames.frames.last else { return XCTFail("\(frames.frames)") }
        XCTAssertTrue(key.contains("pic:kx.nav.arrow:-90"))

        let (textOnly, textFrames) = makeDisplay()
        textOnly.testDrawsPicturesOverride = false
        XCTAssertFalse(textOnly.wantsGuidancePictures)
        textOnly.showNavigation("← 40 m · King St", arrow: arrow)
        await drain()
        XCTAssertEqual(textFrames.frames.last, .content(body: "← 40 m · King St", title: nil, icon: .navigation))
    }

    func testGuidanceWithAnArrowStillReplacesAnAnswerCard() async throws {
        let arrow = try XCTUnwrap(HUDTurnArrow.picture(for: .turnRight))
        let (display, frames) = makeDisplay()
        display.testDrawsPicturesOverride = true
        XCTAssertTrue(display.presentAnswerCard(HUDScreen(title: "Answer", items: [item("kp.close", .outline)])) { _ in })
        await drain()
        display.showNavigation("→ King St", arrow: arrow)
        await drain()
        XCTAssertFalse(display.showsAnswerCard)
        XCTAssertFalse(display.isInteractive)
        guard case .screen(let key)? = frames.frames.last else { return XCTFail("\(frames.frames)") }
        XCTAssertTrue(key.contains("kx.nav.arrow:90"))
    }

    func testASlowPictureSendPutsTheArrowOffForAWhile() {
        let now = Date(timeIntervalSince1970: 1_000)
        var policy = HUDGuidancePicturePolicy()
        policy.note(HUDSendRecord(kind: .picture, milliseconds: 160, outcome: .sent), at: now)
        XCTAssertTrue(policy.allows(at: now))
        policy.note(HUDSendRecord(kind: .text, milliseconds: 5_000, outcome: .timedOut), at: now)
        XCTAssertTrue(policy.allows(at: now), "a text send says nothing about pictures")
        policy.note(HUDSendRecord(kind: .picture, milliseconds: 1_400, outcome: .sent), at: now)
        XCTAssertFalse(policy.allows(at: now))
        XCTAssertFalse(policy.allows(at: now.addingTimeInterval(29)))
        XCTAssertTrue(policy.allows(at: now.addingTimeInterval(30)))

        var failed = HUDGuidancePicturePolicy()
        failed.note(HUDSendRecord(kind: .picture, milliseconds: 100, outcome: .retriedWithoutPicture), at: now)
        XCTAssertFalse(failed.allows(at: now))
        // The same record read again later does not start the cooldown over.
        failed.note(HUDSendRecord(kind: .picture, milliseconds: 100, outcome: .retriedWithoutPicture),
                    at: now.addingTimeInterval(25))
        XCTAssertTrue(failed.allows(at: now.addingTimeInterval(31)))
    }

    // MARK: - Timer card

    private func timer(_ kind: FinishedTimer.Kind = .timer, label: String? = "Pasta",
                       canExtend: Bool = true) -> FinishedTimer {
        FinishedTimer(id: "timer-1", kind: kind, label: label, canExtend: canExtend)
    }

    func testTheTimerCardFocusesStopAndOffersMoreTimeWhenItCan() {
        let screen = HUDTimerCardBuilder.screen(timer(), canExtend: true) { _ in }
        XCTAssertEqual(screen.title, HUDTimerCardBuilder.timerHeading)
        XCTAssertEqual(screen.lines, [HUDLine("Pasta", icon: .reminder)])
        XCTAssertEqual(screen.items.map(\.id), [HUDTimerCardBuilder.ItemID.stop, HUDTimerCardBuilder.ItemID.extend,
                                                HUDTimerCardBuilder.ItemID.close])
        XCTAssertEqual(screen.resolvedFocusItemID, HUDTimerCardBuilder.ItemID.stop)
        XCTAssertTrue(HUDExit.hasExit(screen))

        let noExtend = HUDTimerCardBuilder.screen(timer(canExtend: false), canExtend: true) { _ in }
        XCTAssertFalse(noExtend.items.contains { $0.id == HUDTimerCardBuilder.ItemID.extend })
        let alarm = HUDTimerCardBuilder.screen(timer(.alarm, label: "Alarm"), canExtend: false) { _ in }
        XCTAssertEqual(alarm.title, HUDTimerCardBuilder.alarmHeading)
        XCTAssertTrue(alarm.lines.isEmpty, "the default label is not repeated")
    }

    private func makeTimerCard(_ display: GlassesDisplayService)
        -> (HUDTimerCard, stopped: () -> [FinishedTimer], extended: () -> [FinishedTimer], expire: () -> Void) {
        let card = HUDTimerCard(display: display)
        var stopped: [FinishedTimer] = []
        var extended: [FinishedTimer] = []
        var expiries: [@MainActor () -> Void] = []
        card.stop = { stopped.append($0) }
        card.extend = { extended.append($0) }
        card.scheduleExpiry = { _, fire in expiries.append(fire) }
        return (card, { stopped }, { extended }, { expiries.forEach { $0() } })
    }

    func testStopOnTheTimerCardSilencesItAndClosesTheCard() async {
        let (display, frames) = makeDisplay()
        let rig = makeTimerCard(display)
        rig.0.show(timer())
        await drain()
        XCTAssertTrue(rig.0.isShowing)
        XCTAssertTrue(display.isInteractive)
        press(HUDTimerCardBuilder.ItemID.stop, on: rig.0.screenOnLens, display)
        await drain()
        XCTAssertEqual(rig.stopped(), [timer()])
        XCTAssertFalse(display.isInteractive)
        XCTAssertEqual(frames.frames.last, .clear)
    }

    func testMoreTimeSetsItAgainAndTheCardCloses() async {
        let (display, _) = makeDisplay()
        let rig = makeTimerCard(display)
        rig.0.show(timer())
        await drain()
        press(HUDTimerCardBuilder.ItemID.extend, on: rig.0.screenOnLens, display)
        await drain()
        XCTAssertEqual(rig.extended(), [timer()])
        XCTAssertTrue(rig.stopped().isEmpty)
        XCTAssertFalse(rig.0.isShowing)
    }

    func testTheTimerCardClosesByItselfAndNeverCoversATaskCard() async {
        let (display, frames) = makeDisplay()
        let rig = makeTimerCard(display)
        rig.0.show(timer())
        await drain()
        rig.expire()
        await drain()
        XCTAssertFalse(rig.0.isShowing)
        XCTAssertFalse(display.isInteractive)

        display.present(screen: HUDScreen(title: "Task", items: [item("back", .outline)])) { _ in }
        await drain()
        rig.0.show(timer())
        await drain()
        XCTAssertFalse(rig.0.isShowing)
        guard case .content(let body, let title, _)? = frames.frames.last else { return XCTFail("\(frames.frames)") }
        XCTAssertEqual(title, HUDTimerCardBuilder.timerHeading)
        XCTAssertEqual(body, "Pasta")
    }

    func testATimerDoesNotReopenADismissedLens() async {
        let (display, frames) = makeDisplay()
        display.lensEndedByDevice()
        let rig = makeTimerCard(display)
        let before = frames.frames.count
        rig.0.show(timer())
        await drain()
        XCTAssertFalse(rig.0.isShowing)
        XCTAssertTrue(display.lensDismissed)
        XCTAssertEqual(frames.frames.count, before)
    }

    func testTheWatchHearsATimerFinishAndAnAlarmStartRinging() async {
        let watch = TimerCompletionWatch()
        watch.sleep = { _ in }
        var heard: [FinishedTimer] = []
        watch.onFinished = { heard.append($0) }
        watch.timerScheduled(id: "timer-a", label: "Tea", fireAt: Date().addingTimeInterval(60))
        await drain()
        XCTAssertEqual(heard, [FinishedTimer(id: "timer-a", kind: .timer, label: "Tea", canExtend: true)])
        XCTAssertTrue(watch.watchedTimerIDs.isEmpty)

        heard = []
        watch.alarmsChanged([("A", false), ("B", true)])
        watch.alarmsChanged([("A", false), ("B", true)])
        XCTAssertEqual(heard.map(\.id), ["B"], "one card per ring")
        XCTAssertEqual(heard.first?.kind, .alarm)
        watch.alarmsChanged([("B", false)])
        watch.alarmsChanged([("B", true)])
        XCTAssertEqual(heard.map(\.id), ["B", "B"], "it rings again later")
    }

    // MARK: - Now Playing

    func testNowPlayingOffersTheTransportWithPlayPauseFocused() {
        let playing = HUDNowPlaying(title: "Blue in Green", artist: "Miles Davis", isPlaying: true)
        let screen = HUDNowPlayingBuilder.screen(playing) { _ in }
        XCTAssertEqual(screen.items.map(\.id), [HUDNowPlayingBuilder.ItemID.previous, HUDNowPlayingBuilder.ItemID.toggle,
                                                HUDNowPlayingBuilder.ItemID.next, HUDNowPlayingBuilder.ItemID.close])
        XCTAssertLessThanOrEqual(screen.items.count, 5, "within the band's focus reach")
        XCTAssertEqual(screen.resolvedFocusItemID, HUDNowPlayingBuilder.ItemID.toggle)
        XCTAssertEqual(screen.items[1].label, "Pause")
        XCTAssertEqual(screen.lines, [HUDLine("Blue in Green", icon: .music),
                                      HUDLine("Miles Davis", emphasis: .secondary)])
        XCTAssertTrue(HUDExit.hasExit(screen))

        let paused = HUDNowPlayingBuilder.screen(HUDNowPlaying(title: "x", artist: nil, isPlaying: false)) { _ in }
        XCTAssertEqual(paused.items[1].label, "Play")
        let nothing = HUDNowPlayingBuilder.screen(nil) { _ in }
        XCTAssertEqual(nothing.items.map(\.id), [HUDNowPlayingBuilder.ItemID.toggle, HUDNowPlayingBuilder.ItemID.close])
        XCTAssertEqual(nothing.lines.first?.emphasis, .secondary)
        XCTAssertNil(HUDNowPlaying(nil))
    }

    private func makeLauncher(_ display: GlassesDisplayService) -> (HUDRouter, HUDLauncher) {
        let router = HUDRouter(display: display)
        let launcher = HUDLauncher(router: router)
        launcher.availablePlaybooks = { [] }
        launcher.availableProcedures = { [] }
        launcher.fieldAssistActive = { false }
        launcher.after = { _, body in body() }
        return (router, launcher)
    }

    func testTheMenuOffersNowPlayingAndAPressRedrawsTheCardInPlace() async {
        let (display, _) = makeDisplay()
        let (router, launcher) = makeLauncher(display)
        var playing = HUDNowPlaying(title: "Song", artist: "Band", isPlaying: true)
        var actions: [HUDMediaAction] = []
        launcher.nowPlaying = { playing }
        launcher.mediaTransport = { action in
            actions.append(action)
            if action == .toggle { playing.isPlaying.toggle() }
        }
        launcher.open()
        press("branch:media", on: router.currentScreen, display)
        await drain()
        XCTAssertEqual(router.menuDepth, 2)
        press(HUDNowPlayingBuilder.ItemID.toggle, on: router.currentScreen, display)
        await drain()
        XCTAssertEqual(actions, [.toggle])
        XCTAssertEqual(router.menuDepth, 2, "redrawn in place")
        XCTAssertEqual(router.currentScreen?.items.first { $0.id == HUDNowPlayingBuilder.ItemID.toggle }?.label, "Play")
        press(HUDNowPlayingBuilder.ItemID.close, on: router.currentScreen, display)
        await drain()
        XCTAssertFalse(router.isPresentingMenu)

        launcher.nowPlaying = { nil }
        launcher.open()
        XCTAssertFalse((router.currentScreen?.items.map(\.id) ?? []).contains("branch:media"))
    }

    // MARK: - Home Assistant favourites

    private func favourite(_ n: Int, service: String = "light.toggle", entity: String = "light.kitchen",
                           data: String? = nil) -> QuickAction {
        QuickAction(id: "ha\(n)", label: "Action \(n)", icon: "house", type: .homeAssistant,
                    haService: service, haEntityId: entity, haData: data)
    }

    func testTheHomeListPagesFiveAtATimeWithMoreBackAndClose() {
        let actions = (1...7).map { favourite($0) }
        let first = HUDHomeFavouritesBuilder.screen(actions, page: 0, onRun: { _ in }, onMore: { _ in },
                                                    onBack: {}, onClose: {})
        XCTAssertEqual(first.items.map(\.id), ["ha:ha1", "ha:ha2", "ha:ha3", "ha:ha4", "ha:ha5",
                                               HUDHomeFavouritesBuilder.ItemID.more, "back",
                                               HUDHomeFavouritesBuilder.ItemID.close])
        XCTAssertEqual(first.resolvedFocusItemID, "ha:ha1")
        XCTAssertEqual(first.lines, [HUDLine("1/2", emphasis: .meta)])
        XCTAssertTrue(HUDExit.hasExit(first))
        let second = HUDHomeFavouritesBuilder.screen(actions, page: 1, onRun: { _ in }, onMore: { _ in },
                                                     onBack: {}, onClose: {})
        XCTAssertEqual(second.items.map(\.id), ["ha:ha6", "ha:ha7", "back", HUDHomeFavouritesBuilder.ItemID.close])

        let prompt = QuickAction(id: "p", label: "Ask", icon: "x", type: .prompt, promptText: "hi")
        let empty = QuickAction(id: "e", label: "Nothing", icon: "x", type: .homeAssistant, haService: " ")
        XCTAssertEqual(HUDHomeFavouritesBuilder.favourites([prompt, favourite(1), empty]).map(\.id), ["ha1"])
    }

    func testAFavouriteNamesItsServiceCall() {
        XCTAssertEqual(HomeFavouriteRunner.call(for: favourite(1, service: "light.turn_off")),
                       .init(domain: "light", service: "turn_off", entityId: "light.kitchen", dataJSON: nil))
        XCTAssertEqual(HomeFavouriteRunner.call(for: favourite(1, service: "toggle", entity: "switch.fan"))?.domain,
                       "switch")
        XCTAssertNil(HomeFavouriteRunner.call(for: favourite(1, entity: "")))
        XCTAssertNil(HomeFavouriteRunner.confirmationSummary(for: HomeFavouriteRunner.call(for: favourite(1))!))
        XCTAssertNotNil(HomeFavouriteRunner.confirmationSummary(
            for: HomeFavouriteRunner.call(for: favourite(1, service: "lock.unlock", entity: "lock.front_door"))!))
        XCTAssertNotNil(HomeFavouriteRunner.confirmationSummary(
            for: HomeFavouriteRunner.call(for: favourite(1, service: "cover.open_cover", entity: "cover.garage"))!))
    }

    func testASecurityFavouriteAsksFirstAndAPlainOneRunsOnOnePress() async {
        var asked: [String] = []
        var performed: [HomeFavouriteRunner.Call] = []
        let declined = await HomeFavouriteRunner.run(
            favourite(1, service: "lock.unlock", entity: "lock.front_door"),
            confirm: { asked.append($0); return false },
            perform: { call, _ in performed.append(call); return true })
        XCTAssertEqual(declined, .declined)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(performed.isEmpty, "never on one press")

        let approved = await HomeFavouriteRunner.run(
            favourite(1, service: "lock.unlock", entity: "lock.front_door"),
            confirm: { _ in true }, perform: { call, _ in performed.append(call); return true })
        XCTAssertEqual(approved, .done)

        asked = []
        let plain = await HomeFavouriteRunner.run(favourite(2), confirm: { asked.append($0); return false },
                                                  perform: { _, _ in false })
        XCTAssertEqual(plain, .failed)
        XCTAssertTrue(asked.isEmpty)
        let badData = await HomeFavouriteRunner.run(favourite(3, data: "not json"), confirm: { _ in true },
                                                    perform: { _, _ in true })
        XCTAssertEqual(badData, .failed)
    }

    func testAPressOnTheHomeListRunsItAndSaysHowItWent() async {
        let (display, _) = makeDisplay()
        let (router, launcher) = makeLauncher(display)
        var ran: [String] = []
        var lines: [String] = []
        launcher.homeFavourites = { [self.favourite(1)] }
        launcher.runHomeFavourite = { action in ran.append(action.id); return .done }
        launcher.flashLine = { lines.append($0) }
        launcher.open()
        press("branch:home", on: router.currentScreen, display)
        await drain()
        XCTAssertEqual(router.currentScreen?.title, HUDHomeFavouritesBuilder.title)
        press("ha:ha1", on: router.currentScreen, display)
        await drain()
        XCTAssertEqual(ran, ["ha1"])
        XCTAssertEqual(lines, [HUDHomeFavouritesBuilder.line(for: .done, label: "Action 1")])
        XCTAssertTrue(router.isPresentingMenu, "the list stays up for the next press")
    }

    // MARK: - Teleprompter voice-follow

    func testWordsMatchFuzzily() {
        XCTAssertTrue(TeleprompterPageFollow.wordsMatch("light", "light"))
        XCTAssertTrue(TeleprompterPageFollow.wordsMatch("light", "lights"))
        XCTAssertTrue(TeleprompterPageFollow.wordsMatch("colour", "color"))
        XCTAssertFalse(TeleprompterPageFollow.wordsMatch("there", "their"), "two edits apart")
        XCTAssertFalse(TeleprompterPageFollow.wordsMatch("cat", "car"), "short words must match exactly")
        XCTAssertFalse(TeleprompterPageFollow.wordsMatch("light", "night "))
        XCTAssertFalse(TeleprompterPageFollow.wordsMatch("", "a"))
    }

    func testThePageTurnsWhenItsLastWordsAreHeardToleratingOneMiss() {
        let tail = ["we", "turn", "the", "page", "now"]
        XCTAssertTrue(TeleprompterPageFollow.heardEnd(of: tail, in: ["so", "we", "turn", "the", "page", "now"]))
        XCTAssertTrue(TeleprompterPageFollow.heardEnd(of: tail, in: ["we", "turn", "a", "page", "now"]),
                      "one misheard word")
        XCTAssertTrue(TeleprompterPageFollow.heardEnd(of: tail, in: ["we", "turn", "the", "page"]),
                      "the last word not heard yet: the second-to-last ends it")
        XCTAssertFalse(TeleprompterPageFollow.heardEnd(of: tail, in: ["we", "fell", "a", "page", "now"]),
                       "two misses")
        XCTAssertFalse(TeleprompterPageFollow.heardEnd(of: tail, in: ["we", "turn", "the"]),
                       "not at the end yet")
        XCTAssertFalse(TeleprompterPageFollow.heardEnd(of: tail, in: ["page", "now", "and", "then", "more"]),
                       "only the newest words count")
        XCTAssertTrue(TeleprompterPageFollow.heardEnd(of: ["the", "end"], in: ["the", "end"]))
        XCTAssertFalse(TeleprompterPageFollow.heardEnd(of: ["the", "end"], in: ["a", "end"]),
                       "a short tail is matched whole")
        XCTAssertFalse(TeleprompterPageFollow.heardEnd(of: [], in: ["x"]))
    }

    func testAPageStartsAtItsFirstUnreadWord() {
        let script = TeleprompterScript.parse(title: "t", text: "one two three four five six seven eight nine ten")
        let geometry = TeleprompterPaginator.Geometry(maxLines: 2, maxChars: 10)
        let first = TeleprompterPageFollow.page(script, from: 0, geometry: geometry)
        XCTAssertEqual(first.window.lines, ["one two", "three four"])
        XCTAssertEqual(first.range, 0..<4)
        let second = TeleprompterPageFollow.page(script, from: first.range.upperBound, geometry: geometry)
        XCTAssertEqual(second.window.lines, ["five six", "seven"], "mid-line, without the read half")
        XCTAssertEqual(second.range, 4..<7)
        XCTAssertEqual(TeleprompterPageFollow.tail(script, range: first.range), ["one", "two", "three", "four"])
        let end = TeleprompterPageFollow.page(script, from: 10, geometry: geometry)
        XCTAssertTrue(end.window.lines.isEmpty)
        XCTAssertTrue(end.range.isEmpty)
    }

    func testTheFollowerSetsAsideTheWordsThatTurnedAPage() {
        var follower = TeleprompterPageFollower()
        XCTAssertTrue(follower.hear(["a", "b", "c", "d"], tail: ["c", "d"]))
        XCTAssertFalse(follower.hear(["a", "b", "c", "d"], tail: ["c", "d"]), "the same words turn no second page")
        XCTAssertTrue(follower.hear(["a", "b", "c", "d", "e", "f"], tail: ["e", "f"]))
        XCTAssertTrue(follower.hear(["g", "h"], tail: ["g", "h"]), "a shorter result is a new utterance")
    }

    private func makeTeleprompter() -> TeleprompterService {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = TeleprompterService(store: TeleprompterScriptStore(directory: dir))
        service.testPageFollow = true
        return service
    }

    func testVoiceFollowHoldsThePageAndTurnsItAtItsEnd() throws {
        let service = makeTeleprompter()
        let text = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform"
        service.start(TeleprompterScript.parse(title: "t", text: text), mode: .audioPaced)
        XCTAssertTrue(service.followsPages)
        let firstPage = service.currentScreen?.lines.dropFirst().map(\.text) ?? []
        XCTAssertFalse(firstPage.isEmpty)
        service.ingestForPacing("alpha bravo charlie")
        XCTAssertEqual(service.cursor, 0, "the page holds while it is read")
        let script = TeleprompterScript.parse(title: "t", text: text)
        let geometry = TeleprompterPaginator.Geometry(maxLines: 3, maxChars: 32)
        let page = TeleprompterPageFollow.page(script, from: 0, geometry: geometry)
        let spoken = script.tokens[page.range].map(\.text).joined(separator: " ")
        service.ingestForPacing(spoken)
        XCTAssertEqual(service.cursor, page.range.upperBound, "turned at its last words")
        XCTAssertNotEqual(service.currentScreen?.lines.dropFirst().map(\.text) ?? [], firstPage)

        service.back()
        XCTAssertEqual(service.cursor, 0, "back is the previous page")
        service.advance()
        XCTAssertEqual(service.cursor, page.range.upperBound, "next is the next page")
        service.stop()
    }

    func testWithoutVoiceFollowTheAlignerStillMovesALineAtATime() {
        let service = makeTeleprompter()
        service.testPageFollow = false
        service.start(TeleprompterScript.parse(title: "t", text: "the quick brown fox jumps over"), mode: .audioPaced)
        service.ingestForPacing("the quick brown")
        XCTAssertEqual(service.cursor, 3)
        service.stop()
    }

    // MARK: - Field Assist clips

    func testOnlyAnHTTPSMP4IsPlayable() {
        XCTAssertNotNil(HUDVideo.playable("https://example.com/clips/step1.mp4"))
        XCTAssertNotNil(HUDVideo.playable(" https://example.com/A.MP4 "))
        XCTAssertNil(HUDVideo.playable("http://example.com/step1.mp4"))
        XCTAssertNil(HUDVideo.playable("https://example.com/step1.mov"))
        XCTAssertNil(HUDVideo.playable("https://example.com/watch?v=1"))
        XCTAssertNil(HUDVideo.playable("file:///tmp/a.mp4"))
        XCTAssertNil(HUDVideo.playable(""))
        XCTAssertNil(HUDVideo.playable(nil))
    }

    func testAStepCarriesAnOptionalClipThatIsLeftOutWhenAbsent() throws {
        let json = #"{"id":"s1","title":"Bleed the line","instruction":"Open the valve.","video_url":"https://example.com/bleed.mp4"}"#
        let step = try JSONDecoder().decode(Procedure.Step.self, from: Data(json.utf8))
        XCTAssertEqual(step.videoURL, "https://example.com/bleed.mp4")
        XCTAssertNotNil(HUDVideo.playable(step.videoURL))
        let plain = Procedure.Step(id: "s2", title: "T", instruction: "I")
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(encoded.contains("video_url"))
        let withClip = String(decoding: try JSONEncoder().encode(step), as: UTF8.self)
        XCTAssertTrue(withClip.contains("video_url"))
    }

    func testTheTaskCardOffersWatchOnlyForAPlayableClipOnABackendThatPlaysIt() {
        let source = ClipStubTaskSource()
        let clip = HUDVideo.playable("https://example.com/a.mp4")
        let step = HUDStep(index: 0, total: 2, title: "Bleed", video: clip)
        let offered = HUDRouter.taskCard(source: source, current: step, next: nil, onWatch: { _ in })
        XCTAssertEqual(offered.items.map(\.id), ["done", "skip", HUDRouter.watchItemID, "back"])
        let noBackend = HUDRouter.taskCard(source: source, current: step, next: nil, onWatch: nil)
        XCTAssertFalse(noBackend.items.contains { $0.id == HUDRouter.watchItemID })
        let noClip = HUDRouter.taskCard(source: source, current: HUDStep(index: 0, total: 2, title: "Bleed"),
                                        next: nil, onWatch: { _ in })
        XCTAssertFalse(noClip.items.contains { $0.id == HUDRouter.watchItemID })
    }

    func testWatchPlaysTheClipAndTheCardComesBackWhenItEnds() async throws {
        let (display, frames) = makeDisplay()
        display.testPlaysVideoOverride = true
        let router = HUDRouter(display: display)
        let source = ClipStubTaskSource()
        source.current = HUDStep(index: 0, total: 1, title: "Bleed", video: HUDVideo.playable("https://example.com/a.mp4"))
        router.startTask(source)
        await drain()
        let card = try XCTUnwrap(router.currentScreen)
        XCTAssertTrue(card.items.contains { $0.id == HUDRouter.watchItemID })
        press(HUDRouter.watchItemID, on: card, display)
        await drain()
        XCTAssertTrue(display.showsVideo)
        XCTAssertEqual(frames.frames.last, .video(url: URL(string: "https://example.com/a.mp4")!))

        display.clipEnded(.ended)
        await drain()
        XCTAssertFalse(display.showsVideo)
        XCTAssertEqual(frames.frames.last, .screen(renderKey: card.renderKey), "the task card is back")

        press(HUDRouter.watchItemID, on: card, display)
        await drain()
        let stopped = await router.handleVoiceCommand("stop")
        XCTAssertTrue(stopped)
        XCTAssertFalse(display.showsVideo)
        await drain()
        XCTAssertEqual(frames.frames.last, .screen(renderKey: card.renderKey))
    }

    func testAClipThatFailsSaysSoAndANotificationReplacesIt() async throws {
        let (display, frames) = makeDisplay()
        display.testPlaysVideoOverride = true
        let router = HUDRouter(display: display)
        let source = ClipStubTaskSource()
        source.current = HUDStep(index: 0, total: 1, title: "Bleed", video: HUDVideo.playable("https://example.com/a.mp4"))
        router.startTask(source)
        await drain()
        press(HUDRouter.watchItemID, on: router.currentScreen, display)
        await drain()
        display.clipEnded(.failed)
        await drain()
        XCTAssertTrue(frames.frames.contains(.content(body: "Couldn't play that clip", title: nil, icon: .none)))

        press(HUDRouter.watchItemID, on: router.currentScreen, display)
        await drain()
        XCTAssertTrue(display.showsVideo)
        display.showNotification(title: "Reminder", body: "Call Sam")
        await drain()
        XCTAssertFalse(display.showsVideo, "any other frame replaces the clip")
    }

    func testNoClipPlaysWhereTheBackendCannot() async {
        let (display, _) = makeDisplay()
        display.testPlaysVideoOverride = false
        display.present(screen: HUDScreen(title: "Task", items: [item("back", .outline)])) { _ in }
        XCTAssertFalse(display.playsVideo)
        XCTAssertFalse(display.playVideo(HUDVideo.playable("https://example.com/a.mp4")!))
        let router = HUDRouter(display: display)
        let source = ClipStubTaskSource()
        source.current = HUDStep(index: 0, total: 1, title: "Bleed", video: HUDVideo.playable("https://example.com/a.mp4"))
        router.startTask(source)
        XCTAssertFalse(router.currentScreen?.items.contains { $0.id == HUDRouter.watchItemID } ?? true)
    }

    // MARK: - Icons

    func testTheNewIconsMapToDATIcons() {
        XCTAssertEqual(HUDIcon.microphone.metaIconName, .threeDotSpeechBubble)
        XCTAssertEqual(HUDIcon.music.metaIconName, .musicNote)
        XCTAssertEqual(HUDIcon.video.metaIconName, .triangleRightCircle)
    }

    // MARK: - Helpers

    /// The red channel of `image` at top-down pixel (x, y).
    private func red(_ image: UIImage, x: Int, y: Int) -> UInt8 {
        guard let cg = image.cgImage else { return 0 }
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
            return true
        }
        return drawn ? data[0] : 0
    }
}

/// A `HUDTaskSource` whose step the clip tests set.
@MainActor
private final class ClipStubTaskSource: HUDTaskSource {
    var title = "Procedure"
    var current: HUDStep? = HUDStep(index: 0, total: 1, title: "Now")
    var next: HUDStep?
    private let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    func complete() async {}
    func skip() async {}
    func back() async {}
}
#endif
