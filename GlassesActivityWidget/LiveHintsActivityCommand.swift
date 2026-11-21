import Foundation

/// A press of one of the live-hints buttons on the Live Activity (Plan MO P2): repeat the last hint,
/// skip the one playing, or stop the session. Handed to the app the way the "Ask Avenkin" control
/// hands its press over (`PendingAskRequest`): written to the App Group with a timestamp, a Darwin
/// notification nudges the running app, and the app takes it once. A session runs with the app
/// alive in the background, so the notification is what normally delivers it.
///
/// A press older than `maximumAge` is dropped, never acted on, so a press the app never saw cannot
/// skip a hint minutes later. Taking a press always clears it.
///
/// Compiled into the app and the widget extension (`project.base.yml`, `project.phone-only.yml`).
enum LiveHintsActivityCommand: String, CaseIterable, Sendable {
    case repeatHint
    case skipHint
    case stop
}

struct PendingLiveHintsCommand {
    /// **Storage keys.** Shared between the app and the extension; renaming one strands a press.
    static let commandKey = "pendingLiveHintsCommand"
    static let stampKey = "pendingLiveHintsCommandAt"
    /// Darwin notification posted when a press is recorded.
    static let notificationName = "com.openglasses.app.live-hints-command"
    /// How long a press stays actionable.
    static let maximumAge: TimeInterval = 10
    /// Clock-skew allowance for a stamp a hair in the future.
    static let futureTolerance: TimeInterval = 1

    let defaults: UserDefaults
    var now: () -> Date = Date.init

    /// The store every target shares.
    static var shared: PendingLiveHintsCommand { PendingLiveHintsCommand(defaults: SharedAppState.defaults) }

    /// Records a press. A second press before the first is taken replaces it.
    func record(_ command: LiveHintsActivityCommand) {
        defaults.set(command.rawValue, forKey: Self.commandKey)
        defaults.set(now().timeIntervalSince1970, forKey: Self.stampKey)
    }

    /// Takes the pending press, if there is one fresh enough to act on. Always clears it.
    func consume() -> LiveHintsActivityCommand? {
        let raw = defaults.string(forKey: Self.commandKey)
        let stamp = defaults.object(forKey: Self.stampKey) as? Double
        defaults.removeObject(forKey: Self.commandKey)
        defaults.removeObject(forKey: Self.stampKey)
        guard let raw, let command = LiveHintsActivityCommand(rawValue: raw), let stamp,
              Self.isFresh(age: now().timeIntervalSince1970 - stamp) else { return nil }
        return command
    }

    static func isFresh(age: TimeInterval) -> Bool {
        age >= -futureTolerance && age <= maximumAge
    }

    /// Records a press and nudges the running app to take it.
    static func submit(_ command: LiveHintsActivityCommand) {
        shared.record(command)
        SharedAppState.postDarwinNotification(notificationName)
    }
}
