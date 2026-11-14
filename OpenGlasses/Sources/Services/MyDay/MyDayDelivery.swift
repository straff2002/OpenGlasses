import Foundation

enum MyDayDeliverySlot: String, Equatable, Sendable {
    case morning
    case evening
    /// The Evening Check-in (Plan LE §4): what from today is still waiting on the wearer.
    case checkIn

    var displayName: String {
        switch self {
        case .morning: "Morning"
        case .evening: "Evening"
        case .checkIn: "Check-in"
        }
    }
}

/// The check-in's default time (Plan LE decision 9): 21:00, or 17:00 — the end of a working day —
/// with Field Assist on. Only a default: a time the wearer chose is kept whatever Field Assist does.
enum MyDayCheckInDefaults {
    static let everydayMinutes = 21 * 60
    static let fieldAssistMinutes = 17 * 60

    static func minutes(fieldAssistOn: Bool) -> Int {
        fieldAssistOn ? fieldAssistMinutes : everydayMinutes
    }

    /// What the settings row shows: the stored time, else the default (Plan LE P1).
    static func shown(stored: Int?, fieldAssistOn: Bool) -> Int {
        stored ?? minutes(fieldAssistOn: fieldAssistOn)
    }
}

/// The motion reading a delivery decision may use: the latest sample, only while it is recent
/// (Plan LE decision 10). A reading from an hour ago says nothing about now.
enum MyDayDeliveryMotion {
    static let freshness: TimeInterval = 10 * 60

    static func kind(of sample: MotionSample?, now: Date) -> MotionSample.Kind? {
        guard let sample, now.timeIntervalSince(sample.at) <= freshness else { return nil }
        return sample.kind
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
    /// The Evening Check-in (Plan LE §4). Off by default (decision 2).
    var checkInEnabled = false
    /// The time the wearer chose, or nil to follow the default (`MyDayCheckInDefaults`).
    var checkInMinutes: Int? = nil
    /// Field Assist is on (entitled and switched on): the default check-in time is 17:00.
    var fieldAssistOn = false

    /// The check-in's time: the wearer's own, else the default for the kind of day it is.
    var resolvedCheckInMinutes: Int {
        checkInMinutes ?? MyDayCheckInDefaults.minutes(fieldAssistOn: fieldAssistOn)
    }

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
            quietEndMinutes: Config.myDayQuietEndMinutes,
            checkInEnabled: Config.myDayCheckInEnabled,
            checkInMinutes: Config.myDayCheckInMinutes,
            fieldAssistOn: Config.fieldAssistActive
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
    /// The phone's motion reading at delivery time (`MotionActivityProvider`), when there is one.
    /// `automotive` holds the check-in's speech (Plan LE decision 10).
    var motion: MotionSample.Kind? = nil
}

enum MyDayDeliveryDeferral: Equatable {
    case protectedData
    case quietHours
    case sourceAccess
}

enum MyDayDeliveryDecision: Equatable {
    case notDue
    case deferred(MyDayDeliveryDeferral)
    /// `speak == false` shows it on the phone without saying it. `alsoDelivers` is a second slot
    /// delivered in the same breath and consumed with it: the evening briefing after the check-in,
    /// when the two fall within `MyDayDeliveryPolicy.mergeMinutes` (Plan LE §4).
    case deliver(slot: MyDayDeliverySlot, dayKey: String, speak: Bool, alsoDelivers: MyDayDeliverySlot? = nil)
}

enum MyDayDeliveryPolicy {
    /// A wearer who was briefly away or whose app resumed late should still get today's delivery,
    /// but a stale briefing hours later is worse than no automatic briefing.
    static let deliveryWindowMinutes = 120
    /// The evening briefing and the check-in this close together are delivered as one: the
    /// check-in's list first, then tomorrow (Plan LE §4, decision 1). At 30 they merge; at 31 not.
    static let mergeMinutes = 30

    static func decide(
        now: Date,
        calendar: Calendar,
        settings: MyDayDeliverySettings,
        context: MyDayDeliveryContext,
        lastMorningDayKey: String,
        lastEveningDayKey: String,
        lastCheckInDayKey: String = ""
    ) -> MyDayDeliveryDecision {
        guard settings.myDayEnabled else { return .notDue }
        let dayKey = self.dayKey(for: now, calendar: calendar)
        let minute = minuteOfDay(for: now, calendar: calendar)
        let eveningMinutes = bounded(settings.eveningMinutes)
        let checkInMinutes = bounded(settings.resolvedCheckInMinutes)

        let candidates: [(MyDayDeliverySlot, Bool, Int, String)] = [
            (.morning, settings.morningEnabled, bounded(settings.morningMinutes), lastMorningDayKey),
            (.evening, settings.eveningEnabled, eveningMinutes, lastEveningDayKey),
            (.checkIn, settings.checkInEnabled, checkInMinutes, lastCheckInDayKey),
        ]

        guard let due = candidates.first(where: { _, enabled, scheduled, deliveredDay in
            enabled
                && deliveredDay != dayKey
                && minute >= scheduled
                && minute - scheduled <= deliveryWindowMinutes
        })?.0 else {
            return .notDue
        }

        // The evening briefing and the check-in, both still owed today and close together, go as
        // one — whichever came due first — with the check-in leading. Each keeps its own day key,
        // so neither is ever delivered twice; one already past its own window is not carried along.
        let slot: MyDayDeliverySlot
        let alsoDelivers: MyDayDeliverySlot?
        if due != .morning,
           settings.eveningEnabled, lastEveningDayKey != dayKey,
           settings.checkInEnabled, lastCheckInDayKey != dayKey,
           abs(eveningMinutes - checkInMinutes) <= mergeMinutes,
           minute - eveningMinutes <= deliveryWindowMinutes,
           minute - checkInMinutes <= deliveryWindowMinutes {
            slot = .checkIn
            alsoDelivers = .evening
        } else {
            slot = due
            alsoDelivers = nil
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
        // Plan LE decision 10: the check-in is not spoken while driving. It shows on the phone
        // and is said when asked.
        let driving = slot == .checkIn && context.motion == .automotive
        let speak = settings.scheduledSpeechEnabled
            && wearerPresent
            && context.power != .reserve
            && context.isOnline
            && !context.isBusy
            && !driving
        return .deliver(slot: slot, dayKey: dayKey, speak: speak, alsoDelivers: alsoDelivers)
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

    /// Whether `date` falls in the wearer's quiet hours, when they are on. Shared with the cards'
    /// notifications (Plan KT §5.3), which quiet hours hold back the same way.
    static func isQuiet(at date: Date, calendar: Calendar, settings: MyDayDeliverySettings) -> Bool {
        guard settings.quietHoursEnabled else { return false }
        return isQuiet(minute: minuteOfDay(for: date, calendar: calendar),
                       start: bounded(settings.quietStartMinutes), end: bounded(settings.quietEndMinutes))
    }

    static func isQuiet(minute: Int, start: Int, end: Int) -> Bool {
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
    /// The phone's latest motion reading (`MotionActivityProvider`), when it is recent. `automotive`
    /// holds the check-in's speech (Plan LE decision 10).
    var motion: () -> MotionSample.Kind? = { nil }
    /// The Evening Check-in's content (Plan LE P1). Nil — no check-in to deliver — until wired.
    var checkIn: EveningCheckInService?
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
                isProtectedDataAvailable: protectedDataAvailable(),
                motion: motion()
            ),
            lastMorningDayKey: Config.myDayLastMorningDeliveryDay,
            lastEveningDayKey: Config.myDayLastEveningDeliveryDay,
            lastCheckInDayKey: Config.myDayLastCheckInDeliveryDay
        )
        guard case .deliver(let slot, let dayKey, let speak, let alsoDelivers) = decision else { return }

        guard slot == .checkIn else {
            let text = await myDayService.spokenBriefing(now: now, channel: .scheduled)
            consume(slot, dayKey: dayKey)
            onDelivery?(slot, text, speak, "my-day-\(slot.rawValue)-\(dayKey)")
            return
        }

        // Plan LE P1: the check-in's list first, then — merged inside 30 minutes — the evening's
        // look at tomorrow. Each slot's day key is consumed whether or not it had anything to say:
        // an empty check-in is silent (decision 4), and silent means not later in the window either.
        var parts: [String] = []
        if let text = await checkIn?.scheduledText(now: now) { parts.append(text) }
        consume(.checkIn, dayKey: dayKey)
        if alsoDelivers == .evening {
            parts.append(await myDayService.spokenBriefing(now: now, channel: .scheduled))
            consume(.evening, dayKey: dayKey)
        }
        guard !parts.isEmpty else { return }
        onDelivery?(.checkIn, parts.joined(separator: " "), speak, "my-day-\(slot.rawValue)-\(dayKey)")
    }

    private func consume(_ slot: MyDayDeliverySlot, dayKey: String) {
        switch slot {
        case .morning: Config.myDayLastMorningDeliveryDay = dayKey
        case .evening: Config.myDayLastEveningDeliveryDay = dayKey
        case .checkIn: Config.myDayLastCheckInDeliveryDay = dayKey
        }
    }

    deinit {
        timer?.invalidate()
    }
}
