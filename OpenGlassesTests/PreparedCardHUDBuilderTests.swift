import XCTest
@testable import OpenGlasses

/// Plan KT P3 — the cards on the Display, the pure parts: the screens of §6.3 on both geometries,
/// the button budget, §6.6's sensitivity on the lens and the web mirror, the push policy of §6.2,
/// the staging notification of §6.4, the words and the temple tap. No display, no clock.
@MainActor
final class PreparedCardHUDBuilderTests: XCTestCase {

    private let ray = TeleprompterPaginator.Geometry.raybanDisplay
    private let even = TeleprompterPaginator.Geometry.evenG2

    private func stack(_ cards: [PreparedCard], _ index: Int, _ geometry: TeleprompterPaginator.Geometry,
                       pressed: ((PreparedCardLensPress) -> Void)? = nil) -> HUDScreen {
        PreparedCardHUDBuilder.stack(cards, index: index, geometry: geometry) { pressed?($0) }!
    }

    private func draft(_ card: PreparedCard, page: Int = 0, _ geometry: TeleprompterPaginator.Geometry,
                       pressed: ((PreparedCardLensPress) -> Void)? = nil) -> HUDScreen {
        PreparedCardHUDBuilder.draft(card, page: page, geometry: geometry) { pressed?($0) }!
    }

    // MARK: - Snapshots by renderKey

    /// Every kind's stack screen, card i of all ten, on both geometries; and the first page of
    /// every draft. A change to any of these is a change to what the wearer sees.
    func testEveryKindRendersAsRecordedOnBothGeometries() {
        let cards = LensCardFixtures.all
        var actual: [String: String] = [:]
        for (index, card) in cards.enumerated() {
            for (name, geometry) in [("ray", ray), ("even", even)] {
                actual["stack.\(card.kind.rawValue).\(name)"] = stack(cards, index, geometry).renderKey
                if card.draft != nil {
                    actual["draft.\(card.kind.rawValue).\(name)"] = draft(card, geometry).renderKey
                }
            }
        }
        XCTAssertEqual(Set(actual.keys), Set(Self.snapshots.keys), "every kind has a snapshot on both geometries")
        for key in actual.keys.sorted() {
            XCTAssertEqual(actual[key], Self.snapshots[key], "SNAPSHOT \(key) = \(actual[key] ?? "")")
        }
    }

    // MARK: - The stack

    func testTheStackShowsTheHeadlineChipsAFactAndWhereItIs() {
        let cards = [LensCardFixtures.leaveBy, LensCardFixtures.runningLate]
        let screen = stack(cards, 0, ray)
        XCTAssertEqual(screen.title, "Leave by 18:15")
        XCTAssertEqual(screen.lines.first, HUDLine("19:00 · You're in Example Bay", icon: .calendar, emphasis: .meta))
        XCTAssertEqual(screen.lines.dropFirst().map(\.text), ["Travel 30 min · Driving", "Arrive by 18:45", "1/2"],
                       "the fact the headline already says is skipped")
        XCTAssertEqual(screen.items.map(\.label), ["Directions", "Text Ana", "Next ›"])
        XCTAssertEqual(screen.resolvedFocusItemID, PreparedCardHUDBuilder.ItemID.primary)

        let last = stack(cards, 1, ray)
        XCTAssertEqual(last.items.map(\.label), ["Text Ana", "Directions", "Close"],
                       "the primary is the draft, so the second slot is the first secondary; Close on the last card")
        XCTAssertEqual(last.lines.last?.text, "2/2")
    }

    func testASingleCardHasNoFooterAndEvenG2FitsItsThreeLines() {
        let screen = stack([LensCardFixtures.leaveBy], 0, even)
        XCTAssertEqual(screen.lines.count, 3)
        XCTAssertFalse(screen.lines.map(\.text).contains("1/1"))
        XCTAssertTrue(screen.lines.allSatisfy { $0.text.count <= even.maxChars })
        let paged = stack([LensCardFixtures.leaveBy, LensCardFixtures.fitItIn], 0, even)
        XCTAssertEqual(paged.lines.count, 3, "meta, one fact and the footer")
        XCTAssertEqual(paged.lines.last?.text, "1/2")
    }

    func testEveryScreenKeepsToThreeButtonsAndEveryLineToTheGeometry() {
        let cards = LensCardFixtures.all
        for geometry in [ray, even] {
            for (index, card) in cards.enumerated() {
                let screens = [stack(cards, index, geometry),
                               PreparedCardHUDBuilder.glance(card, geometry: geometry) { _ in }]
                    + (0..<PreparedCardHUDBuilder.draftPages(card, geometry: geometry).count).map {
                        draft(card, page: $0, geometry)
                    }
                for screen in screens {
                    XCTAssertLessThanOrEqual(screen.items.count, PreparedCardHUDBuilder.maxButtons,
                                             "\(card.kind) \(screen.title ?? "")")
                    XCTAssertLessThanOrEqual(screen.lines.count, geometry.maxLines, "\(card.kind)")
                    XCTAssertTrue(screen.lines.allSatisfy { $0.text.count <= geometry.maxChars },
                                  "\(card.kind): \(screen.lines.map(\.text))")
                    XCTAssertLessThanOrEqual(screen.title?.count ?? 0, HUDTextShaper.maxTitleLength)
                }
            }
        }
    }

    func testLaterAndDismissNeverTakeAButton() {
        for card in LensCardFixtures.all {
            let screen = stack([card], 0, ray)
            XCTAssertFalse(screen.items.contains { $0.label == "Later" || $0.label == "Dismiss" }, "\(card.kind)")
        }
    }

    func testEachButtonReportsItsActionWithTheCard() {
        var presses: [PreparedCardLensPress] = []
        let cards = [LensCardFixtures.leaveBy, LensCardFixtures.fitItIn]
        let screen = stack(cards, 0, ray) { presses.append($0) }
        screen.items.forEach { $0.action() }
        let id = LensCardFixtures.leaveBy.id
        XCTAssertEqual(presses, [
            PreparedCardLensPress(action: .run(.directions(destination: "1 Example Street", mode: .driving)), cardID: id),
            PreparedCardLensPress(action: .draft, cardID: id),
            PreparedCardLensPress(action: .nextCard, cardID: id),
        ])
        presses = []
        stack(cards, 1, ray) { presses.append($0) }.items.forEach { $0.action() }
        XCTAssertEqual(presses.map(\.action), [.run(.complete(reminderId: "reminder-1")), .close],
                       "fit it in has no draft and nothing else to do")
    }

    // MARK: - The draft

    func testAShortDraftIsOnePageWithSendOnPhone() {
        var presses: [PreparedCardLensAction] = []
        let screen = draft(LensCardFixtures.leaveBy, ray) { presses.append($0.action) }
        XCTAssertEqual(screen.title, "To Ana Example · Messages")
        XCTAssertEqual(screen.lines, [HUDLine("On my way — there about 18:45.")])
        XCTAssertEqual(screen.items.map(\.label), ["Send on phone", "Read it", "‹ Back"])
        screen.items.forEach { $0.action() }
        XCTAssertEqual(presses, [.sendOnPhone, .readIt, .back])
        XCTAssertTrue(HUDExit.hasExit(screen))
    }

    func testAPagedDraftShowsNextUntilItsLastPage() {
        let card = LensCardFixtures.shortNight
        let pages = PreparedCardHUDBuilder.draftPages(card, geometry: ray)
        XCTAssertGreaterThan(pages.count, 1)
        for index in pages.indices {
            let screen = draft(card, page: index, ray)
            let isLast = index == pages.count - 1
            XCTAssertEqual(screen.items.first?.label, isLast ? "Send on phone" : "Next ›", "page \(index)")
            XCTAssertEqual(screen.items.first?.id, isLast ? PreparedCardHUDBuilder.ItemID.send
                                                          : PreparedCardHUDBuilder.ItemID.draftNext)
            XCTAssertEqual(screen.lines.last?.text, "\(index + 1)/\(pages.count)")
        }
        XCTAssertFalse((0..<pages.count - 1).contains { draft(card, page: $0, ray).items.contains { $0.label == "Send on phone" } },
                       "the whole message is seen before it can be staged")
    }

    // MARK: - Sensitivity on the lens (§6.6)

    func testAHealthChipShowsAsShortNightOnTheLens() {
        let card = LensCardFixtures.shortNight
        for geometry in [ray, even] {
            let screen = stack([card], 0, geometry)
            let text = ([screen.title ?? ""] + screen.lines.map(\.text) + screen.items.map(\.label)).joined(separator: " ")
            XCTAssertTrue(text.contains("Short night"), text)
            XCTAssertFalse(text.contains("Slept"), "the hours slept never reach the lens")
            XCTAssertFalse(text.contains("5h"))
        }
        XCTAssertEqual(PreparedCardHUDBuilder.lensChips(card), ["Short night", "Free from 10:00"])
    }

    func testPersonalAndOrdinaryChipsShowAsTheyAre() {
        XCTAssertEqual(PreparedCardHUDBuilder.lensChips(LensCardFixtures.meetingFollowUp), ["3 things agreed", "09:00"])
        XCTAssertEqual(PreparedCardHUDBuilder.lensChips(LensCardFixtures.jobReportOwed), ["Job 1003", "Report not sent"])
    }

    // MARK: - The web mirror (§6.6)

    func testTheMirrorShowsAnOrdinaryCardAsTheLensDoes() {
        let screen = stack([LensCardFixtures.leaveBy], 0, ray)
        let payload = WebHUDPayload.from(screen: screen)
        XCTAssertEqual(payload.title, "Leave by 18:15")
        XCTAssertEqual(payload.lines.map(\.text), screen.lines.map(\.text))
        XCTAssertEqual(payload.renderKey, screen.renderKey)
    }

    func testTheMirrorHidesADraftsTextForOrdinaryAndPersonalCards() {
        for card in [LensCardFixtures.leaveBy, LensCardFixtures.meetingFollowUp, LensCardFixtures.jobOnMyWay] {
            let screen = draft(card, ray)
            let payload = WebHUDPayload.from(screen: screen)
            let shown = payload.lines.map(\.text).joined(separator: " ")
            XCTAssertEqual(payload.lines.map(\.text), [PreparedCardHUDBuilder.mirrorDraftHiddenLine], "\(card.kind)")
            XCTAssertFalse(shown.contains("way"), "\(card.kind)")
            XCTAssertNil(payload.pages)
            XCTAssertEqual(payload.items.map(\.label), screen.items.map(\.label), "the buttons still show")
            XCTAssertEqual(payload.title, screen.title)
        }
        // A personal card's stack screen is as the lens shows it: only its draft's text is hidden.
        let personal = stack([LensCardFixtures.meetingFollowUp], 0, ray)
        XCTAssertNil(personal.mirror)
        XCTAssertEqual(WebHUDPayload.from(screen: personal).lines.map(\.text), personal.lines.map(\.text))
    }

    func testTheMirrorHidesAHealthCardEverywhere() {
        let card = LensCardFixtures.shortNight
        let screens = [stack([card], 0, ray), draft(card, ray),
                       PreparedCardHUDBuilder.glance(card, geometry: ray) { _ in }]
        for screen in screens {
            let payload = WebHUDPayload.from(screen: screen)
            XCTAssertNil(payload.title)
            XCTAssertEqual(payload.lines.map(\.text), [PreparedCardHUDBuilder.mirrorHiddenLine])
            XCTAssertTrue(payload.items.isEmpty)
            let json = String(decoding: payload.jsonData(), as: UTF8.self)
            XCTAssertFalse(json.contains("Example review"))
            XCTAssertFalse(json.contains("Short night"))
            XCTAssertFalse(json.contains("Slept"))
        }
    }

    // MARK: - The glance (§6.2)

    func testAGlanceIsTheHeadlineOneFactOpenAndClose() {
        var presses: [PreparedCardLensAction] = []
        let screen = PreparedCardHUDBuilder.glance(LensCardFixtures.leaveBy, geometry: ray) { presses.append($0.action) }
        XCTAssertEqual(screen.title, "Leave by 18:15")
        XCTAssertEqual(screen.lines.map(\.text), ["Travel 30 min · Driving"])
        XCTAssertEqual(screen.items.map(\.label), ["Open", "Close"])
        XCTAssertEqual(screen.resolvedFocusItemID, PreparedCardHUDBuilder.ItemID.open)
        XCTAssertTrue(HUDExit.hasExit(screen))
        screen.items.forEach { $0.action() }
        XCTAssertEqual(presses, [.open, .close])
    }

    // MARK: - The push policy (§6.2)

    private func context(_ availability: DisplayAvailability = .ours, worn: Bool? = true, quiet: Bool = false,
                         lensFree: Bool = true, hasDisplay: Bool = true) -> PreparedCardPushPolicy.Context {
        .init(availability: availability, hasDisplay: hasDisplay, worn: worn, quiet: quiet, lensFree: lensFree)
    }

    func testOnlyTheFourKindsPushAndOnlyWhenImmediate() {
        let all = LensCardFixtures.all
        let pushable = all.filter(PreparedCardPushPolicy.isPushable).map(\.kind)
        XCTAssertEqual(Set(pushable), [.leaveBy, .runningLate, .jobRunningLate, .jobOnMyWay])
        var notYet = LensCardFixtures.leaveBy
        notYet = PreparedCard(id: notYet.id, headline: notYet.headline, subject: nil, signals: notYet.signals,
                              facts: notYet.facts, primary: notYet.primary, urgency: .important,
                              dueAt: notYet.dueAt, validUntil: notYet.validUntil)
        XCTAssertFalse(PreparedCardPushPolicy.isPushable(notYet), "leave-by more than ten minutes away is pulled only")
        XCTAssertNil(PreparedCardPushPolicy.decide(cards: [notYet, LensCardFixtures.meetingFollowUp],
                                                   pushed: [], context: context()).push)
    }

    func testACardPushesOnce() {
        let card = LensCardFixtures.leaveBy
        XCTAssertEqual(PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: context()).push, card)
        XCTAssertNil(PreparedCardPushPolicy.decide(cards: [card], pushed: [card.id.rawValue], context: context()).push)
    }

    func testNothingIsPushedOrQueuedWhileTheDisplayIsInUse() {
        let cards = [LensCardFixtures.runningLate, LensCardFixtures.leaveBy]
        let decision = PreparedCardPushPolicy.decide(cards: cards, pushed: [], context: context(.inUse))
        XCTAssertNil(decision.push)
        XCTAssertEqual(decision.drop, cards.map(\.id), "spent: they do not come up when the Display is ours again")
        let back = PreparedCardPushPolicy.decide(cards: cards, pushed: Set(decision.drop.map(\.rawValue)),
                                                 context: context())
        XCTAssertNil(back.push)
    }

    func testAPushWaitsBehindACoveredLensAndIsDroppedWhenNoLongerImmediate() {
        let card = LensCardFixtures.leaveBy
        let waiting = PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: context(lensFree: false))
        XCTAssertNil(waiting.push)
        XCTAssertTrue(waiting.drop.isEmpty, "a covered lens is waited for, not spent")
        XCTAssertEqual(PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: context()).push, card)
        XCTAssertNil(PreparedCardPushPolicy.decide(cards: [], pushed: [], context: context()).push,
                     "once the card is gone (or no longer immediate), nothing goes up")
    }

    func testQuietHoursTheGlassesOffAndNoDisplayPushNothing() {
        let card = LensCardFixtures.runningLate
        for ctx in [context(quiet: true), context(worn: false), context(.off), context(hasDisplay: false)] {
            let decision = PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: ctx)
            XCTAssertNil(decision.push, "\(ctx)")
            XCTAssertTrue(decision.drop.isEmpty, "\(ctx)")
        }
        XCTAssertEqual(PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: context(worn: nil)).push, card,
                       "an unknown worn reading is not 'taken off'")
    }

    // MARK: - Staging (§6.4)

    func testTheStagingNotificationNamesTheRecipientAndNeverTheDraft() {
        let card = LensCardFixtures.leaveBy
        let content = PreparedCardStagingPolicy.content(for: card)
        XCTAssertEqual(content?.body, "Message to Ana Example ready — tap to send")
        XCTAssertEqual(content?.identifier, "my-day.staged.\(card.id.rawValue)")
        XCTAssertFalse((content?.body ?? "").contains("18:45"))
        XCTAssertFalse((content?.title ?? "").contains("way"))
        XCTAssertNil(PreparedCardStagingPolicy.content(for: LensCardFixtures.fitItIn), "no draft, nothing to stage")

        let info = PreparedCardStagingPolicy.userInfo(for: card.id)
        XCTAssertTrue(PreparedCardStagingPolicy.isStaged(info))
        XCTAssertEqual(PreparedCardNotificationPolicy.cardID(from: info), card.id)
        XCTAssertFalse(PreparedCardStagingPolicy.isStaged([PreparedCardNotificationPolicy.cardKey: card.id.rawValue]))
    }

    func testTheComposerOpensStraightAwayOnlyInFrontAndUnlocked() {
        XCTAssertTrue(PreparedCardStagingPolicy.opensComposerNow(appInFront: true, unlocked: true))
        XCTAssertFalse(PreparedCardStagingPolicy.opensComposerNow(appInFront: true, unlocked: false))
        XCTAssertFalse(PreparedCardStagingPolicy.opensComposerNow(appInFront: false, unlocked: true))
    }

    func testStagingPostsTheNotificationWhenThePhoneIsAway() async {
        let stager = PreparedCardStager()
        var recorded: [PreparedCardID] = []
        var opened: [PreparedCardID] = []
        var posted: [PreparedCardNotificationContent] = []
        var removed: [String] = []
        stager.record = { recorded.append($0.id) }
        stager.openComposer = { opened.append($0.id) }
        stager.post = { posted.append($0) }
        stager.remove = { removed += $0 }
        stager.appInFront = { false }
        stager.unlocked = { false }

        let card = LensCardFixtures.leaveBy
        let outcome = await stager.stage(card)
        XCTAssertEqual(outcome, .notified)
        XCTAssertEqual(recorded, [card.id])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(posted, [PreparedCardStagingPolicy.content(for: card)!])

        // The card leaves the feed (sent, or past validUntil): its notification goes with it.
        stager.feedChanged(TodayFeed(cards: [LensCardFixtures.runningLate], rows: [], overflow: [], absorbed: []))
        XCTAssertEqual(removed, [PreparedCardStagingPolicy.identifier(for: card.id)])
    }

    func testStagingOpensTheComposerWhenTheAppIsInFrontAndUnlocked() async {
        let stager = PreparedCardStager()
        var opened: [PreparedCardID] = []
        var posted = 0
        var recorded = 0
        stager.record = { _ in recorded += 1 }
        stager.openComposer = { opened.append($0.id) }
        stager.post = { _ in posted += 1 }
        stager.appInFront = { true }
        stager.unlocked = { true }
        let outcome = await stager.stage(LensCardFixtures.runningLate)
        XCTAssertEqual(outcome, .openedComposer)
        XCTAssertEqual(opened, [LensCardFixtures.runningLate.id])
        XCTAssertEqual(recorded, 1)
        XCTAssertEqual(posted, 0)
        let nothing = await stager.stage(LensCardFixtures.fitItIn)
        XCTAssertEqual(nothing, .nothingToStage)
        XCTAssertEqual(recorded, 1)
    }

    func testAStagedCardStaysOnThePageUntilItEnds() {
        let now = CardFixtures.at(18)
        XCTAssertTrue(PreparedCardState.staged(at: now).isShown(at: now.addingTimeInterval(600)))
        let card = CardFixtures.card(.leaveBy, "a", validUntil: CardFixtures.at(19))
        let memory = [card.card.id: PreparedCardMemory(state: .staged(at: now), changedAt: now)]
        XCTAssertEqual(CardFixtures.joiner.join([card], items: [], memory: memory, now: now).cards.map(\.id), [card.card.id])
        XCTAssertTrue(CardFixtures.joiner.join([card], items: [], memory: memory, now: CardFixtures.at(19)).cards.isEmpty,
                      "staged lasts until validUntil")
    }

    func testAStagedStateRoundTripsThroughTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = CardFixtures.at(18)
        let card = LensCardFixtures.leaveBy
        let store = PreparedCardStore(directory: directory)
        store.record(.staged(at: now), for: card, now: now)
        let reloaded = PreparedCardStore(directory: directory)
        XCTAssertEqual(reloaded.entry(for: card.id)?.memory.state, .staged(at: now))
        XCTAssertNil(reloaded.entry(for: card.id)?.memory.editedText, "the staged draft is not written down")
    }

    // MARK: - Words, the temple tap and the launcher

    func testTheCardWords() {
        XCTAssertEqual(PreparedCardVoiceCommand.parse("Next card"), .nextCard)
        XCTAssertEqual(PreparedCardVoiceCommand.parse("later"), .later)
        XCTAssertEqual(PreparedCardVoiceCommand.parse("Not useful."), .notUseful)
        XCTAssertEqual(PreparedCardVoiceCommand.parse("OK, send it on my phone"), .sendOnPhone)
        XCTAssertEqual(PreparedCardVoiceCommand.parse("read it"), .readIt)
        XCTAssertEqual(PreparedCardVoiceCommand.parse("next"), .next)
        XCTAssertNil(PreparedCardVoiceCommand.parse("text Ana that I'll be later"))
        XCTAssertNil(PreparedCardVoiceCommand.parse("is that useful"))
        XCTAssertEqual(HUDVoiceCommand.parse("What's ready?"), .briefing)
        XCTAssertEqual(HUDVoiceCommand.parse("what's next"), .briefing)
        XCTAssertEqual(HUDVoiceCommand.parse("catch me up"), .briefing)
    }

    func testTheTempleTapOpensTheCardsOnlyWhenThereAreSome() {
        XCTAssertEqual(TempleAction(rawValue: "today"), .today)
        XCTAssertTrue(TempleAction.builtIns.contains(.today))
        XCTAssertEqual(TempleAction.builtIns.last, .nothing)
        XCTAssertEqual(TempleActionResolver.resolve(action: .today, context: TempleContext(activity: .standby, cardsReady: true)),
                       .run(.openCards))
        XCTAssertEqual(TempleActionResolver.resolve(action: .today, context: TempleContext(activity: .speaking, cardsReady: true)),
                       .run(.openCards))
        XCTAssertEqual(TempleActionResolver.resolve(action: .today, context: TempleContext(activity: .standby)),
                       .ignored(.noCards))
        XCTAssertEqual(TempleActionResolver.resolve(action: .today, context: TempleContext(activity: .busy, cardsReady: true)),
                       .ignored(.busy))
        XCTAssertEqual(TempleEarcon.for(.run(.openCards)), .accepted)
    }

    func testTodayOffersReadyFirstAndFocusedWhenThereAreCards() {
        let actions = HUDTodayBuilder.Actions(ready: {}, whatsNew: {}, menu: {}, close: {})
        let screen = HUDTodayBuilder.screen(HUDTodayGlance(time: "09:41"), actions: actions)
        XCTAssertEqual(screen.items.first?.id, HUDTodayBuilder.ItemID.ready)
        XCTAssertEqual(screen.items.first?.label, "Ready")
        XCTAssertEqual(screen.resolvedFocusItemID, HUDTodayBuilder.ItemID.ready)
        let none = HUDTodayBuilder.screen(HUDTodayGlance(time: "09:41"),
                                          actions: HUDTodayBuilder.Actions(whatsNew: {}, close: {}))
        XCTAssertFalse(none.items.contains { $0.id == HUDTodayBuilder.ItemID.ready })
    }

    // MARK: - Recorded snapshots

    static let snapshots: [String: String] = [
        "draft.jobOnMyWay.even":
            "To Hana Example · Messages|primary:none:Hi Hana, it's Sam from Example Plumbing.¦primary:none:On my way, there about 09:55.|kt.draft.send:primary:message:Send on phone¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.jobOnMyWay.ray":
            "To Hana Example · Messages|primary:none:Hi Hana, it's Sam from Example¦primary:none:Plumbing. On my way, there about¦primary:none:09:55.|kt.draft.send:primary:message:Send on phone¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.jobRunningLate.even":
            "To Hana Example · Messages|primary:none:Hi Hana, running about 15 minutes behind¦primary:none:— there about 10:15. Sorry for the wait.|kt.draft.send:primary:message:Send on phone¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.jobRunningLate.ray":
            "To Hana Example · Messages|primary:none:Hi Hana, running about 15¦primary:none:minutes behind — there about¦primary:none:10:15. Sorry for the wait.|kt.draft.send:primary:message:Send on phone¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.leaveBy.even":
            "To Ana Example · Messages|primary:none:On my way — there about 18:45.|kt.draft.send:primary:message:Send on phone¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.leaveBy.ray":
            "To Ana Example · Messages|primary:none:On my way — there about 18:45.|kt.draft.send:primary:message:Send on phone¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.meetingFollowUp.even":
            "To Tom Example and 2 others · Email|primary:none:Hi all,¦primary:none:Thanks for this morning.¦meta:none:1/5|kt.draft.next:primary:none:Next ›¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.meetingFollowUp.ray":
            "To Tom Example and 2 others · Email|primary:none:Hi all,¦primary:none:Thanks for this morning. What we¦primary:none:agreed:¦meta:none:1/4|kt.draft.next:primary:none:Next ›¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.runningLate.even":
            "To Ana Example · Messages|primary:none:Running about 10 minutes late, sorry —¦primary:none:there about 19:10.|kt.draft.send:primary:message:Send on phone¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.runningLate.ray":
            "To Ana Example · Messages|primary:none:Running about 10 minutes late,¦primary:none:sorry — there about 19:10.|kt.draft.send:primary:message:Send on phone¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.shortNight.even":
            "To Tom Example · Email|primary:none:Hi Tom,¦primary:none:Could we move the Example review to¦meta:none:1/5|kt.draft.next:primary:none:Next ›¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "draft.shortNight.ray":
            "To Tom Example · Email|primary:none:Hi Tom,¦primary:none:Could we move the Example review¦primary:none:to 10:00?¦meta:none:1/4|kt.draft.next:primary:none:Next ›¦kt.draft.read:secondary:none:Read it¦kt.draft.back:outline:none:‹ Back",
        "stack.fitItIn.even":
            "Fit it in: Post the parcel|meta:reminder:Post the parcel · Free till 15:00¦secondary:none:Free 14:00–15:00¦meta:none:10/10|kt.primary:primary:success:Done¦kt.close:outline:none:Close|focus:kt.primary",
        "stack.fitItIn.ray":
            "Fit it in: Post the parcel|meta:reminder:Post the parcel¦secondary:none:Free 14:00–15:00¦meta:none:10/10|kt.primary:primary:success:Done¦kt.close:outline:none:Close|focus:kt.primary",
        "stack.jobOnMyWay.even":
            "Leave by 09:30 for job 1005|meta:info:Job 1005 · 14 Example Street · 25 min¦secondary:none:Customer Hana Example¦meta:none:2/10|kt.primary:primary:navigation:Directions¦kt.second:secondary:message:Text Hana¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.jobOnMyWay.ray":
            "Leave by 09:30 for job 1005|meta:info:Job 1005 · 14 Example Street¦secondary:none:Customer Hana Example¦secondary:none:Scheduled 10:00¦meta:none:2/10|kt.primary:primary:navigation:Directions¦kt.second:secondary:message:Text Hana¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.jobPartsOwed.even":
            "Parts not ordered|meta:info:Job 1004 · 2 parts¦secondary:none:Parts 2¦meta:none:4/10|kt.primary:primary:none:Send parts order¦kt.second:secondary:none:Open job¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.jobPartsOwed.ray":
            "Parts not ordered|meta:info:Job 1004 · 2 parts¦secondary:none:Parts 2¦meta:none:4/10|kt.primary:primary:none:Send parts order¦kt.second:secondary:none:Open job¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.jobReportOwed.even":
            "Report not sent|meta:info:Job 1003 · Report not sent¦secondary:none:Customer Example Customer¦meta:none:3/10|kt.primary:primary:none:Send report¦kt.second:secondary:none:Open job¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.jobReportOwed.ray":
            "Report not sent|meta:info:Job 1003 · Report not sent¦secondary:none:Customer Example Customer¦secondary:none:Ended 11:40¦meta:none:3/10|kt.primary:primary:none:Send report¦kt.second:secondary:none:Open job¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.jobRunningLate.even":
            "Running late to job 1005|meta:info:Job 1005 · 20 min away¦secondary:none:Scheduled 10:00¦meta:none:1/10|kt.primary:primary:message:Text Hana¦kt.second:secondary:navigation:Directions¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.jobRunningLate.ray":
            "Running late to job 1005|meta:info:Job 1005 · 20 min away¦secondary:none:Scheduled 10:00¦secondary:none:Arrive about 10:15¦meta:none:1/10|kt.primary:primary:message:Text Hana¦kt.second:secondary:navigation:Directions¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.jobSignOffOwed.even":
            "Sign-off owed|meta:info:Job 1002¦secondary:none:Customer Example Customer¦meta:none:5/10|kt.primary:primary:none:Get sign-off¦kt.second:secondary:none:Open job¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.jobSignOffOwed.ray":
            "Sign-off owed|meta:info:Job 1002¦secondary:none:Customer Example Customer¦meta:none:5/10|kt.primary:primary:none:Get sign-off¦kt.second:secondary:none:Open job¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.leaveBy.even":
            "Leave by 18:15|meta:calendar:19:00 · You're in Example Bay¦secondary:none:Travel 30 min · Driving¦meta:none:7/10|kt.primary:primary:navigation:Directions¦kt.second:secondary:message:Text Ana¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.leaveBy.ray":
            "Leave by 18:15|meta:calendar:19:00 · You're in Example Bay¦secondary:none:Travel 30 min · Driving¦secondary:none:Arrive by 18:45¦meta:none:7/10|kt.primary:primary:navigation:Directions¦kt.second:secondary:message:Text Ana¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.meetingFollowUp.even":
            "Send a recap|meta:microphone:3 things agreed · 09:00¦secondary:none:Agreed Example Co sends the revised quo…¦meta:none:9/10|kt.primary:primary:message:Email recap¦kt.second:secondary:calendar:Open event¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.meetingFollowUp.ray":
            "Send a recap|meta:microphone:3 things agreed · 09:00¦secondary:none:Agreed Example Co sends the rev…¦secondary:none:Agreed Sam books the site visit¦meta:none:9/10|kt.primary:primary:message:Email recap¦kt.second:secondary:calendar:Open event¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.runningLate.even":
            "Running about 10 min late|meta:calendar:Starts 19:00 · 25 min away¦secondary:none:Starts 19:00¦meta:none:6/10|kt.primary:primary:message:Text Ana¦kt.second:secondary:navigation:Directions¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.runningLate.ray":
            "Running about 10 min late|meta:calendar:Starts 19:00 · 25 min away¦secondary:none:Starts 19:00¦secondary:none:Arrive about 19:10¦meta:none:6/10|kt.primary:primary:message:Text Ana¦kt.second:secondary:navigation:Directions¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.shortNight.even":
            "Ask to move Example review|meta:clock:Short night · Free from 10:00¦secondary:none:Meeting 08:30¦meta:none:8/10|kt.primary:primary:message:Email Tom¦kt.second:secondary:calendar:Open event¦kt.next:outline:none:Next ›|focus:kt.primary",
        "stack.shortNight.ray":
            "Ask to move Example review|meta:clock:Short night · Free from 10:00¦secondary:none:Meeting 08:30¦secondary:none:Proposed 10:00¦meta:none:8/10|kt.primary:primary:message:Email Tom¦kt.second:secondary:calendar:Open event¦kt.next:outline:none:Next ›|focus:kt.primary",
    ]
}
