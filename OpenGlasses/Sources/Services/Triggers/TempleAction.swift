import Foundation

/// What a temple tap can be assigned to do (Plan GJ).
///
/// The glasses maker's own gestures — the long press that summons their assistant and the capture
/// button — never reach the app and are not in this list. "Read my digest" is the honest version of
/// "read my messages": iOS does not let an app read other apps' messages, so the tap reads the
/// app's own digest of what it has collected.
enum TempleAction: Hashable, Identifiable {
    case nothing
    case startTalking
    case hangUp
    case mute
    case photoDescribe
    case photoToCameraRoll
    case readDigest
    case toggleRecording
    /// Hand the next thing the wearer says straight to their agent. Agent Mode only.
    case askAgent
    /// Run a saved Quick Action by id.
    case quickAction(String)

    private static let quickActionPrefix = "quickAction:"

    /// Every assignable action that is not a Quick Action, in picker order.
    static let builtIns: [TempleAction] = [
        .startTalking, .hangUp, .mute, .photoDescribe, .photoToCameraRoll,
        .readDigest, .toggleRecording, .askAgent, .nothing,
    ]

    /// Persisted form. Stable — never rename a case's value.
    var rawValue: String {
        switch self {
        case .nothing: return "none"
        case .startTalking: return "startTalking"
        case .hangUp: return "hangUp"
        case .mute: return "mute"
        case .photoDescribe: return "photoDescribe"
        case .photoToCameraRoll: return "photoToCameraRoll"
        case .readDigest: return "readDigest"
        case .toggleRecording: return "toggleRecording"
        case .askAgent: return "askAgent"
        case .quickAction(let id): return Self.quickActionPrefix + id
        }
    }

    /// Parse a persisted value. Anything unknown — a value from a newer build, a typo, an empty
    /// Quick Action id — reads as `.nothing`, never as some other action.
    init(rawValue: String) {
        if rawValue.hasPrefix(Self.quickActionPrefix) {
            let id = String(rawValue.dropFirst(Self.quickActionPrefix.count))
            self = id.isEmpty ? .nothing : .quickAction(id)
            return
        }
        self = Self.builtIns.first { $0.rawValue == rawValue } ?? .nothing
    }

    var id: String { rawValue }

    var requiresAgentMode: Bool { self == .askAgent }

    /// Picker label. Quick Actions are labelled by the caller, which knows their names.
    var displayName: String {
        switch self {
        case .nothing: return String(localized: "Nothing")
        case .startTalking: return String(localized: "Start talking")
        case .hangUp: return String(localized: "Hang up")
        case .mute: return String(localized: "Mute or unmute the mic")
        case .photoDescribe: return String(localized: "Photo and describe")
        case .photoToCameraRoll: return String(localized: "Photo to camera roll")
        case .readDigest: return String(localized: "Read my digest")
        case .toggleRecording: return String(localized: "Start or stop recording")
        case .askAgent: return String(localized: "Ask my agent")
        case .quickAction: return String(localized: "Quick Action")
        }
    }
}

/// The three assignments, one per tap count (Plan GJ).
struct TempleGestureMap: Equatable {
    var one: TempleAction
    var two: TempleAction
    var three: TempleAction

    /// New wearers: one tap talks, two taps hang up, three taps mute.
    static let defaults = TempleGestureMap(one: .startTalking, two: .hangUp, three: .mute)

    /// Wearers who had the earlier single-gesture temple tap switched on: a double tap (next track)
    /// kept starting a conversation and nothing else did anything, so that is exactly what they keep.
    static let legacyDoubleTapToTalk = TempleGestureMap(one: .nothing, two: .startTalking, three: .nothing)

    func action(for gesture: TempleGesture) -> TempleAction {
        switch gesture {
        case .one: return one
        case .two: return two
        case .three: return three
        }
    }

    mutating func set(_ action: TempleAction, for gesture: TempleGesture) {
        switch gesture {
        case .one: one = action
        case .two: two = action
        case .three: three = action
        }
    }
}

/// Reads and writes the map as three raw strings. A missing key falls back to that tap's default;
/// an unreadable one reads as `.nothing`.
struct TempleGestureMapStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(for gesture: TempleGesture) -> String { "templeTap.\(gesture.rawValue)" }

    func load() -> TempleGestureMap {
        var map = TempleGestureMap.defaults
        for gesture in TempleGesture.allCases {
            if let raw = defaults.string(forKey: Self.key(for: gesture)) {
                map.set(TempleAction(rawValue: raw), for: gesture)
            }
        }
        return map
    }

    func save(_ map: TempleGestureMap) {
        for gesture in TempleGesture.allCases {
            defaults.set(map.action(for: gesture).rawValue, forKey: Self.key(for: gesture))
        }
    }

    var hasStoredMap: Bool {
        TempleGesture.allCases.contains { defaults.object(forKey: Self.key(for: $0)) != nil }
    }
}

/// One-time carry-over from the single-gesture temple tap (Plan GJ P1, decision 1).
///
/// The on/off switch keeps its key, so a wearer who had it on still has it on. What changes is what
/// the taps do: new wearers get `TempleGestureMap.defaults`, but anyone who already had the switch
/// on keeps double tap = start talking (`legacyDoubleTapToTalk`), because that is the gesture they
/// learned. Runs once, behind a flag; a map the wearer has already saved is never overwritten.
enum TempleGestureSettingsMigration {
    static let doneKey = "templeTapMapMigrated"
    static let legacyEnabledKey = "mediaTriggerEnabled"

    enum Outcome: Equatable {
        case alreadyDone
        /// The wearer had the old switch on: double tap still talks.
        case keptDoubleTapToTalk
        /// Nothing to carry over; the defaults apply.
        case defaultsApply
    }

    @discardableResult
    static func run(defaults: UserDefaults = .standard) -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return .alreadyDone }
        defer { defaults.set(true, forKey: doneKey) }
        let store = TempleGestureMapStore(defaults: defaults)
        guard defaults.bool(forKey: legacyEnabledKey), !store.hasStoredMap else {
            return .defaultsApply
        }
        store.save(.legacyDoubleTapToTalk)
        return .keptDoubleTapToTalk
    }
}
