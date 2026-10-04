import Foundation

/// A press of the "Ask Avenkin" control, handed to the app through the App Group.
///
/// The control's intent may run in the widget extension or in the app, and neither can assume the
/// app's `AppState` exists yet (a cold launch builds it after the intent has run). So the press is
/// written down as a timestamp, a Darwin notification nudges a live app, and the app takes the
/// request when it can act on it: on the notification, on launch, and on becoming active.
///
/// A request older than `maximumAge` is dropped, never acted on, so a press the app never saw
/// cannot start listening minutes later. Taking a request always clears it, so one press starts
/// one ask however many of those paths run.
///
/// Compiled into the app and the widget extension (`project.base.yml`).
struct PendingAskRequest {
    /// **Storage key.** Shared between the app and the extension; renaming it strands a press.
    static let key = "pendingAskRequestedAt"
    /// Darwin notification posted when a request is recorded.
    static let notificationName = "com.openglasses.app.ask-requested"
    /// How long a press stays actionable. Long enough for a cold launch, short enough that a
    /// stale press never fires on some later, unrelated launch.
    static let maximumAge: TimeInterval = 10
    /// Clock-skew allowance for a stamp a hair in the future (the two processes read one clock,
    /// but the wall clock can step).
    static let futureTolerance: TimeInterval = 1

    let defaults: UserDefaults
    var now: () -> Date = Date.init

    /// The request store every target shares.
    static var shared: PendingAskRequest { PendingAskRequest(defaults: SharedAppState.defaults) }

    /// Records a press. A second press before the first is taken just refreshes the stamp.
    func record() {
        defaults.set(now().timeIntervalSince1970, forKey: Self.key)
    }

    /// Takes the pending request: `true` if there was one fresh enough to act on. Always clears it,
    /// fresh or stale, so a request is acted on at most once.
    func consume() -> Bool {
        guard let stamp = defaults.object(forKey: Self.key) as? Double else { return false }
        defaults.removeObject(forKey: Self.key)
        return Self.isFresh(age: now().timeIntervalSince1970 - stamp)
    }

    static func isFresh(age: TimeInterval) -> Bool {
        age >= -futureTolerance && age <= maximumAge
    }

    /// Records a press and nudges a running app to take it.
    static func submit() {
        shared.record()
        SharedAppState.postDarwinNotification(notificationName)
    }
}
