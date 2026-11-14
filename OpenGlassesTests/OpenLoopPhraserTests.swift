import XCTest
@testable import OpenGlasses

/// Plan LE P0 — `OpenLoopPhraser`: the count first and exact, four named at most, silent when the
/// scheduled check-in has nothing, "before you finish" with Field Assist on, and one question
/// when the first item is an approval.
final class OpenLoopPhraserTests: XCTestCase {
    private typealias F = OpenLoopFixture

    private func say(_ loops: [OpenLoop], channel: OpenLoopChannel = .scheduled, fieldAssist: Bool = false,
                     unavailable: [OpenLoopSource] = []) -> OpenLoopPhrase? {
        OpenLoopPhraser.phrase(OpenLoopCollection(loops: loops, unavailable: unavailable),
                               channel: channel, fieldAssist: fieldAssist)
    }

    // MARK: Empty

    func testTheEmptyScheduledCheckInHasNothingToSay() {
        XCTAssertNil(say([]))
        XCTAssertNil(say([], unavailable: [.reminder]), "silent on schedule even when a source was unreadable")
    }

    func testAskedWithNothingWaitingSaysSo() {
        XCTAssertEqual(say([], channel: .asked)?.text, "Nothing is waiting on you.")
        XCTAssertEqual(say([], channel: .asked, unavailable: [.reminder])?.text,
                       "I couldn't check everything, and nothing I could check is waiting on you.",
                       "never a plain 'nothing' when a source could not be read")
    }

    // MARK: The list

    func testThePlansEverydayExample() {
        let loops = [
            F.approval(1, "Your OK to send the message to the plumber", since: F.at(9)),
            F.reminder("r1", "renew the registration", due: F.at(9)),
            F.step(1, "Book the skip", goal: "clear the garage", due: F.at(12)),
        ]
        XCTAssertEqual(say(loops)?.text,
                       "Three things are still waiting on you: your OK to send the message to the plumber, "
                       + "the 'renew the registration' reminder, and the next step of 'clear the garage'. "
                       + "Want to deal with the first one now?")
    }

    func testOneThing() {
        let phrase = say([F.reminder("r1", "Put the bins out", due: F.at(20))])
        XCTAssertEqual(phrase?.text, "One thing is still waiting on you: the 'Put the bins out' reminder.")
        XCTAssertEqual(phrase?.spokenCount, 1)
        XCTAssertEqual(phrase?.offersFirst, false)
    }

    func testFourAreSpokenAndTheRestAreOnYourPhone() {
        let loops = (1...6).map { F.reminder("r\($0)", "Task \($0)", due: nil) }
        let phrase = say(loops)
        XCTAssertEqual(phrase?.text,
                       "Six things are still waiting on you: the 'Task 1' reminder, the 'Task 2' reminder, "
                       + "the 'Task 3' reminder, and the 'Task 4' reminder. The rest are on your phone.")
        XCTAssertEqual(phrase?.spokenCount, 4)
    }

    func testExactlyFourHasNoRest() {
        let loops = (1...4).map { F.reminder("r\($0)", "Task \($0)", due: nil) }
        XCTAssertFalse(say(loops)?.text.contains("on your phone") ?? true)
    }

    func testALongListFitsTheCeilingAndKeepsTheCountExact() {
        let long = "Ring the council about the overgrown hedge on the corner by the bus stop again, and ask "
            + "them whether the footpath repairs they promised in spring are still going ahead this year"
        let loops = (1...9).map { F.reminder("r\($0)", "\(long) \($0)", due: nil) }
        let phrase = say(loops)!
        XCTAssertTrue(phrase.text.hasPrefix("Nine things are still waiting on you:"), phrase.text)
        XCTAssertLessThan(phrase.spokenCount, 4)
        XCTAssertGreaterThanOrEqual(phrase.spokenCount, 1)
        XCTAssertTrue(phrase.text.hasSuffix("The rest are on your phone."), phrase.text)
        XCTAssertLessThanOrEqual(MyDaySpeechPolicy.estimatedDuration(for: phrase.text), MyDaySpeechPolicy.maximumDuration)
    }

    // MARK: The question

    func testOnlyAnApprovalFirstAsksTheQuestion() {
        let approval = F.approval(1, "Your OK to use the send message tool", since: F.at(9))
        let reminder = F.reminder("r1", "Put the bins out", due: F.at(20))
        let asking = say([approval, reminder])!
        XCTAssertTrue(asking.offersFirst)
        XCTAssertTrue(asking.text.hasSuffix(" Want to deal with the first one now?"), asking.text)
        XCTAssertEqual(asking.text.components(separatedBy: "?").count - 1, 1, "a single question")

        let notAsking = say([reminder, approval])!
        XCTAssertFalse(notAsking.offersFirst)
        XCTAssertFalse(notAsking.text.contains("?"))
    }

    // MARK: Field Assist (§10)

    func testThePlansEndOfShiftExample() {
        let loops = [
            F.report("q1", job: .customer("Smith")),
            F.job(.partsRequest, "s2", title: "filter", job: .customer("Jones")),
        ]
        XCTAssertEqual(say(loops, fieldAssist: true)?.text,
                       "Two things before you finish: the report for the Smith job isn't sent "
                       + "and the filter for Jones is still not ordered.")
        XCTAssertEqual(say(loops, fieldAssist: false)?.text,
                       "Two things are still waiting on you: the report for the Smith job isn't sent "
                       + "and the filter for Jones is still not ordered.")
        XCTAssertEqual(say([loops[0]], fieldAssist: true)?.text,
                       "One thing before you finish: the report for the Smith job isn't sent.")
    }

    func testEachJobLooseEndNamesItsJobTheWayTheRecordDoes() {
        XCTAssertEqual(OpenLoopPhraser.clause(F.report("q1", job: .reference("1005"), failed: true)),
                       "the report for job 1005 didn't send")
        XCTAssertEqual(OpenLoopPhraser.clause(F.report("q1", job: nil)),
                       "the report for one of today's jobs isn't sent")
        XCTAssertEqual(OpenLoopPhraser.clause(F.job(.jobCloseHeld, "s1", title: "The customer's sign-off",
                                                    job: .customer("Smith"))),
                       "the Smith job still needs the customer's sign-off")
        XCTAssertEqual(OpenLoopPhraser.clause(F.job(.jobCloseHeld, "s1", title: "", job: .reference("1005"))),
                       "job 1005 isn't closed")
        XCTAssertEqual(OpenLoopPhraser.clause(F.job(.partsRequest, "s1", title: "Capacitor", job: .reference("1005"))),
                       "the capacitor for job 1005 is still not ordered")
        XCTAssertEqual(OpenLoopPhraser.clause(F.job(.deferredTask, "s1", title: "Clean the coil",
                                                    job: .customer("Smith"))),
                       "you put off clean the coil on the Smith job")
        XCTAssertEqual(OpenLoopPhraser.clause(F.job(.expertOrEscalation, "s1", title: "Hand-off",
                                                    job: .customer("Smith"), subject: "Sam")),
                       "no answer yet from Sam on the Smith job")
        XCTAssertEqual(OpenLoopPhraser.clause(F.job(.expertOrEscalation, "s1", title: "Escalation",
                                                    job: .customer("Smith"))),
                       "the escalation on the Smith job has no answer yet")
    }

    func testTheOtherSourcesClauses() {
        let since = F.at(9)
        XCTAssertEqual(OpenLoopPhraser.clause(OpenLoop(id: "d", source: .digest, title: "Parcel delivered",
                                                       since: since, action: .dismiss)),
                       "the 'Parcel delivered' update")
        XCTAssertEqual(OpenLoopPhraser.clause(OpenLoop(id: "a", source: .agentResult, title: "Upcoming Events",
                                                       since: since, action: .open(.agentResult(id: "a")))),
                       "the result of 'Upcoming Events'")
        XCTAssertEqual(OpenLoopPhraser.clause(OpenLoop(id: "k", source: .waitingOnOthers, title: "Quote",
                                                       subject: "the roofer", since: since, action: .dismiss)),
                       "no reply yet from the roofer")
        XCTAssertEqual(OpenLoopPhraser.clause(OpenLoop(id: "c", source: .draft, title: "Running late",
                                                       subject: "Ana", since: since, action: .open(.card(id: "c")))),
                       "the message to Ana you haven't sent")
        XCTAssertEqual(OpenLoopPhraser.clause(F.step(1, "Book the skip", goal: "Clear the garage", due: nil)),
                       "the next step of 'Clear the garage'")
    }

    func testTheCheckInNeverSaysAPlanLetter() {
        let loops = OpenLoopSource.allCases.enumerated().map { index, source in
            OpenLoop(id: "\(source.rawValue):\(index)", source: source, title: "Something", subject: "Ana",
                     job: .customer("Smith"), since: F.at(9), action: .dismiss)
        }
        for loop in loops {
            let clause = OpenLoopPhraser.clause(loop)
            XCTAssertNil(clause.range(of: #"\bPlan [A-Z]{1,2}\b"#, options: .regularExpression), clause)
        }
    }
}
