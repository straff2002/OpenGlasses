import Foundation

/// The side of the wearer's own body a reminder points at.
///
/// Wearer-relative, always. Nothing derives this from a camera frame, a medical record, handedness
/// or where the glasses sit — a frame cannot establish where someone is looking, so the only
/// source of a side is the person choosing one. `nil` (see `ScanAssistSettings.side`) is a real,
/// expected state: it means "not chosen yet", and no session may start from it.
enum ScanAssistSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case right

    var id: String { rawValue }
}

/// How a reminder reaches the wearer.
///
/// A sound is a learned reminder, not spatial audio: nothing here steers a cue to one ear, and
/// nothing claims the wearer heard it.
enum ScanAssistCueStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case spoken
    case sound

    var id: String { rawValue }
}

/// Seconds between reminders. Product settings for usability testing, not prescribed doses.
enum ScanAssistInterval: Int, Codable, CaseIterable, Identifiable, Sendable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
}

/// How long one session runs before it ends itself. Finite by design — a reminder loop with no
/// end is a reminder loop nobody turns off.
enum ScanAssistSessionDuration: Int, Codable, CaseIterable, Identifiable, Sendable {
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
}

/// Everything Scan Assist remembers between launches.
///
/// Deliberately small: a chosen side, how the cue sounds, and two timings. No diagnosis, no
/// inferred side, no session state — reopening the app never resurrects a running session
/// (docs/plans/FB-scan-assist.md P1), so "running" is not a thing this type can hold.
struct ScanAssistSettings: Equatable, Codable, Sendable {
    /// Off until the wearer turns it on. Never enabled by an upgrade or another feature.
    var enabled: Bool = false
    /// `nil` until the wearer answers the side question. Never inferred.
    var side: ScanAssistSide?
    var cueStyle: ScanAssistCueStyle = .spoken
    var interval: ScanAssistInterval = .thirtySeconds
    var sessionDuration: ScanAssistSessionDuration = .fiveMinutes

    init(enabled: Bool = false,
         side: ScanAssistSide? = nil,
         cueStyle: ScanAssistCueStyle = .spoken,
         interval: ScanAssistInterval = .thirtySeconds,
         sessionDuration: ScanAssistSessionDuration = .fiveMinutes) {
        self.enabled = enabled
        self.side = side
        self.cueStyle = cueStyle
        self.interval = interval
        self.sessionDuration = sessionDuration
    }
}

/// `UserDefaults`-backed storage for `ScanAssistSettings`.
///
/// One key per field rather than one blob: the fields are independent, a future migration only
/// touches the field it changes, and a malformed blob can't lose a wearer's chosen side. The
/// store takes its `UserDefaults` so tests use a private suite instead of the app's.
@MainActor
final class ScanAssistSettingsStore: ObservableObject {
    static let shared = ScanAssistSettingsStore()

    enum Key {
        static let enabled = "scanAssistEnabled"
        static let side = "scanAssistSide"
        static let cueStyle = "scanAssistCueStyle"
        static let intervalSeconds = "scanAssistIntervalSeconds"
        static let sessionDurationSeconds = "scanAssistSessionDurationSeconds"

        static var all: [String] {
            [enabled, side, cueStyle, intervalSeconds, sessionDurationSeconds]
        }
    }

    private let defaults: UserDefaults

    @Published var settings: ScanAssistSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> ScanAssistSettings {
        var loaded = ScanAssistSettings()
        loaded.enabled = defaults.object(forKey: Key.enabled) as? Bool ?? loaded.enabled
        // An absent key and an unrecognised value both mean "not chosen" — the one state this
        // feature must never guess its way out of.
        loaded.side = (defaults.object(forKey: Key.side) as? String).flatMap(ScanAssistSide.init(rawValue:))
        if let style = (defaults.object(forKey: Key.cueStyle) as? String).flatMap(ScanAssistCueStyle.init(rawValue:)) {
            loaded.cueStyle = style
        }
        if let interval = (defaults.object(forKey: Key.intervalSeconds) as? Int).flatMap(ScanAssistInterval.init(rawValue:)) {
            loaded.interval = interval
        }
        if let duration = (defaults.object(forKey: Key.sessionDurationSeconds) as? Int)
            .flatMap(ScanAssistSessionDuration.init(rawValue:)) {
            loaded.sessionDuration = duration
        }
        return loaded
    }

    private func persist() {
        defaults.set(settings.enabled, forKey: Key.enabled)
        if let side = settings.side {
            defaults.set(side.rawValue, forKey: Key.side)
        } else {
            defaults.removeObject(forKey: Key.side)
        }
        defaults.set(settings.cueStyle.rawValue, forKey: Key.cueStyle)
        defaults.set(settings.interval.rawValue, forKey: Key.intervalSeconds)
        defaults.set(settings.sessionDuration.rawValue, forKey: Key.sessionDurationSeconds)
    }

    /// Re-read from the backing store. Used by tests to prove a round trip through `UserDefaults`
    /// rather than through this object's own memory.
    func reload() {
        settings = Self.load(from: defaults)
    }
}
