import XCTest
@testable import OpenGlasses

final class MyDayTravelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_066_000)

    private func event(
        _ id: String,
        startsIn: TimeInterval,
        location: String?,
        allDay: Bool = false
    ) -> MyDayCalendarEvent {
        .init(
            id: id,
            title: "Event \(id)",
            startDate: now.addingTimeInterval(startsIn),
            endDate: now.addingTimeInterval(startsIn + 3600),
            isAllDay: allDay,
            location: location
        )
    }

    private var settings: MyDayTravelSettings {
        .init(mode: .driving, bufferMinutes: 10, origin: .currentLocation,
              homeAddress: "", workAddress: "")
    }

    func testCandidateUsesFirstTimedPhysicalLocation() {
        let selected = MyDayTravelPlanner.nextLocatableEvent(in: [
            event("virtual", startsIn: 600, location: "Zoom"),
            event("all-day", startsIn: 900, location: "Auckland", allDay: true),
            event("later", startsIn: 3600, location: "22 Queen Street"),
            event("first", startsIn: 1800, location: "Library")
        ], now: now)

        XCTAssertEqual(selected?.id, "first")
        XCTAssertNil(MyDayTravelPlanner.usableDestination("https://meet.example.com/abc"))
        XCTAssertNil(MyDayTravelPlanner.usableDestination("Phone call"))
        XCTAssertEqual(MyDayTravelPlanner.usableDestination("  Civic Theatre  "), "Civic Theatre")
    }

    func testLeaveAtSubtractsRouteAndBoundedBuffer() {
        let appointment = event("dentist", startsIn: 3600, location: "Dentist")
        let estimate = MyDayTravelPlanner.estimate(
            event: appointment,
            destination: "Dentist",
            travelDuration: 20 * 60,
            settings: settings
        )

        XCTAssertEqual(estimate?.leaveAt, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(estimate?.bufferDuration, 10 * 60)
        XCTAssertNil(MyDayTravelPlanner.estimate(
            event: appointment,
            destination: "Dentist",
            travelDuration: 0,
            settings: settings
        ))
    }

    func testCacheInvalidatesForAgeLocationRouteOrSettingsChange() {
        let appointment = event("dentist", startsIn: 3600, location: "Dentist")
        let origin = MyDayCoordinate(latitude: -36.8485, longitude: 174.7633)
        let metadata = MyDayTravelCacheMetadata(
            eventID: appointment.id,
            eventStart: appointment.startDate,
            destinationKey: "dentist",
            origin: origin,
            originMode: .currentLocation,
            transportMode: .driving,
            bufferMinutes: 10,
            calculatedAt: now
        )

        XCTAssertTrue(MyDayTravelCachePolicy.canReuse(
            metadata, event: appointment, destinationKey: "dentist", origin: origin,
            settings: settings, now: now.addingTimeInterval(299)
        ))
        XCTAssertFalse(MyDayTravelCachePolicy.canReuse(
            metadata, event: appointment, destinationKey: "dentist", origin: origin,
            settings: settings, now: now.addingTimeInterval(301)
        ))
        XCTAssertFalse(MyDayTravelCachePolicy.canReuse(
            metadata, event: appointment, destinationKey: "dentist",
            origin: .init(latitude: -36.8450, longitude: 174.7633),
            settings: settings, now: now.addingTimeInterval(60)
        ))
        let walking = MyDayTravelSettings(mode: .walking, bufferMinutes: 10,
                                          origin: .currentLocation,
                                          homeAddress: "", workAddress: "")
        XCTAssertFalse(MyDayTravelCachePolicy.canReuse(
            metadata, event: appointment, destinationKey: "dentist", origin: origin,
            settings: walking, now: now.addingTimeInterval(60)
        ))
    }

    func testAlertFiresOnceLeaveTimeArrivesButYieldsToImminentEventAlert() {
        let appointment = event("dentist", startsIn: 3600, location: "Dentist")
        let estimate = MyDayTravelPlanner.estimate(
            event: appointment,
            destination: "Dentist",
            travelDuration: 20 * 60,
            settings: settings
        )!

        XCTAssertNil(MyDayLeaveByAlertPolicy.alert(
            for: estimate,
            now: estimate.leaveAt.addingTimeInterval(-1)
        ))
        let alert = MyDayLeaveByAlertPolicy.alert(for: estimate, now: estimate.leaveAt)
        XCTAssertEqual(alert?.id, "leave-by:dentist:\(Int(appointment.startDate.timeIntervalSince1970))")
        XCTAssertTrue(alert?.message.contains("Leave now") == true)
        XCTAssertNil(MyDayLeaveByAlertPolicy.alert(
            for: estimate,
            now: appointment.startDate.addingTimeInterval(-60)
        ))
    }
}
