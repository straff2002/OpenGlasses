import CoreLocation
import Foundation

/// One motion-activity reading, independent of CoreMotion so the detector is testable headless.
struct MotionSample: Equatable {
    enum Kind: String, Equatable { case automotive, walking, running, cycling, stationary, unknown }
    enum Confidence: Int, Comparable, Equatable {
        case low = 0, medium = 1, high = 2
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind
    let confidence: Confidence
    let at: Date

    init(_ kind: Kind, confidence: Confidence = .high, at: Date) {
        self.kind = kind
        self.confidence = confidence
        self.at = at
    }

    /// On foot, for the walking-after-driving rule. Running counts — people jog back to a meter.
    var isOnFoot: Bool { kind == .walking || kind == .running }
}

/// One location fix the detector may use, independent of `CLLocation`.
struct LocationFix: Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let at: Date

    init(latitude: Double, longitude: Double, horizontalAccuracy: Double = 10, at: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.at = at
    }

    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                  horizontalAccuracy: location.horizontalAccuracy, at: location.timestamp)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Plan GH — decides, from CarPlay, motion and location inputs, that a drive has ended and where
/// the car probably is. A pure state machine with the clock passed in on every input.
///
/// Two paths, in order of trust:
/// - **CarPlay disconnect** after at least three minutes connected: the spot is the last fix
///   received while connected. Fresh (≤ 60 s) → `certain`; older → `probable`, and the recall says
///   how old it was. No fix while connected → no spot, because a fix from before the drive is where
///   the drive *started*.
/// - **Motion** ("I drive" on only): automotive at medium/high confidence for three minutes, then on
///   foot for thirty seconds, starting within three minutes of the drive ending. The spot is the
///   last fix taken during the drive, up to thirty seconds past its end; `probable`, because a
///   passenger produces exactly the same pattern. With no fix in that window there is no spot — the
///   plan's "last fix the app had" is refused when that fix predates the drive, for the same reason
///   as above: the app is usually suspended while driving, and its last fix is the driveway.
///
/// Replaying `CMMotionActivityManager` history through the same inputs is what finds a transition
/// that happened while the app was suspended; samples older than the last one seen are ignored, so
/// a replay and live updates can overlap safely.
struct DriveEndDetector {

    struct Settings: Equatable {
        var carPlayCapture: Bool
        var motionCapture: Bool

        static let off = Settings(carPlayCapture: false, motionCapture: false)
    }

    struct Thresholds: Equatable {
        var minimumCarPlaySession: TimeInterval = 3 * 60
        var freshFixAge: TimeInterval = 60
        var minimumDrive: TimeInterval = 3 * 60
        var minimumWalk: TimeInterval = 30
        var walkMustStartWithin: TimeInterval = 3 * 60
        var fixGraceAfterDriveEnd: TimeInterval = 30
        var bufferedFixes = 64
    }

    /// A spot the detector wants saved.
    struct Detection: Equatable {
        let fix: LocationFix
        let capture: ParkingSpot.Capture
        let confidence: ParkingSpot.Confidence
        /// When the drive ended — the CarPlay disconnect, or the automotive→stationary edge.
        let driveEndedAt: Date

        func spot(savedAt: Date) -> ParkingSpot {
            ParkingSpot(coordinate: fix.coordinate, horizontalAccuracy: fix.horizontalAccuracy,
                        locationAt: fix.at, savedAt: savedAt, capture: capture, confidence: confidence)
        }
    }

    enum Input: Equatable {
        case carPlayConnected(at: Date)
        case carPlayDisconnected(at: Date)
        case motion(MotionSample)
        case fix(LocationFix)
        /// Time passing with no new sample — how "walking for thirty seconds" is noticed when
        /// CoreMotion only reports changes.
        case tick(at: Date)
    }

    var settings: Settings
    var thresholds = Thresholds()

    private(set) var carPlayConnectedAt: Date?
    private(set) var driveStartedAt: Date?
    private(set) var driveEndedAt: Date?
    private(set) var walkStartedAt: Date?
    private(set) var lastMotionAt: Date?
    private var fixes: [LocationFix] = []
    /// After a CarPlay save, the same drive must not also end by motion.
    private var motionSuppressedUntil: Date?

    init(settings: Settings, thresholds: Thresholds = Thresholds()) {
        self.settings = settings
        self.thresholds = thresholds
    }

    /// Whether a drive-end is pending on foot time — the caller schedules a tick for this instant.
    var pendingWalkConfirmationAt: Date? {
        guard let walkStartedAt else { return nil }
        return walkStartedAt.addingTimeInterval(thresholds.minimumWalk)
    }

    mutating func handle(_ input: Input) -> Detection? {
        switch input {
        case .fix(let fix):
            guard fix.horizontalAccuracy >= 0 else { return nil }
            fixes.append(fix)
            if fixes.count > thresholds.bufferedFixes { fixes.removeFirst(fixes.count - thresholds.bufferedFixes) }
            return nil

        case .carPlayConnected(let at):
            carPlayConnectedAt = at
            return nil

        case .carPlayDisconnected(let at):
            defer { carPlayConnectedAt = nil }
            guard settings.carPlayCapture, let connectedAt = carPlayConnectedAt,
                  at.timeIntervalSince(connectedAt) >= thresholds.minimumCarPlaySession else { return nil }
            guard let fix = fixes.last(where: { $0.at >= connectedAt && $0.at <= at }) else { return nil }
            let fresh = at.timeIntervalSince(fix.at) <= thresholds.freshFixAge
            resetMotion()
            motionSuppressedUntil = at.addingTimeInterval(thresholds.walkMustStartWithin + thresholds.minimumWalk)
            return Detection(fix: fix, capture: .carPlayDisconnect,
                             confidence: fresh ? .certain : .probable, driveEndedAt: at)

        case .motion(let sample):
            if let lastMotionAt, sample.at < lastMotionAt { return nil }
            lastMotionAt = sample.at
            return handleMotion(sample)

        case .tick(let at):
            return evaluateWalk(now: at)
        }
    }

    // MARK: - Motion

    private mutating func handleMotion(_ sample: MotionSample) -> Detection? {
        guard settings.motionCapture else { resetMotion(); return nil }

        switch sample.kind {
        case .automotive:
            guard sample.confidence >= .medium else { return nil }
            if driveStartedAt == nil { driveStartedAt = sample.at }
            // Back in the car after a stop at the lights: the drive continues.
            driveEndedAt = nil
            walkStartedAt = nil
            return nil

        case .stationary, .unknown, .cycling:
            if driveStartedAt != nil, driveEndedAt == nil { driveEndedAt = sample.at }
            walkStartedAt = nil
            return evaluateWalk(now: sample.at)

        case .walking, .running:
            guard driveStartedAt != nil else { return nil }
            if driveEndedAt == nil { driveEndedAt = sample.at }
            if walkStartedAt == nil { walkStartedAt = sample.at }
            return evaluateWalk(now: sample.at)
        }
    }

    private mutating func evaluateWalk(now: Date) -> Detection? {
        guard settings.motionCapture, let start = driveStartedAt, let end = driveEndedAt else { return nil }

        // A drive that never lasted long enough, or a stop that never became a walk, is dropped.
        if end.timeIntervalSince(start) < thresholds.minimumDrive {
            if walkStartedAt != nil || now.timeIntervalSince(end) > thresholds.walkMustStartWithin {
                resetMotion()
            }
            return nil
        }
        guard let walk = walkStartedAt else {
            if now.timeIntervalSince(end) > thresholds.walkMustStartWithin { resetMotion() }
            return nil
        }
        guard walk.timeIntervalSince(end) <= thresholds.walkMustStartWithin else {
            resetMotion()
            return nil
        }
        guard now.timeIntervalSince(walk) >= thresholds.minimumWalk else { return nil }

        defer { resetMotion() }
        if let suppressed = motionSuppressedUntil, end <= suppressed { return nil }
        let latest = end.addingTimeInterval(thresholds.fixGraceAfterDriveEnd)
        guard let fix = fixes.last(where: { $0.at >= start && $0.at <= latest }) else { return nil }
        return Detection(fix: fix, capture: .motion, confidence: .probable, driveEndedAt: end)
    }

    private mutating func resetMotion() {
        driveStartedAt = nil
        driveEndedAt = nil
        walkStartedAt = nil
    }
}

/// Plan GH decision 3: an automatic save is silent with a notification, and spoken only after a
/// CarPlay disconnect — the one moment the wearer has just stopped and is likely listening.
enum ParkingAutoSaveAnnouncement {
    struct Plan: Equatable {
        let speak: Bool
        let notify: Bool
    }

    static func plan(for capture: ParkingSpot.Capture) -> Plan {
        switch capture {
        case .carPlayDisconnect: return Plan(speak: true, notify: true)
        case .motion: return Plan(speak: false, notify: true)
        case .voice, .photo: return Plan(speak: false, notify: false)
        }
    }

    static let spokenConfirmation = "Saved where you parked."
    static let notificationTitle = "Parking saved"
    static let notificationBody = "Avenkin saved where you parked. Ask \u{201C}where did I park?\u{201D} to find your way back."
}
