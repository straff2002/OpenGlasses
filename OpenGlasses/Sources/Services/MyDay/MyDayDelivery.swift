import Foundation

enum MyDayDeliverySlot: String, Equatable, Sendable {
    case morning
    case evening

    var displayName: String {
        switch self {
        case .morning: "Morning"
        case .evening: "Evening"
        }
    }
}

struct MyDayDeliverySettings: Equatable, Sendable {
    let myDayEnabled: Bool
    let morningEnabled: Bool
    let morningMinutes: Int
    let eveningEnabled: Bool
    let eveningMinutes: Int
    let scheduledSpeechEnabled: Bool
    let quietHoursEnabled: Bool
    let quietStartMinutes: Int
    let quietEndMinutes: Int

    static var current: Self {
        .init(
            myDayEnabled: Config.myDayEnabled,
            morningEnabled: Config.myDayMorningDeliveryEnabled,
            morningMinutes: Config.myDayMorningDeliveryMinutes,
            eveningEnabled: Config.myDayEveningDeliveryEnabled,
            eveningMinutes: Config.myDayEveningDeliveryMinutes,
            scheduledSpeechEnabled: Config.myDayScheduledSpeechEnabled,
            quietHoursEnabled: Config.myDayQuietHoursEnabled,
            quietStartMinutes: Config.myDayQuietStartMinutes,
            quietEndMinutes: Config.myDayQuietEndMinutes
        )
    }
}

struct MyDayDeliveryContext: Equatable {
    let presence: EngagementMode
    let power: PowerPosture
    let isOnline: Bool
    let isBusy: Bool
    let sourceAccessReady: Bool
    let isProtectedDataAvailable: Bool
}

enum MyDayDeliveryDeferral: Equatable {
    case protectedData
    case quietHours
    case sourceAccess
}

enum MyDayDeliveryDecision: Equatable {
    case notDue
    case deferred(MyDayDeliveryDeferral)
    case deliver(slot: MyDayDeliverySlot, dayKey: String, speak: Bool)
}

enum MyDayDeliveryPolicy {
    /// A wearer who was briefly away or whose app resumed late should still get today's delivery,
    /// but a stale briefing hours later is worse than no automatic briefing.
    static let deliveryWindowMinutes = 120

    static func decide(
        now: Date,
        calendar: Calendar,
        settings: MyDayDeliverySettings,
        context: MyDayDeliveryContext,
        lastMorningDayKey: String,
        lastEveningDayKey: String
    ) -> MyDayDeliveryDecision {
        guard settings.myDayEnabled else { return .notDue }
        let dayKey = self.dayKey(for: now, calendar: calendar)
        let minute = minuteOfDay(for: now, calendar: calendar)

        let candidates: [(MyDayDeliverySlot, Bool, Int, String)] = [
            (.morning, settings.morningEnabled, bounded(settings.morningMinutes), lastMorningDayKey),
            (.evening, settings.eveningEnabled, bounded(settings.eveningMinutes), lastEveningDayKey),
        ]

        guard let slot = candidates.first(where: { _, enabled, scheduled, deliveredDay in
            enabled
                && deliveredDay != dayKey
                && minute >= scheduled
                && minute - scheduled <= deliveryWindowMinutes
        })?.0 else {
            return .notDue
        }

        guard context.isProtectedDataAvailable else { return .deferred(.protectedData) }
        if settings.quietHoursEnabled,
           isQuiet(
               minute: minute,
               start: bounded(settings.quietStartMinutes),
               end: bounded(settings.quietEndMinutes)
           ) {
            return .deferred(.quietHours)
        }
        guard context.sourceAccessReady else { return .deferred(.sourceAccess) }

        let wearerPresent = context.presence == .active || context.presence == .present
        let speak = settings.scheduledSpeechEnabled
            && wearerPresent
            && context.power != .reserve
            && context.isOnline
            && !context.isBusy
        return .deliver(slot: slot, dayKey: dayKey, speak: speak)
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func minuteOfDay(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func isQuiet(minute: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }

    private static func bounded(_ minutes: Int) -> Int {
        min(23 * 60 + 59, max(0, minutes))
    }
}

@MainActor
final class MyDayScheduledDeliveryService: ObservableObject {
    var settings: () -> MyDayDeliverySettings = { .current }
    var presence: () -> EngagementMode = { .away }
    var power: () -> PowerPosture = { .reserve }
    var isOnline: () -> Bool = { false }
    var isBusy: () -> Bool = { true }
    var sourceAccessReady: () -> Bool = { false }
    var protectedDataAvailable: () -> Bool = { false }
    var onDelivery: ((MyDayDeliverySlot, String, Bool, String) -> Void)?

    private let myDayService: MyDayService
    private let calendarProvider: () -> Calendar
    private var timer: Timer?
    private var checkInFlight = false

    init(
        myDayService: MyDayService,
        calendarProvider: @escaping () -> Calendar = { .autoupdatingCurrent }
    ) {
        self.myDayService = myDayService
        self.calendarProvider = calendarProvider
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
        Task { @MainActor [weak self] in await self?.evaluate() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func evaluate(now: Date = Date()) async {
        guard !checkInFlight else { return }
        checkInFlight = true
        defer { checkInFlight = false }

        let decision = MyDayDeliveryPolicy.decide(
            now: now,
            calendar: calendarProvider(),
            settings: settings(),
            context: .init(
                presence: presence(),
                power: power(),
                isOnline: isOnline(),
                isBusy: isBusy(),
                sourceAccessReady: sourceAccessReady(),
                isProtectedDataAvailable: protectedDataAvailable()
            ),
            lastMorningDayKey: Config.myDayLastMorningDeliveryDay,
            lastEveningDayKey: Config.myDayLastEveningDeliveryDay
        )
        guard case .deliver(let slot, let dayKey, let speak) = decision else { return }

        let text = await myDayService.spokenBriefing(now: now, channel: .scheduled)
        switch slot {
        case .morning: Config.myDayLastMorningDeliveryDay = dayKey
        case .evening: Config.myDayLastEveningDeliveryDay = dayKey
        }
        onDelivery?(slot, text, speak, "my-day-\(slot.rawValue)-\(dayKey)")
    }

    deinit {
        timer?.invalidate()
    }
}
