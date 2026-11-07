import Combine
import Foundation
import UIKit

extension Config {
    /// "Today on Your Watch" (Plan KS): today's calendar and weather on the wrist. On by default —
    /// the data travels only to the wearer's own watch, over WatchConnectivity.
    static var watchTodayEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "watchTodayEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "watchTodayEnabled") }
    }
}

/// Plan KS — keeps the watch's `today` value current.
///
/// It holds the last thing My Day gathered and builds the value at push time, so a change of
/// Medical Compliance mode or of the setting applies to the very next push, whoever sends it. The
/// surface publisher folds `contextValue()` into every application-context push (see
/// `WatchApplicationContext`); this type only asks for a push when the value changes.
///
/// It looks again — a My Day refresh with no briefing — when the app comes to the foreground (no
/// more often than `WatchTodaySchedule.foregroundInterval`) and just after local midnight, and
/// only when that cannot put a permission sheet up.
@MainActor
final class WatchTodayPublisher {

    struct Environment {
        var enabled: () -> Bool = { Config.watchTodayEnabled }
        var medical: () -> MedicalEgressGuard.Mode = { MedicalEgressGuard.currentMode() }
        var now: () -> Date = Date.init
        var calendar: () -> Calendar = { .autoupdatingCurrent }
        var temperatureUnit: () -> WatchTodayTemperatureUnit = {
            WeatherUnits.forLocale(.autoupdatingCurrent).temperature == .fahrenheit ? .fahrenheit : .celsius
        }
        var attribution: @MainActor () -> WatchTodayAttribution = {
            let info = WeatherAttributionStore.shared.info
            return WatchTodayAttribution(serviceName: info.serviceName,
                                         legalPageURL: info.legalPageURL.absoluteString)
        }
        /// A watch with the app is paired. No watch, no looking.
        var watchAppInstalled: () -> Bool = { true }
        /// Every My Day source the refresh reads has had its permission answered, so an
        /// unattended refresh cannot ask.
        var sourceAccessReady: () -> Bool = { true }
    }

    private let environment: Environment
    private let refresh: () async -> Void
    private let onChange: () -> Void
    private(set) var held: MyDayGathered?
    private var lastValue: Data?
    private var subscriptions: Set<AnyCancellable> = []
    private var midnightTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(environment: Environment = Environment(), refresh: @escaping () async -> Void,
         onChange: @escaping () -> Void) {
        self.environment = environment
        self.refresh = refresh
        self.onChange = onChange
    }

    /// Take every gathering `myDay` makes from now on, look on foreground, and look at midnight.
    func start(observing myDay: MyDayService) {
        subscriptions.removeAll()
        myDay.$gathered
            .compactMap { $0 }
            .sink { [weak self] gathered in self?.accept(gathered) }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.refreshIfDue() }
            .store(in: &subscriptions)
        // Medical Compliance, its Local Only, an organisation profile pinning either, and the
        // setting itself all live in defaults. A change rebuilds the value, and pushes only if it
        // shows — so titles leave the wrist the moment Medical Compliance comes on.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.valueMayHaveChanged() }
            .store(in: &subscriptions)
        scheduleMidnight()
        refreshIfDue()
    }

    /// Hold a new gathering (unless it is a locked look that would hide a good one) and ask for a
    /// push when the value changed.
    func accept(_ gathered: MyDayGathered) {
        guard WatchTodayHoldPolicy.shouldReplace(held: held, with: gathered,
                                                 calendar: environment.calendar()) else { return }
        held = gathered
        valueMayHaveChanged()
    }

    /// The setting or a mode changed: rebuild, and push if it shows.
    func valueMayHaveChanged() {
        let value = contextValue()
        guard value != lastValue else { return }
        lastValue = value
        onChange()
    }

    /// The `today` value as it stands, or nil for "absent" (nothing gathered yet).
    func contextValue() -> Data? {
        let now = environment.now()
        let calendar = environment.calendar()
        let payload: WatchTodayPayload
        if !environment.enabled() {
            payload = .settingOff(at: now, calendar: calendar)
        } else if let held {
            payload = WatchTodayBuilder.payload(
                from: held,
                .init(now: now, calendar: calendar, medical: environment.medical(),
                      temperatureUnit: environment.temperatureUnit(),
                      attribution: environment.attribution()))
        } else {
            return nil
        }
        switch WatchTodayCodec.encode(payload) {
        case .success(let encoded):
            return encoded.data
        case .failure(.overBudget(let bytes, _)):
            PrivacyLog.device(.watch, .todayRefused, reason: PrivacyToken("overBudget"), count: bytes)
            return nil
        case .failure(.encodingFailed):
            PrivacyLog.device(.watch, .todayRefused, reason: PrivacyToken("encodingFailed"))
            return nil
        }
    }

    /// Look again if it is due and cannot ask for a permission.
    func refreshIfDue() {
        guard environment.enabled(), environment.watchAppInstalled(), environment.sourceAccessReady(),
              refreshTask == nil,
              WatchTodaySchedule.isRefreshDue(lastGeneratedAt: held?.generatedAt, now: environment.now(),
                                              calendar: environment.calendar()) else { return }
        refreshTask = Task { @MainActor [weak self] in
            await self?.refresh()
            self?.refreshTask = nil
        }
    }

    private func scheduleMidnight() {
        midnightTask?.cancel()
        let now = environment.now()
        let fire = WatchTodaySchedule.nextMidnight(after: now, calendar: environment.calendar())
        let delay = max(1, fire.timeIntervalSince(now))
        midnightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Yesterday's value now reads as stale on the wrist; a fresh look replaces it.
            self.refreshIfDue()
            self.scheduleMidnight()
        }
    }
}
