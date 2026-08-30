import XCTest
@testable import OpenGlasses

final class MyDayDigestPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func item(
        id: String,
        source: DigestSource,
        age: TimeInterval,
        priority: NotificationPriority = .medium,
        awaitingReply: Bool = false
    ) -> DigestItem {
        .init(
            id: id,
            source: source,
            title: "Update \(id)",
            createdAt: now.addingTimeInterval(-age),
            priority: priority,
            awaitingReply: awaitingReply
        )
    }

    func testSelectionKeepsOnlyTwoActionableFirstPartyUpdates() {
        let selected = MyDayDigestPolicy.select([
            item(id: "calendar", source: .calendar, age: 1, priority: .high),
            item(id: "leave-by", source: .proactive, age: 2, priority: .high),
            item(id: "agent-info", source: .agent, age: 3),
            item(id: "geofence", source: .geofence, age: 4),
            item(id: "agent-reply", source: .agent, age: 5, priority: .high, awaitingReply: true),
            item(id: "sync-failure", source: .sync, age: 6, priority: .high),
        ], now: now)

        XCTAssertEqual(selected.map(\.id), ["agent-reply", "sync-failure"])
        XCTAssertEqual(selected.count, MyDayDigestPolicy.limit)
        XCTAssertTrue(selected.allSatisfy { $0.urgency == .immediate })
    }

    func testSelectionBoundsAndCollapsesDigestText() {
        let selected = MyDayDigestPolicy.select([
            DigestItem(
                id: "long",
                source: .agent,
                title: String(repeating: "T", count: 100),
                rawBody: String(repeating: "detail  \n", count: 30),
                createdAt: now,
                priority: .high,
                awaitingReply: true
            ),
        ], now: now)

        XCTAssertEqual(selected.first?.title.count, 80)
        XCTAssertEqual(selected.first?.detail?.count, 160)
        XCTAssertFalse(selected.first?.detail?.contains("\n") == true)
    }

    @MainActor
    func testDismissRetiresDigestOwnerAndAcknowledgesAgentSource() {
        let oldEnabled = Config.digestEnabled
        Config.digestEnabled = true
        defer { Config.digestEnabled = oldEnabled }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-day-digest-\(UUID().uuidString).json")
        let service = NotificationDigestService(storageURL: url)
        var acknowledged = Set<String>()
        service.acknowledgeAgentItems = { acknowledged.formUnion($0) }
        service.ingest(
            id: "agent-item",
            source: .agent,
            title: "Need your answer",
            priority: .high,
            threadKey: "queue-item",
            awaitingReply: true
        )

        service.dismissItem(id: "agent-item")

        XCTAssertTrue(service.items.isEmpty)
        XCTAssertEqual(acknowledged, ["queue-item"])
        try? FileManager.default.removeItem(at: url)
    }
}

final class MyDayDeliveryPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ hour: Int, minute: Int = 0) -> Date {
        DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 30,
            hour: hour,
            minute: minute
        ).date!
    }

    private func settings(
        morning: Bool = true,
        evening: Bool = false,
        speech: Bool = true,
        quiet: Bool = false
    ) -> MyDayDeliverySettings {
        .init(
            myDayEnabled: true,
            morningEnabled: morning,
            morningMinutes: 8 * 60,
            eveningEnabled: evening,
            eveningMinutes: 19 * 60,
            scheduledSpeechEnabled: speech,
            quietHoursEnabled: quiet,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60
        )
    }

    private func context(
        presence: EngagementMode = .active,
        power: PowerPosture = .normal,
        online: Bool = true,
        busy: Bool = false,
        access: Bool = true
    ) -> MyDayDeliveryContext {
        .init(
            presence: presence,
            power: power,
            isOnline: online,
            isBusy: busy,
            sourceAccessReady: access,
            isProtectedDataAvailable: true
        )
    }

    func testMorningFiresOnceInsideBoundedWindow() {
        let due = MyDayDeliveryPolicy.decide(
            now: date(8, minute: 5),
            calendar: calendar,
            settings: settings(),
            context: context(),
            lastMorningDayKey: "",
            lastEveningDayKey: ""
        )
        XCTAssertEqual(due, .deliver(slot: .morning, dayKey: "2026-08-30", speak: true))

        let duplicate = MyDayDeliveryPolicy.decide(
            now: date(8, minute: 6),
            calendar: calendar,
            settings: settings(),
            context: context(),
            lastMorningDayKey: "2026-08-30",
            lastEveningDayKey: ""
        )
        XCTAssertEqual(duplicate, .notDue)

        let stale = MyDayDeliveryPolicy.decide(
            now: date(10, minute: 1),
            calendar: calendar,
            settings: settings(),
            context: context(),
            lastMorningDayKey: "",
            lastEveningDayKey: ""
        )
        XCTAssertEqual(stale, .notDue)
    }

    func testQuietHoursAndMissingSourceAccessDeferWithoutConsumingDelivery() {
        var quietSettings = settings(quiet: true)
        quietSettings = .init(
            myDayEnabled: quietSettings.myDayEnabled,
            morningEnabled: true,
            morningMinutes: 6 * 60,
            eveningEnabled: false,
            eveningMinutes: quietSettings.eveningMinutes,
            scheduledSpeechEnabled: true,
            quietHoursEnabled: true,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60
        )
        XCTAssertEqual(
            MyDayDeliveryPolicy.decide(
                now: date(6, minute: 30), calendar: calendar, settings: quietSettings,
                context: context(), lastMorningDayKey: "", lastEveningDayKey: ""
            ),
            .deferred(.quietHours)
        )
        XCTAssertEqual(
            MyDayDeliveryPolicy.decide(
                now: date(8), calendar: calendar, settings: settings(),
                context: context(access: false), lastMorningDayKey: "", lastEveningDayKey: ""
            ),
            .deferred(.sourceAccess)
        )
    }

    func testAwayOfflineBusyOrReserveStillDeliversPrivatelyWithoutSpeech() {
        let restrictedContexts = [
            context(presence: .away),
            context(online: false),
            context(busy: true),
            context(power: .reserve),
        ]

        for value in restrictedContexts {
            XCTAssertEqual(
                MyDayDeliveryPolicy.decide(
                    now: date(8), calendar: calendar, settings: settings(), context: value,
                    lastMorningDayKey: "", lastEveningDayKey: ""
                ),
                .deliver(slot: .morning, dayKey: "2026-08-30", speak: false)
            )
        }
    }

    func testEveningUsesItsOwnOccurrenceMarker() {
        XCTAssertEqual(
            MyDayDeliveryPolicy.decide(
                now: date(19, minute: 15), calendar: calendar,
                settings: settings(morning: false, evening: true), context: context(),
                lastMorningDayKey: "2026-08-30", lastEveningDayKey: ""
            ),
            .deliver(slot: .evening, dayKey: "2026-08-30", speak: true)
        )
    }
}
