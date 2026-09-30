import Foundation

/// A temple tap as the wearer thinks of it — one, two or three taps (Plan GJ).
///
/// The glasses' firmware decides what a tap count *is*; the app only sees the standard media
/// command it sends to whichever app holds Now Playing. `TempleGestureDecoder` turns those commands
/// back into tap counts through a calibration table, so the mapping is data that a device run can
/// correct, not an assumption buried in a switch.
enum TempleGesture: String, CaseIterable, Codable, Identifiable {
    case one
    case two
    case three

    var id: String { rawValue }

    var tapCount: Int {
        switch self {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        }
    }

    /// Row title in Settings and the spoken name in test mode.
    var displayName: String {
        switch self {
        case .one: return String(localized: "One tap")
        case .two: return String(localized: "Two taps")
        case .three: return String(localized: "Three taps")
        }
    }
}

/// Which media command each tap count arrives as, for one glasses model.
///
/// **Device-unverified (Plan GJ P2, formerly CH P3).** The default table is the conventional AVRCP
/// reading of a headset's touch surface — single press = play/pause, double = next track, triple =
/// previous track — and has never been observed on the glasses. Some Bluetooth stacks deliver a
/// single press as a discrete `play` or `pause` rather than a toggle, so all three count as one tap.
/// When the device run reports, its findings go into `forModel(_:)` and the confirmation flags below.
struct TempleCalibration: Equatable {
    var table: [MediaRemoteCommand: TempleGesture]
    /// A device run has confirmed `table` on real glasses.
    var deviceConfirmed: Bool
    /// Whether taps are expected to reach the app while its own conversation holds the audio
    /// session (no silent player — the session's audio has to make the app the Now Playing owner).
    /// `true` until a device run says otherwise; if it does not work, flipping this off stops the
    /// app registering for taps mid-conversation, and Settings says hang-up/in-session mute are
    /// unavailable instead of letting them fail silently.
    var sessionControlAvailable: Bool
    /// A device run has confirmed `sessionControlAvailable`.
    var sessionControlConfirmed: Bool

    /// The assumed, unconfirmed default.
    static let assumedDefault = TempleCalibration(
        table: [
            .togglePlayPause: .one,
            .play: .one,
            .pause: .one,
            .nextTrack: .two,
            .previousTrack: .three,
        ],
        deviceConfirmed: false,
        sessionControlAvailable: true,
        sessionControlConfirmed: false)

    /// The table for a glasses model. Every model uses the assumed default until a device run
    /// records otherwise.
    static func forModel(_ model: String?) -> TempleCalibration {
        assumedDefault
    }

    /// The calibration in force now.
    static var current: TempleCalibration { forModel(nil) }

    func gesture(for command: MediaRemoteCommand) -> TempleGesture? {
        table[command]
    }
}

/// Turns raw media commands into tap gestures (Plan GJ P0). Pure — the clock is passed in.
///
/// Some stacks report one physical tap as two commands (`pause` then `play`), so a command arriving
/// within `coalescingWindow` of the previous one is folded into it. The window is measured from the
/// most recent command, so a burst of any length counts once.
struct TempleGestureDecoder: Equatable {
    static let defaultCoalescingWindow: TimeInterval = 0.15

    var calibration: TempleCalibration
    var coalescingWindow: TimeInterval
    private(set) var lastCommandAt: TimeInterval?

    init(calibration: TempleCalibration = .current,
         coalescingWindow: TimeInterval = TempleGestureDecoder.defaultCoalescingWindow) {
        self.calibration = calibration
        self.coalescingWindow = coalescingWindow
    }

    /// The gesture `command` stands for, or nil when it is part of the previous gesture or the
    /// calibration table does not know it.
    mutating func decode(_ command: MediaRemoteCommand, at now: TimeInterval) -> TempleGesture? {
        defer { lastCommandAt = now }
        if let last = lastCommandAt, now - last >= 0, now - last < coalescingWindow {
            return nil
        }
        return calibration.gesture(for: command)
    }

    mutating func reset() {
        lastCommandAt = nil
    }
}
