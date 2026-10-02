import XCTest
@testable import OpenGlasses

/// Plan HC — "Add new job" with and without a job open, and where a link into one job lands:
/// pushed over the list so Back returns to it, or the list with a short notice when the job has gone.
final class JobListRoutingTests: XCTestCase {

    private let facts = JobListRouting.Facts(openSessionId: "open", openJobLabel: "Job 1005",
                                             finishedSessionIds: ["done"], upcomingIds: ["ahead"])
    private let nothingOpen = JobListRouting.Facts(openSessionId: nil, openJobLabel: nil,
                                                   finishedSessionIds: ["done"], upcomingIds: ["ahead"])

    // MARK: - Add new job

    func testWithNothingOpenAddNewJobIsTheStartPage() {
        XCTAssertEqual(JobListAdd.decide(openJobLabel: nil), .startNew)
        XCTAssertEqual(JobListRouting.resolve(.newJob, nothingOpen), .init(path: [.currentJob]),
                       "the start page is the open job's page with no job — Start turns it into the job")
    }

    func testWithAJobOpenAddNewJobAsksAndNeverStartsOrEnds() {
        guard case .jobOpen(let prompt) = JobListAdd.decide(openJobLabel: "Job 1005") else {
            return XCTFail("a job is open: it must ask")
        }
        XCTAssertEqual(prompt.title, "Job 1005 is still open")
        XCTAssertEqual(prompt.resumeTitle, "Resume Job 1005")
        XCTAssertEqual(prompt.finishTitle, "Finish Job 1005…")
        XCTAssertEqual(OpenJobPrompt.scheduleTitle, "Schedule a job for later")
        XCTAssertTrue(prompt.message.contains("Nothing is closed for you"))

        let outcome = JobListRouting.resolve(.newJob, facts)
        XCTAssertEqual(outcome.prompt, prompt)
        XCTAssertEqual(outcome.path, [], "the question is asked on the list, nothing is pushed")
    }

    func testAnOpenJobWithNoNumberIsNamedInPlainWords() {
        let prompt = OpenJobPrompt(jobLabel: JobTabModel.noJobNumber)
        XCTAssertEqual(prompt.title, "A job is still open")
        XCTAssertEqual(prompt.resumeTitle, "Resume the open job")
        XCTAssertEqual(prompt.finishTitle, "Finish the open job…")
        // …and routing without a label still asks.
        XCTAssertEqual(JobListRouting.resolve(.newJob, .init(openSessionId: "x")).prompt, prompt)
    }

    func testEachAnswerAndWhatItDoes() {
        XCTAssertEqual(OpenJobPrompt.step(.resume), .init(path: [.currentJob]))
        XCTAssertEqual(OpenJobPrompt.step(.finishFirst), .init(path: [.currentJob], beginsClose: true),
                       "finishing goes through the job's own close — its confirmation, review and sign-off")
        XCTAssertEqual(OpenJobPrompt.step(.scheduleLater), .init(schedules: true),
                       "a job for later needs nothing closed")
        XCTAssertEqual(OpenJobPrompt.step(.cancel), .init())
        // No answer is a close without the job's own confirmation: only `finishFirst` begins one,
        // and it opens the page that asks.
        for answer in OpenJobPrompt.Answer.allCases where OpenJobPrompt.step(answer).beginsClose {
            XCTAssertEqual(OpenJobPrompt.step(answer).path, [.currentJob])
        }
    }

    // MARK: - Links into a job

    func testTheListItself() {
        XCTAssertEqual(JobListRouting.resolve(.list, facts), .init())
    }

    func testTheOpenJob() {
        XCTAssertEqual(JobListRouting.resolve(.currentJob, facts), .init(path: [.currentJob]))
        XCTAssertEqual(JobListRouting.resolve(.currentJob, nothingOpen),
                       .init(notice: JobListRouting.noOpenJob),
                       "Resume after the job closed: the list, saying why")
    }

    func testOneJobBySessionId() {
        XCTAssertEqual(JobListRouting.resolve(.session(id: "open"), facts), .init(path: [.currentJob]),
                       "the open one is the open job's page")
        XCTAssertEqual(JobListRouting.resolve(.session(id: "done"), facts),
                       .init(path: [.pastJob(sessionId: "done")]))
        XCTAssertEqual(JobListRouting.resolve(.session(id: "gone"), facts),
                       .init(notice: JobListRouting.jobGone))
        XCTAssertEqual(JobListRouting.jobGone, "That job is no longer on this phone.")
    }

    func testAJobAhead() {
        XCTAssertEqual(JobListRouting.resolve(.upcoming(id: "ahead"), facts),
                       .init(path: [.upcomingJob(id: "ahead")]))
        XCTAssertEqual(JobListRouting.resolve(.upcoming(id: "started"), facts),
                       .init(notice: JobListRouting.upcomingGone))
    }

    func testEveryLinkIsOnePageOverTheList() {
        // Back from wherever a link lands is the list: the path is never deeper than one page.
        let requests: [JobListRequest] = [.list, .currentJob, .newJob, .session(id: "open"),
                                          .session(id: "done"), .session(id: "gone"),
                                          .upcoming(id: "ahead"), .upcoming(id: "gone")]
        for request in requests {
            XCTAssertLessThanOrEqual(JobListRouting.resolve(request, facts).path.count, 1, "\(request)")
            XCTAssertLessThanOrEqual(JobListRouting.resolve(request, nothingOpen).path.count, 1, "\(request)")
        }
    }

    // MARK: - The job-day card's routes

    func testTheDayCardsRoutesBecomeRequests() {
        XCTAssertEqual(JobListRequest(JobDayDestination.openJob), .currentJob)
        XCTAssertEqual(JobListRequest(JobDayDestination.upcomingJob(id: "u")), .upcoming(id: "u"))
        XCTAssertEqual(JobListRequest(JobDayDestination.pastJob(sessionId: "s")), .session(id: "s"))
        XCTAssertNil(JobListRequest(JobDayDestination.send(queuedId: "q")),
                     "a report opens its composer where the wearer is, not in the tab")
    }

    @MainActor
    func testTheStagedSendNotificationLandsOnTheList() {
        // The notification still names the Jobs tab; the app turns that into the list, where the
        // send card is.
        let tab = JobSendNotificationRouter.requestedTab(from: [JobSendNotifications.openTabKey: MainTab.job.rawValue])
        XCTAssertEqual(tab, .job)
        XCTAssertEqual(JobListRouting.resolve(.list, facts).path, [])
    }
}
