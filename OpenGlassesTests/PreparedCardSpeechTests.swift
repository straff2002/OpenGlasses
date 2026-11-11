import XCTest
@testable import OpenGlasses

/// Plan KT P4 — the cards by voice: `PreparedCardPhraser` per kind and sensitivity, the "what's
/// ready?" reading and its words, a spoken yes that only stages, and pushed cards said when the
/// Display can't show them. Invented data only (`LensCardFixtures`).
@MainActor
final class PreparedCardSpeechTests: XCTestCase {

    private let time: (Date) -> String = { _ in "08:30" }

    private func phrase(_ card: PreparedCard, asked: Bool = false, withholding: Bool = false) -> PreparedCardPhrase {
        PreparedCardPhraser.phrase(card, askedAboutSleep: asked, withholding: withholding, time: time)
    }

    /// Sentences: a full stop, question mark or exclamation followed by a space or the end.
    private func sentences(_ text: String) -> Int {
        let pattern = try! NSRegularExpression(pattern: "[.?!…](\\s|$)")
        return pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // MARK: - The phraser, per kind

    func testEveryKindIsSaidInAtMostTwoSentences() {
        for card in LensCardFixtures.all {
            for asked in [false, true] {
                let text = phrase(card, asked: asked).text
                XCTAssertFalse(text.isEmpty, "\(card.kind)")
                XCTAssertLessThanOrEqual(sentences(text), 2, "\(card.kind): \(text)")
            }
        }
    }

    func testLeaveByIsItsHeadlineSubjectAndWeatherThenTheOffer() {
        let said = phrase(LensCardFixtures.leaveBy)
        XCTAssertEqual(said.statement, "Leave by 18:15 for Gig at the Example Hall — Rain from 18:00.")
        XCTAssertEqual(said.offer, "Want me to get a message to Ana ready?")
        XCTAssertTrue(said.offersStage)
        XCTAssertFalse(said.text.contains("Example Bay"), "the location chip is not said")
    }

    func testRunningLateOffersTheMessage() {
        let said = phrase(LensCardFixtures.runningLate)
        XCTAssertEqual(said.text, "Running about 10 min late for Gig at the Example Hall. Want me to get a message to Ana ready?")
    }

    func testShortNightIsSaidWithoutSleep() {
        let said = phrase(LensCardFixtures.shortNight)
        XCTAssertEqual(said.text, "Your 08:30 with Tom — want to ask to move it?")
        XCTAssertTrue(said.offersStage)
        XCTAssertFalse(said.text.contains("Slept"))
        XCTAssertFalse(said.text.contains("5h"))
        XCTAssertFalse(said.text.contains("Short night"))
    }

    func testSleepIsSaidOnlyWhenTheWearerAskedAboutIt() {
        let asked = phrase(LensCardFixtures.shortNight, asked: true)
        XCTAssertEqual(asked.text, "Slept 5h 10m. Your 08:30 with Tom — want to ask to move it?")
        for card in LensCardFixtures.all {
            let text = phrase(card).text
            XCTAssertFalse(text.contains("Slept") || text.contains("5h 10m"), "\(card.kind): \(text)")
        }
    }

    func testPersonalSaysTheHeadlineOnly() {
        let said = phrase(LensCardFixtures.meetingFollowUp)
        XCTAssertEqual(said.statement, "Send a recap.")
        XCTAssertEqual(said.offer, "Want me to put it on your phone?", "to several people: no name")
        XCTAssertFalse(said.text.contains("Example planning"), "no subject")
        XCTAssertFalse(said.text.contains("agreed"), "no chips")
    }

    func testCaptionTextIsNeverQuoted() {
        // The meeting's agreed items come from captions, and every draft's text is never part of a phrase.
        let items = LensCardFixtures.meetingFollowUp.facts.map(\.value)
        for card in LensCardFixtures.all {
            for asked in [false, true] {
                let text = phrase(card, asked: asked).text
                for item in items { XCTAssertFalse(text.contains(item), "\(card.kind)") }
                if let draft = card.draft?.text {
                    XCTAssertFalse(text.contains(draft), "\(card.kind)")
                    let firstLine = draft.split(separator: "\n").first.map(String.init) ?? draft
                    XCTAssertFalse(text.contains(firstLine), "\(card.kind)")
                }
            }
        }
    }

    func testJobKindsOfferATextToTheCustomerAndTheRestOfferNothing() {
        XCTAssertEqual(phrase(LensCardFixtures.jobOnMyWay).offer, "Shall I get an on-my-way text ready for Hana?")
        XCTAssertEqual(phrase(LensCardFixtures.jobRunningLate).offer, "Shall I get a text ready for Hana?")
        XCTAssertEqual(phrase(LensCardFixtures.jobReportOwed).text, "Report not sent for Job 1003.")
        for card in [LensCardFixtures.fitItIn, LensCardFixtures.jobReportOwed, LensCardFixtures.jobPartsOwed,
                     LensCardFixtures.jobSignOffOwed] {
            XCTAssertNil(phrase(card).offer, "\(card.kind): no draft, nothing to offer")
            XCTAssertFalse(phrase(card).offersStage)
        }
    }

    func testAnEmailOfferSaysEmail() {
        let card = LensCardFixtures.leaveBy
        let email = PreparedCard(id: card.id, headline: card.headline, subject: card.subject, signals: card.signals,
                                 facts: card.facts, primary: card.primary, secondary: card.secondary,
                                 draft: LensCardFixtures.draft(LensCardFixtures.tom, "On my way.", channel: .email),
                                 urgency: card.urgency, dueAt: card.dueAt, validUntil: card.validUntil)
        XCTAssertEqual(phrase(email).offer, "Want me to get an email to Tom ready?")
    }

    func testReadItSaysTheDraftWithWhoItIsTo() {
        XCTAssertEqual(PreparedCardPhraser.draftReading(LensCardFixtures.leaveBy),
                       "To Ana Example: On my way — there about 18:45.")
        XCTAssertNil(PreparedCardPhraser.draftReading(LensCardFixtures.fitItIn))
    }

    // MARK: - "What's ready?" — the reading

    private func reading(_ cards: [PreparedCard], at now: Date = CardFixtures.at(9)) -> PreparedCardSpokenStack {
        PreparedCardSpokenStack(cards: cards, withholding: false, now: now, time: time)!
    }

    func testTheReadingOpensWithTheCountAndTheFirstCard() {
        let three = reading([LensCardFixtures.runningLate, LensCardFixtures.leaveBy, LensCardFixtures.fitItIn])
        XCTAssertEqual(three.opening(),
                       "3 things. First: Running about 10 min late for Gig at the Example Hall. Want me to get a message to Ana ready?")
        XCTAssertEqual(reading([LensCardFixtures.fitItIn]).opening(), "Fit it in: Post the parcel.",
                       "one card is just the card")
        XCTAssertNil(PreparedCardSpokenStack(cards: [], withholding: false, now: CardFixtures.at(9)))
    }

    func testTheWordsWhileItReads() {
        let cases: [(String, PreparedCardSpokenStack.Answer?)] = [
            ("yes", .yes), ("Yes please", .yes), ("yeah", .yes), ("go ahead", .yes), ("send it on my phone", .yes),
            ("no", .next), ("next", .next), ("skip", .next), ("skip it", .next), ("next card", .next),
            ("later", .later), ("not now", .later), ("not useful", .notUseful), ("dismiss", .dismiss),
            ("back", .back), ("again", .again), ("read it", .readIt),
            ("stop", .stop), ("cancel", .stop), ("that's all", .stop), ("close", .stop),
            ("what's the weather tomorrow", nil), ("yes I think we should go to the beach", nil), ("", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(PreparedCardSpokenStack.Answer.parse(text), expected, text)
        }
    }

    func testTheStackIsReadOneCardAtATime() {
        var stack = reading([LensCardFixtures.runningLate, LensCardFixtures.leaveBy, LensCardFixtures.fitItIn])
        let next = stack.answer(.next)
        XCTAssertNil(next.effect)
        XCTAssertEqual(next.say, "Next: \(phrase(LensCardFixtures.leaveBy).text)")
        XCTAssertTrue(next.awaiting)
        let later = stack.answer(.later)
        XCTAssertEqual(later.effect, .later(LensCardFixtures.leaveBy.id))
        XCTAssertEqual(later.say, "Last one: Fit it in: Post the parcel.")
        let last = stack.answer(.notUseful)
        XCTAssertEqual(last.effect, .notUseful(LensCardFixtures.fitItIn.id))
        XCTAssertEqual(last.say, "That's everything.")
        XCTAssertFalse(last.awaiting)
        XCTAssertNil(stack.current)
    }

    func testAYesStagesOnlyWhenTheCardOffersIt() {
        var stack = reading([LensCardFixtures.fitItIn, LensCardFixtures.leaveBy])
        let noOffer = stack.answer(.yes)
        XCTAssertNil(noOffer.effect, "fit it in offers nothing: a yes moves on")
        let staged = stack.answer(.yes)
        XCTAssertEqual(staged.effect, .stage(LensCardFixtures.leaveBy.id), "the only thing a yes can do")
    }

    func testBackAgainReadItAndStop() {
        var stack = reading([LensCardFixtures.leaveBy, LensCardFixtures.runningLate])
        XCTAssertEqual(stack.answer(.back).say, phrase(LensCardFixtures.leaveBy).text, "nothing before the first")
        _ = stack.answer(.next)
        XCTAssertEqual(stack.answer(.again).say, phrase(LensCardFixtures.runningLate).text)
        XCTAssertEqual(stack.answer(.back).say, phrase(LensCardFixtures.leaveBy).text)
        let read = stack.answer(.readIt)
        XCTAssertEqual(read.say, "To Ana Example: On my way — there about 18:45. Want me to get a message to Ana ready?")
        XCTAssertNil(read.effect)
        let stop = stack.answer(.stop)
        XCTAssertFalse(stop.awaiting)
        XCTAssertEqual(stop.say, PreparedCardSpokenStack.stoppedLine)
        XCTAssertNil(stop.effect)
    }

    func testAnAnswerCountsOnlyInsideTheWindow() {
        let start = CardFixtures.at(9)
        var stack = reading([LensCardFixtures.leaveBy], at: start)
        XCTAssertTrue(stack.isLive(at: start.addingTimeInterval(PreparedCardSpokenStack.answerWindow)))
        XCTAssertFalse(stack.isLive(at: start.addingTimeInterval(PreparedCardSpokenStack.answerWindow + 1)))
        stack.noteSpoke(at: start.addingTimeInterval(120))
        XCTAssertTrue(stack.isLive(at: start.addingTimeInterval(130)), "the window starts when the line was said")
    }

    // MARK: - The controller: a spoken yes only stages

    private final class Rig {
        var cards: [PreparedCard]
        var said: [(String, Bool)] = []
        var staged: [PreparedCardID] = []
        var later: [PreparedCardID] = []
        var notUseful: [PreparedCardID] = []
        var dismissed: [PreparedCardID] = []
        var now = CardFixtures.at(9)
        var outcome: PreparedCardStager.Outcome = .notified
        init(_ cards: [PreparedCard]) { self.cards = cards }
    }

    private func speech(_ rig: Rig, withholding: Bool = false) -> PreparedCardSpeech {
        let speech = PreparedCardSpeech()
        speech.cards = { rig.cards }
        speech.stage = { card in rig.staged.append(card.id); return rig.outcome }
        speech.later = { rig.later.append($0.id) }
        speech.notUseful = { rig.notUseful.append($0.id) }
        speech.dismiss = { rig.dismissed.append($0.id) }
        speech.voice = { text, source in rig.said.append((text, source == .alert)) }
        speech.withholding = { withholding }
        speech.now = { rig.now }
        speech.time = time
        return speech
    }

    func testWhatsReadyReadsTheStackAndAYesOnlyStages() async {
        let rig = Rig([LensCardFixtures.leaveBy, LensCardFixtures.fitItIn])
        let speech = speech(rig)
        let started = await speech.readStack()
        XCTAssertTrue(started)
        XCTAssertEqual(rig.said.first?.0.hasPrefix("2 things. First: Leave by 18:15"), true)
        XCTAssertEqual(rig.said.first?.1, false, "asked for, not pushed")
        XCTAssertTrue(speech.isAwaitingAnswer, "the follow-up capture stays open")

        let consumed = await speech.handle("yes")
        XCTAssertTrue(consumed)
        XCTAssertEqual(rig.staged, [LensCardFixtures.leaveBy.id], "the yes staged the draft — and did nothing else")
        XCTAssertTrue(rig.later.isEmpty && rig.dismissed.isEmpty && rig.notUseful.isEmpty)
        XCTAssertEqual(rig.said.last?.0,
                       "It's on your phone — tap the notification to send. Last one: Fit it in: Post the parcel.")

        _ = await speech.handle("yes")
        XCTAssertEqual(rig.staged, [LensCardFixtures.leaveBy.id], "a yes to a card with no draft stages nothing")
        XCTAssertEqual(rig.said.last?.0, "That's everything.")
        XCTAssertFalse(speech.isAwaitingAnswer)
        let after = await speech.handle("yes")
        XCTAssertFalse(after, "once the reading is over a yes is not an answer")
        XCTAssertEqual(rig.staged.count, 1)
    }

    func testAComposerAlreadyOpenSaysSo() async {
        let rig = Rig([LensCardFixtures.runningLate])
        rig.outcome = .openedComposer
        let speech = speech(rig)
        await speech.readStack()
        _ = await speech.handle("yeah")
        XCTAssertEqual(rig.said.last?.0, "It's open on your phone — tap Send there.")
    }

    func testLaterNotUsefulAndDismissActOnTheLiveCard() async {
        let rig = Rig([LensCardFixtures.leaveBy, LensCardFixtures.runningLate, LensCardFixtures.fitItIn])
        let speech = speech(rig)
        await speech.readStack()
        _ = await speech.handle("later")
        _ = await speech.handle("not useful")
        _ = await speech.handle("dismiss")
        XCTAssertEqual(rig.later, [LensCardFixtures.leaveBy.id])
        XCTAssertEqual(rig.notUseful, [LensCardFixtures.runningLate.id])
        XCTAssertEqual(rig.dismissed, [LensCardFixtures.fitItIn.id])
        XCTAssertTrue(rig.staged.isEmpty)
    }

    func testACardThatWentWhileItWasReadIsSkipped() async {
        let rig = Rig([LensCardFixtures.leaveBy])
        let speech = speech(rig)
        await speech.readStack()
        rig.cards = []
        _ = await speech.handle("yes")
        XCTAssertTrue(rig.staged.isEmpty, "nothing staged for a card no longer in the feed")
    }

    func testAStaleOrUnrelatedAnswerIsNotTaken() async {
        let rig = Rig([LensCardFixtures.leaveBy])
        let speech = speech(rig)
        await speech.readStack()
        rig.now = rig.now.addingTimeInterval(PreparedCardSpokenStack.answerWindow + 5)
        let late = await speech.handle("yes")
        XCTAssertFalse(late, "a yes after the window goes on to the model")
        XCTAssertTrue(rig.staged.isEmpty)
        XCTAssertNil(speech.reading)

        rig.now = CardFixtures.at(10)
        await speech.readStack()
        let other = await speech.handle("what's the weather tomorrow")
        XCTAssertFalse(other)
        XCTAssertNil(speech.reading, "anything else ends the reading")
        let yes = await speech.handle("yes")
        XCTAssertFalse(yes)
        XCTAssertTrue(rig.staged.isEmpty)
    }

    func testNoCardsNothingRead() async {
        let rig = Rig([])
        let started = await speech(rig).readStack()
        XCTAssertFalse(started, "the words go on to the digest")
        XCTAssertTrue(rig.said.isEmpty)
    }

    func testAPushedCardIsSaidAsPushedAndItsOfferStaysOpenForTheWindow() async {
        let rig = Rig([LensCardFixtures.runningLate])
        let speech = speech(rig)
        await speech.speakPushed(LensCardFixtures.runningLate)
        XCTAssertEqual(rig.said.first?.0, phrase(LensCardFixtures.runningLate).text)
        XCTAssertEqual(rig.said.first?.1, true)
        _ = await speech.handle("yes")
        XCTAssertEqual(rig.staged, [LensCardFixtures.runningLate.id])
    }

    func testReadItThroughThePhraser() async {
        let rig = Rig([])
        await speech(rig).readDraft(LensCardFixtures.leaveBy)
        XCTAssertEqual(rig.said.map(\.0), ["To Ana Example: On my way — there about 18:45."])
    }

    // MARK: - Pushed cards spoken (§6.5)

    private func context(_ availability: DisplayAvailability = .off, hasDisplay: Bool = false, worn: Bool? = true,
                         quiet: Bool = false, lensFree: Bool = true,
                         speech: PreparedCardPushPolicy.Speech = .init(glassesConnected: true, onCall: false,
                                                                       captionsRunning: false, busy: false))
        -> PreparedCardPushPolicy.Context {
        .init(availability: availability, hasDisplay: hasDisplay, worn: worn, quiet: quiet, lensFree: lensFree,
              speech: speech)
    }

    func testAPushedCardIsSpokenWhenTheLensCannotShowIt() {
        let card = LensCardFixtures.leaveBy
        for ctx in [context(.ours, hasDisplay: false), context(.off, hasDisplay: true), context(.inUse, hasDisplay: true)] {
            let decision = PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: ctx)
            XCTAssertEqual(decision.speak, card, "\(ctx.availability) display=\(ctx.hasDisplay)")
            XCTAssertNil(decision.push)
        }
        let lens = PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: context(.ours, hasDisplay: true))
        XCTAssertEqual(lens.push, card, "a lens that can show it shows it")
        XCTAssertNil(lens.speak, "never both")
    }

    func testOnlyPushableImmediateCardsAreSpokenAndOnce() {
        let decision = PreparedCardPushPolicy.decide(cards: [LensCardFixtures.meetingFollowUp, LensCardFixtures.fitItIn],
                                                     pushed: [], context: context())
        XCTAssertNil(decision.speak)
        let card = LensCardFixtures.runningLate
        XCTAssertNil(PreparedCardPushPolicy.decide(cards: [card], pushed: [card.id.rawValue], context: context()).speak,
                     "the once-memory a glance uses")
    }

    func testNeverDuringACallCaptionsQuietHoursOrWithTheGlassesOff() {
        let card = LensCardFixtures.runningLate
        let call = PreparedCardPushPolicy.Speech(glassesConnected: true, onCall: true, captionsRunning: false, busy: false)
        let captions = PreparedCardPushPolicy.Speech(glassesConnected: true, onCall: false, captionsRunning: true, busy: false)
        let away = PreparedCardPushPolicy.Speech(glassesConnected: false, onCall: false, captionsRunning: false, busy: false)
        for ctx in [context(speech: call), context(speech: captions), context(speech: away), context(quiet: true),
                    context(worn: false)] {
            let decision = PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: ctx)
            XCTAssertNil(decision.speak, "\(ctx)")
            XCTAssertNil(decision.push)
            XCTAssertTrue(decision.drop.isEmpty, "off: it may still be said once the call ends")
        }
        let inUseOnCall = PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: context(.inUse, hasDisplay: true, speech: call))
        XCTAssertNil(inUseOnCall.speak)
        XCTAssertEqual(inUseOnCall.drop, [card.id], "in use, it is spent as before: nothing queues")
    }

    func testItWaitsForTheWearersTurnToEnd() {
        let card = LensCardFixtures.runningLate
        let busy = PreparedCardPushPolicy.Speech(glassesConnected: true, onCall: false, captionsRunning: false, busy: true)
        let waiting = PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: context(speech: busy))
        XCTAssertNil(waiting.speak)
        XCTAssertTrue(waiting.drop.isEmpty)
        XCTAssertEqual(PreparedCardPushPolicy.decide(cards: [card], pushed: [], context: context()).speak, card)
    }

    func testTheP3ContextSpeaksNothing() {
        // A context built without speech (P3's) never speaks: `.unavailable` is the default.
        let ctx = PreparedCardPushPolicy.Context(availability: .inUse, hasDisplay: true, worn: true, quiet: false,
                                                 lensFree: true)
        let decision = PreparedCardPushPolicy.decide(cards: [LensCardFixtures.leaveBy], pushed: [], context: ctx)
        XCTAssertNil(decision.speak)
        XCTAssertEqual(decision.drop, [LensCardFixtures.leaveBy.id])
    }
}
