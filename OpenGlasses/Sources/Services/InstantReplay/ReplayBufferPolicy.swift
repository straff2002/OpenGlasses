import Foundation

/// Instant Replay — when the short rolling video buffer may exist at all, and how big it is.
///
/// The buffer keeps the last minute (by default) of what the glasses camera already showed, as
/// short encoded segments on the phone, so "keep the last 30 seconds" can save a moment that has
/// already happened. Everything about *whether* it runs is decided here, as plain values, so every
/// condition is a table row in a test rather than an `if` buried in a frame callback.
///
/// The buffer runs only when **every** condition holds, and is deleted the moment one stops:
///
/// - the setting is on (off by default) and no organisation profile pins it off;
/// - the glasses camera is already streaming for something else. Instant Replay never starts,
///   keeps alive or restarts a stream — it rides one the wearer started and can see;
/// - Medical Compliance mode is off;
/// - the power posture is normal. At a raised posture the buffer stops rather than lowering its
///   quality, so it never competes with the stream's own purpose;
/// - free storage is above twice the buffer's size plus the recorder's own low-storage line.
///
/// The relay delivering nothing (the privacy filter required and failing) is **not** a reason to
/// stop: the buffer simply has a gap, and is never fed raw frames instead.
enum ReplayBufferPolicy {

    /// Everything the decision depends on, read by the caller.
    struct Conditions: Equatable {
        var settingOn: Bool
        var orgPinnedOff: Bool
        var glassesStreaming: Bool
        var medicalCompliance: Bool
        var posture: PowerPosture
        /// Free bytes on the volume, or nil when the system would not say. Unknown is not a
        /// refusal: the recorder starts on an unknown too, and a phone that cannot report its
        /// own storage is not one that is out of it.
        var freeBytes: Int64?
        var plan: ReplayBufferPlan
    }

    enum Decision: Equatable {
        case run(ReplayBufferPlan)
        case off(ReplayOffReason)

        var isRunning: Bool { if case .run = self { return true }; return false }
        var offReason: ReplayOffReason? { if case .off(let reason) = self { return reason }; return nil }
    }

    /// The storage the buffer must leave free beyond itself: the long-form recorder's own
    /// low-storage line, so a replay never takes the space a recording the wearer starts on
    /// purpose would warn about.
    /// The same figure as `VideoRecordingService.lowStorageBytes` (a test holds the two
    /// together); restated here because that one lives on a main-actor type.
    static let storageFloorBytes: Int64 = 2_000 * 1_000_000

    /// The order is the order the reasons are worth hearing in: a switch that is off says so
    /// before anything about the camera; a camera that isn't on is said before anything
    /// that would only matter if it were.
    static func decide(_ c: Conditions) -> Decision {
        // An organisation's pin is said before the switch it holds down: a ceiling makes the
        // setting read off, and "it's switched off in Settings" would send the wearer looking
        // for a switch they cannot move.
        guard !c.orgPinnedOff else { return .off(.organisationOff) }
        guard c.settingOn else { return .off(.settingOff) }
        guard !c.medicalCompliance else { return .off(.medicalCompliance) }
        guard c.glassesStreaming else { return .off(.cameraOff) }
        guard c.posture == .normal else { return .off(.power) }
        if let free = c.freeBytes,
           free < 2 * c.plan.bufferBytes + storageFloorBytes {
            return .off(.lowStorage)
        }
        return .run(c.plan)
    }
}

/// Why the buffer is not running, in the words the wearer hears and the settings footer shows.
enum ReplayOffReason: String, Equatable, CaseIterable {
    case settingOff
    case organisationOff
    case medicalCompliance
    case cameraOff
    case power
    case lowStorage

    /// Completes "Instant Replay isn't running: …".
    var spokenClause: String {
        switch self {
        case .settingOff: return "it's switched off in Settings."
        case .organisationOff: return "your organisation has switched it off."
        case .medicalCompliance: return "it's off in Medical Compliance mode."
        case .cameraOff: return "the camera's off."
        case .power: return "it stops while the phone or glasses are saving power."
        case .lowStorage: return "the phone is low on storage."
        }
    }

    var spoken: String { "Instant Replay isn't running: " + spokenClause }

    /// One short line for the settings row and the status mark's description.
    var statusLine: String {
        switch self {
        case .settingOff: return "Off"
        case .organisationOff: return "Off by your organisation"
        case .medicalCompliance: return "Off in Medical Compliance mode"
        case .cameraOff: return "Waiting for the camera"
        case .power: return "Paused to save power"
        case .lowStorage: return "Paused: low storage"
        }
    }
}

/// The buffer's shape: segment length, how many segments it keeps, and what that costs on disk,
/// worked from the frame size the relay actually delivers (never assumed) and the stream's rate.
struct ReplayBufferPlan: Equatable {

    /// Each segment starts on a keyframe, so a save can be cut at any segment boundary without a
    /// re-encode. Two seconds keeps the overshoot of a cut small (a 30-second ask is 30–32).
    static let segmentSeconds: TimeInterval = 2

    /// The lengths the wearer can choose. A minute is the default.
    static let bufferChoices: [TimeInterval] = [30, 60, 120]
    static let defaultBufferSeconds: TimeInterval = 60
    /// What "save the replay" keeps when no length is said.
    static let defaultSaveSeconds: TimeInterval = 30

    let bufferSeconds: TimeInterval
    let width: Int
    let height: Int
    let frameRate: Int
    /// Bits a second, from `VideoBitratePolicy`'s disk profile at this size and rate — the same
    /// figure the long-form recorder and job clips encode at.
    let bitrate: Int

    init(bufferSeconds: TimeInterval, width: Int, height: Int, frameRate: Int) {
        let choice = Self.bufferChoices.contains(bufferSeconds) ? bufferSeconds : Self.defaultBufferSeconds
        self.bufferSeconds = choice
        self.width = max(2, width)
        self.height = max(2, height)
        self.frameRate = max(1, frameRate)
        self.bitrate = VideoBitratePolicy.bitrate(width: self.width, height: self.height,
                                                  frameRate: Double(self.frameRate), profile: .disk)
    }

    /// The plan for a stream tier before its first frame has said what it really delivers.
    static func estimate(bufferSeconds: TimeInterval, resolution: String, frameRate: Int) -> ReplayBufferPlan {
        let size = StreamConfigPolicy.encodedSize(for: resolution)
        return ReplayBufferPlan(bufferSeconds: bufferSeconds, width: size.width, height: size.height,
                                frameRate: frameRate)
    }

    /// Segments kept: the buffer plus the one being written, so the full length is always on disk
    /// even at the moment the oldest is about to go.
    var capacity: Int { Int((bufferSeconds / Self.segmentSeconds).rounded(.up)) + 1 }

    /// Bytes for `seconds` of video at this plan's bitrate.
    func bytes(forSeconds seconds: TimeInterval) -> Int64 {
        Int64((Double(bitrate) / 8 * max(0, seconds)).rounded())
    }

    /// The most the buffer holds on disk: its length plus one segment of overhead.
    var bufferBytes: Int64 { bytes(forSeconds: bufferSeconds + Self.segmentSeconds) }

    /// "about 44 MB" — megabytes in the decimal sense the Settings app and the Files app use.
    static func megabytesPhrase(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes < 10 { return String(format: "about %.1f MB", megabytes) }
        return "about \(Int(megabytes.rounded())) MB"
    }

    /// The settings footer's size line, for the stream as it is configured now.
    var footerSizeLine: String {
        "Keeps up to \(Self.megabytesPhrase(bufferBytes)) on the phone while the camera is on."
    }
}
