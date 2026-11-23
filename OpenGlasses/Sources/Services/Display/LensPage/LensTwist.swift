import Foundation

// Plan NB §2: the Neural Band's wrist, in the app's own words. Pure and SDK-free, compiled and
// tested in every build. Only a flagged (TestFlight-only) build hears the band's motion: its
// wiring lives in `Sources/Glasses/Experimental/` and hands each sample here.

/// A unit quaternion `(x, y, z, w)` taking the band's own frame to the world's (up = +Z).
struct WristQuaternion: Equatable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    static let identity = WristQuaternion(x: 0, y: 0, z: 0, w: 1)

    /// A rotation of `angle` radians about `axis` (normalised here).
    init(axis: WristVector, angle: Double) {
        let unit = axis.normalized
        let half = angle / 2
        let s = sin(half)
        self.init(x: unit.x * s, y: unit.y * s, z: unit.z * s, w: cos(half))
    }

    init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    var length: Double { (x * x + y * y + z * z + w * w).squareRoot() }

    /// Scaled to unit length; the identity for a zero (or not finite) quaternion.
    var normalized: WristQuaternion {
        let n = length
        guard n.isFinite, n > 1e-12 else { return .identity }
        return WristQuaternion(x: x / n, y: y / n, z: z / n, w: w / n)
    }

    /// `self ∘ other`: `other` applied first.
    static func * (a: WristQuaternion, b: WristQuaternion) -> WristQuaternion {
        WristQuaternion(x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                        y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                        z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                        w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
    }

    /// `v` rotated by this (unit) quaternion.
    func rotate(_ v: WristVector) -> WristVector {
        let q = normalized
        let u = WristVector(x: q.x, y: q.y, z: q.z)
        let t = u.cross(v) * 2
        return v + t * q.w + u.cross(t)
    }
}

/// A three-axis reading or direction.
struct WristVector: Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let forearm = WristVector(x: 0, y: 1, z: 0)
    static let up = WristVector(x: 0, y: 0, z: 1)

    var length: Double { (x * x + y * y + z * z).squareRoot() }
    var normalized: WristVector {
        let n = length
        guard n.isFinite, n > 1e-12 else { return WristVector(x: 0, y: 0, z: 0) }
        return WristVector(x: x / n, y: y / n, z: z / n)
    }
    func dot(_ o: WristVector) -> Double { x * o.x + y * o.y + z * o.z }
    func cross(_ o: WristVector) -> WristVector {
        WristVector(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x)
    }
    static func + (a: WristVector, b: WristVector) -> WristVector { WristVector(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func * (a: WristVector, s: Double) -> WristVector { WristVector(x: a.x * s, y: a.y * s, z: a.z * s) }
}

/// One motion sample from the Neural Band, as the app keeps it: when (the SDK's own clock, in
/// nanoseconds), the fused orientation and the gyroscope (radians a second, band-local), each when
/// the sample carried one. Never written down: the probe keeps counts and angles only.
struct WristSample: Equatable {
    var timestampNs: Int64
    var orientation: WristQuaternion?
    var gyroscope: WristVector?
}

/// Where a motion sample came from (the glasses or the band), in the app's own words.
enum WristSampleOrigin: String, CaseIterable, Equatable, Hashable {
    case glasses, neuralBand, unknown
}

/// The wrist's twist about the forearm (Plan NB §2). Pure.
enum WristTwist {
    /// Below this a sample's orientation is not used (`confidence`).
    static let minimumConfidence = 0.35

    /// The signed twist about the forearm axis (band-local +Y), in radians, from a unit quaternion:
    /// the twist part of a swing–twist split, `2·atan2(q·axis, w)`, wrapped to [−π, π). No Euler
    /// angles.
    static func angle(of q: WristQuaternion) -> Double {
        let unit = q.normalized
        return wrap(2 * atan2(unit.y, unit.w))
    }

    /// An angle in [−π, π): +179° to −179° is a 2° step.
    static func wrap(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        let twoPi = 2 * Double.pi
        var a = (angle + .pi).truncatingRemainder(dividingBy: twoPi)
        if a < 0 { a += twoPi }
        return a - .pi
    }

    /// The forearm's direction in the world.
    static func forearm(of q: WristQuaternion) -> WristVector {
        q.rotate(.forearm).normalized
    }

    /// How far gravity can resolve the twist: 1 with the forearm level, falling to 0 as it points
    /// straight up or down (`1 − |forearm · up|`).
    static func confidence(of q: WristQuaternion) -> Double {
        let f = forearm(of: q)
        return max(0, min(1, 1 - abs(f.dot(.up))))
    }

    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}

/// One clutch's twist from its samples (Plan NB §2, decision 6). Pure: samples in, the twist since
/// the reference out.
///
/// - **Orientation first.** A sample with an orientation (and enough confidence) moves the twist by
///   its change since the last such sample, unwrapped, so passing ±180° is a small step.
/// - **The gyroscope as fallback.** A sample with no orientation but a gyroscope adds `gyro.y · dt`
///   (the forearm axis), `dt` from `timestampNs` and capped at 100 ms, so a gap never jumps.
/// - **The reference** is the first usable sample after a 150 ms settle, never the very first.
/// - **A flip of more than 120° between two samples in the first 500 ms** is the frame settling:
///   the reference is taken again.
struct TwistTracker: Equatable {
    static let settleNs: Int64 = 150_000_000
    static let maxGyroStepNs: Int64 = 100_000_000
    static let flipWindowNs: Int64 = 500_000_000
    static let flipRadians = WristTwist.radians(120)

    /// The first sample's time.
    private(set) var startNs: Int64?
    /// Whether the reference has been taken.
    private(set) var isReferenced = false
    /// The twist since the reference, radians (signed; not wrapped).
    private(set) var angle: Double = 0
    /// How many times the reference was taken again (a settling flip).
    private(set) var rereferences = 0
    /// The last orientation angle used, while the last sample used carried one.
    private var lastRaw: Double?
    private var lastNs: Int64?

    /// The twist since the reference after `sample`, nil until the reference is taken.
    @discardableResult
    mutating func add(_ sample: WristSample) -> Double? {
        let ts = sample.timestampNs
        if let lastNs, ts < lastNs { return isReferenced ? angle : nil }   // out of order: ignored
        guard let start = startNs else {
            startNs = ts
            lastNs = ts
            return nil
        }
        let raw: Double? = sample.orientation.flatMap { q in
            WristTwist.confidence(of: q) >= WristTwist.minimumConfidence ? WristTwist.angle(of: q) : nil
        }
        // A sample whose forearm points too near up or down is not used at all (`confidence`);
        // nor is one with neither reading.
        if sample.orientation != nil, raw == nil { return isReferenced ? angle : nil }
        guard raw != nil || sample.gyroscope != nil else { return isReferenced ? angle : nil }
        if !isReferenced {
            guard ts - start >= Self.settleNs else {
                lastNs = ts
                lastRaw = raw
                return nil
            }
            isReferenced = true
            angle = 0
            lastRaw = raw
            lastNs = ts
            return angle
        }
        if let raw {
            if let previous = lastRaw {
                let step = WristTwist.wrap(raw - previous)
                if abs(step) > Self.flipRadians, ts - start <= Self.flipWindowNs {
                    angle = 0
                    rereferences += 1
                } else {
                    angle += step
                }
            }
            // After a run of gyroscope samples the orientation is rebased, never jumped to.
            lastRaw = raw
        } else if let gyro = sample.gyroscope {
            let dt = min(ts - (lastNs ?? ts), Self.maxGyroStepNs)
            if dt > 0, gyro.y.isFinite { angle += gyro.y * Double(dt) / 1e9 }
            lastRaw = nil
        }
        lastNs = ts
        return angle
    }
}

/// One rung of the zoom ladder a twist asks for.
enum TwistRung: String, Equatable {
    case zoomIn, zoomOut
}

/// Which way the twist zooms (Plan NB decision 9): a constant, plus the wearer's "Reverse the
/// twist". The device pass (P3) sets which sign of the twist angle "clockwise" is.
enum TwistDirection: String, Equatable {
    case clockwiseZoomsIn, anticlockwiseZoomsIn

    /// Whether a positive twist angle (about band-local +Y) is clockwise as the wearer sees it.
    /// Unknown until the probe reads it on a pair (P3): the web runtime mirrors the left wrist,
    /// and nothing says DAT does.
    static let clockwiseIsPositive = true

    /// The default, with the wearer's reversal.
    static func current(reversed: Bool) -> TwistDirection {
        reversed ? .anticlockwiseZoomsIn : .clockwiseZoomsIn
    }

    /// The rung a twist of `sign` (+1 or −1, of the angle) asks for.
    func rung(forSign sign: Int) -> TwistRung {
        let clockwise = (sign > 0) == Self.clockwiseIsPositive
        switch self {
        case .clockwiseZoomsIn: return clockwise ? .zoomIn : .zoomOut
        case .anticlockwiseZoomsIn: return clockwise ? .zoomOut : .zoomIn
        }
    }
}

/// Turns a clutch's twist into rungs (Plan NB §2, decision 3). Pure: angles in, rungs out.
///
/// Every `detent` past the last rung emits one rung, in or out by sign, and the next needs
/// `detent` more from there. Turning back needs `detent + hysteresis` from the last rung before a
/// rung the other way, so a wrist hovering on a boundary never sends in, out, in. At most
/// `maxRungsPerClutch` a clutch.
struct TwistZoomDetent: Equatable {
    static let detent = WristTwist.radians(20)
    static let hysteresis = WristTwist.radians(5)
    static let maxRungsPerClutch = 6

    var direction: TwistDirection
    var detent: Double = TwistZoomDetent.detent
    var hysteresis: Double = TwistZoomDetent.hysteresis
    var maxRungs: Int = TwistZoomDetent.maxRungsPerClutch

    /// The angle of the last rung (the reference before any).
    private(set) var anchor: Double = 0
    /// The sign of the last rung's angle, 0 before any.
    private(set) var lastSign = 0
    private(set) var rungsSent = 0

    init(direction: TwistDirection = .clockwiseZoomsIn) {
        self.direction = direction
    }

    var isCapped: Bool { rungsSent >= maxRungs }

    /// The rungs the twist's angle since the reference asks for now, oldest first.
    mutating func update(angle: Double) -> [TwistRung] {
        guard angle.isFinite else { return [] }
        var rungs: [TwistRung] = []
        while rungsSent < maxRungs {
            let delta = angle - anchor
            let sign = delta >= 0 ? 1 : -1
            let reversing = lastSign != 0 && sign != lastSign
            let needed = reversing ? detent + hysteresis : detent
            guard abs(delta) >= needed - 1e-9 else { break }
            anchor += Double(sign) * needed
            lastSign = sign
            rungsSent += 1
            rungs.append(direction.rung(forSign: sign))
        }
        return rungs
    }
}

/// Pinch and move the arm to pan (Plan NB §2; its own switch, owner 2026-11-23). Pure. While
/// clutched, the forearm's pointing direction (the forearm axis rotated into the world) against
/// the reference: past `threshold` of yaw or pitch it emits a move that way and re-anchors there.
/// The reference is taken after the same 150 ms settle as the twist's, from a sample whose forearm
/// is not near vertical (where yaw means nothing).
struct ArmPan: Equatable {
    static let threshold = WristTwist.radians(12)

    var threshold: Double = ArmPan.threshold
    private(set) var startNs: Int64?
    /// The direction moves are measured from; nil until the reference is taken.
    private(set) var referenceYaw: Double?
    private(set) var referencePitch: Double = 0
    private(set) var stepsSent = 0

    /// Yaw (about up, anticlockwise from above positive) and pitch (up positive) of the forearm.
    static func direction(of q: WristQuaternion) -> (yaw: Double, pitch: Double) {
        let f = WristTwist.forearm(of: q)
        return (atan2(f.y, f.x), asin(max(-1, min(1, f.z))))
    }

    /// The move the sample asks for, if any. Yaw anticlockwise from above (the arm swung to the
    /// wearer's left) is `.left`; pitch up is `.up`. The larger of the two wins.
    mutating func update(_ sample: WristSample) -> LensPageViewport.Step? {
        guard let q = sample.orientation else { return nil }
        guard let start = startNs else { startNs = sample.timestampNs; return nil }
        guard sample.timestampNs - start >= TwistTracker.settleNs,
              WristTwist.confidence(of: q) >= WristTwist.minimumConfidence else { return nil }
        let now = Self.direction(of: q)
        guard let referenceYaw else {
            self.referenceYaw = now.yaw
            referencePitch = now.pitch
            return nil
        }
        let yaw = WristTwist.wrap(now.yaw - referenceYaw)
        let pitch = now.pitch - referencePitch
        guard max(abs(yaw), abs(pitch)) >= threshold else { return nil }
        self.referenceYaw = now.yaw
        referencePitch = now.pitch
        stepsSent += 1
        if abs(yaw) >= abs(pitch) { return yaw > 0 ? .left : .right }
        return pitch > 0 ? .up : .down
    }
}
