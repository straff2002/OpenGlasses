import XCTest
@testable import OpenGlasses

/// Plan MY §6 — a tap on the weekly count reminder lands on the Stock screen with its count sheet
/// open. The reminder carries nothing but its identifier, so the route is read from that alone,
/// through the Jobs tab's own request (`JobListRequest`), the way every other notification lands.
final class StockCountReminderTapTests: XCTestCase {

    private let facts = JobListRouting.Facts(openSessionId: nil, openJobLabel: nil,
                                             finishedSessionIds: [], upcomingIds: [])

    // MARK: - The identifier

    func testOnlyTheRemindersIdentifierAsksForTheCount() {
        XCTAssertEqual(StockCountReminderPolicy.jobListRequest(forTapped: "stock.weekly-count"), .stockCount)
        XCTAssertEqual(StockCountReminderPolicy.jobListRequest(forTapped: StockCountReminderPolicy.identifier), .stockCount)
        for other in ["", JobSendNotifications.identifier, HeldRecommendationNotification.identifier,
                      "stock.weekly-count.old", "Stock.Weekly-Count"] {
            XCTAssertNil(StockCountReminderPolicy.jobListRequest(forTapped: other), other)
        }
    }

    func testTheReminderStillCarriesNothingButItsIdentifier() {
        let request = StockCountReminderPolicy.wanted(StockCountReminderSettings(enabled: true))
        XCTAssertEqual(request?.identifier, StockCountReminderPolicy.identifier,
                       "the tap is routed by the identifier, so nothing about the stock goes in userInfo")
    }

    // MARK: - Where it lands

    func testTheRequestOpensTheStockScreenAndAsksForTheCount() {
        let outcome = JobListRouting.resolve(.stockCount, facts)
        XCTAssertEqual(outcome.path, [.vanStock], "pushed over the list, so Back is the list")
        XCTAssertTrue(outcome.opensStockCount)
        XCTAssertNil(outcome.notice)
    }

    func testWhereTheOrganisationKeepsNoListTheTapSaysSo() {
        var forbidden = facts
        forbidden.showsStock = false
        let outcome = JobListRouting.resolve(.stockCount, forbidden)
        XCTAssertEqual(outcome.path, [])
        XCTAssertFalse(outcome.opensStockCount)
        XCTAssertEqual(outcome.notice, JobListRouting.stockUnavailable)
    }

    func testNoOtherRequestAsksForTheCount() {
        let open = JobListRouting.Facts(openSessionId: "s", openJobLabel: "Job 1", finishedSessionIds: ["d"], upcomingIds: ["u"])
        for request in [JobListRequest.list, .currentJob, .newJob, .session(id: "d"), .upcoming(id: "u")] {
            XCTAssertFalse(JobListRouting.resolve(request, open).opensStockCount, "\(request)")
        }
    }

    // MARK: - The sheet opens only where the screen offers it

    func testTheCountSheetOpensOnlyWhereTheScreenOffersACount() {
        XCTAssertTrue(StockCountOpening.opens(clinical: true, unreadable: false, empty: false, systemHoldsCount: false))
        XCTAssertFalse(StockCountOpening.opens(clinical: false, unreadable: false, empty: false, systemHoldsCount: false),
                       "only a clinic's list has a weekly count")
        XCTAssertFalse(StockCountOpening.opens(clinical: true, unreadable: true, empty: false, systemHoldsCount: false))
        XCTAssertFalse(StockCountOpening.opens(clinical: true, unreadable: false, empty: true, systemHoldsCount: false))
        XCTAssertFalse(StockCountOpening.opens(clinical: true, unreadable: false, empty: false, systemHoldsCount: true),
                       "a connected stock system holds the count")
    }

    // MARK: - The router

    @MainActor
    func testATapOnTheReminderGoesToTheJobsTabsRequest() {
        var requests: [JobListRequest] = []
        var tabs: [MainTab] = []
        let router = JobSendNotificationRouter(openTab: { tabs.append($0) }, routeAction: { _ in })
        router.openJobList = { requests.append($0) }
        router.handle(.tap, userInfo: [:], identifier: StockCountReminderPolicy.identifier)
        XCTAssertEqual(requests, [.stockCount])
        XCTAssertEqual(tabs, [])

        router.handle(.dismiss, userInfo: [:], identifier: StockCountReminderPolicy.identifier)
        XCTAssertEqual(requests, [.stockCount], "a dismissal opens nothing")
    }

    @MainActor
    func testEveryOtherTapIsRoutedAsBefore() {
        var requests: [JobListRequest] = []
        var tabs: [MainTab] = []
        let router = JobSendNotificationRouter(openTab: { tabs.append($0) }, routeAction: { _ in })
        router.openJobList = { requests.append($0) }
        router.handle(.tap, userInfo: [JobSendNotifications.openTabKey: MainTab.job.rawValue],
                      identifier: JobSendNotifications.identifier)
        router.handle(.tap, userInfo: [JobSendNotifications.openTabKey: MainTab.job.rawValue])
        XCTAssertEqual(tabs, [.job, .job])
        XCTAssertEqual(requests, [])
    }
}
