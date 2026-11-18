import Foundation

/// Bookkeeping for photo requests sent to the glasses, so each photo answers the capture that
/// asked for it and no other.
///
/// The glasses queue photo requests and deliver each photo with no request id, and a Bluetooth
/// photo can land well after the capture that asked for it gave up and used a video frame. With a
/// single "someone is waiting" slot, two things went wrong:
///
/// - a capture's timeout timer resolved whichever capture was waiting when it fired, so a timer
///   left over from an earlier capture answered a later one with a stale frame;
/// - a photo that arrived after its own capture had timed out answered the next capture, which
///   then described the scene from seconds earlier.
///
/// The ledger fixes both. Every request gets a ``Token``. A timeout resolves a capture only when
/// its token is still the pending one. Photos are matched to requests oldest first, the order the
/// glasses deliver them, and a photo whose capture already timed out is **drained**: counted and
/// discarded, never handed on.
///
/// **Holding the slot.** While any photo is still owed (pending, or late after a timeout), a new
/// capture does not add a second request to the glasses' queue. It waits up to ``holdWait`` for
/// the owed photo to land or for an SDK error to clear it, then asks; if the photo is still owed
/// after that, it does not ask at all and uses a fresh video frame instead. Waiting first keeps the
/// usual case, a photo a few seconds late, on a real shutter photo. Not asking after the wait keeps
/// a lost or very slow photo from shifting every later photo onto the wrong capture.
///
/// An owed late photo is given up on ``owedHorizon`` after it was requested. Photos have been
/// seen up to about 13 s after the request; past the horizon the request is assumed lost, so one
/// dropped photo cannot hold every later capture to a frame for ever.
///
/// Pure value type, clock passed in: the backend owns the continuation and the timers, and calls
/// this for every decision.
struct PhotoCaptureLedger: Equatable, Sendable {

    /// One request to the glasses. Opaque outside the ledger.
    struct Token: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    /// What a photo that has just arrived belongs to.
    enum Arrival: Equatable, Sendable {
        /// The pending capture's own photo: hand it over.
        case answers(Token)
        /// The photo of a capture that already timed out: discard it.
        case drainedLate(Token)
        /// Nothing was owed: a photo nobody asked for.
        case unexpected
    }

    /// How long a capture waits for its photo before it falls back to a video frame. A cold
    /// Wi-Fi-transport capture often lands at 5–7 s, so 5 s was too tight.
    static let captureTimeout: TimeInterval = 8
    /// How long a new capture waits for an owed photo before deciding without it.
    static let holdWait: TimeInterval = 5
    /// How long after its request an owed late photo is still expected.
    static let owedHorizon: TimeInterval = 20

    private struct Request: Equatable, Sendable {
        let token: Token
        let requestedAt: Date
    }

    private var nextValue: UInt64 = 0
    /// Requested and not yet arrived, oldest first. Includes the pending one.
    private var owed: [Request] = []
    /// The capture still waiting for its photo, if any.
    private(set) var pending: Token?

    init() {}

    /// Owed photos whose capture already timed out, within the horizon at `now`.
    func latePhotosOwed(at now: Date) -> Int {
        owed.filter { $0.token != pending && now.timeIntervalSince($0.requestedAt) < Self.owedHorizon }.count
    }

    /// Whether a new capture must wait before asking the glasses for a photo.
    func mustHold(at now: Date) -> Bool {
        pending != nil || latePhotosOwed(at: now) > 0
    }

    /// Record a request to the glasses and make it the pending capture. Callers check
    /// ``mustHold(at:)`` first; a capture that is still pending is never replaced.
    mutating func issue(at now: Date) -> Token? {
        expire(at: now)
        guard pending == nil else { return nil }
        nextValue += 1
        let token = Token(value: nextValue)
        owed.append(Request(token: token, requestedAt: now))
        pending = token
        return token
    }

    /// The SDK refused the request outright (`capturePhoto` returned false): nothing is owed.
    mutating func rejected(_ token: Token) {
        owed.removeAll { $0.token == token }
        if pending == token { pending = nil }
    }

    /// `token`'s timer fired. True only when `token` is still the pending capture, which the caller
    /// then resolves with its fallback; its photo stays owed so that it is drained when it comes.
    /// A timer from an earlier capture returns false and touches nothing.
    mutating func timedOut(_ token: Token) -> Bool {
        guard pending == token else { return false }
        pending = nil
        return true
    }

    /// A photo arrived. It belongs to the oldest owed request.
    mutating func photoArrived(at now: Date) -> Arrival {
        expire(at: now)
        guard !owed.isEmpty else { return .unexpected }
        let oldest = owed.removeFirst()
        if oldest.token == pending {
            pending = nil
            return .answers(oldest.token)
        }
        return .drainedLate(oldest.token)
    }

    /// A terminal SDK error (hinges closed, device gone, thermal or battery shutdown): no queued
    /// photo is coming. Returns the pending capture for the caller to resolve, and forgets every
    /// owed photo.
    mutating func aborted() -> Token? {
        let token = pending
        pending = nil
        owed.removeAll()
        return token
    }

    /// Forget late photos past the horizon. The pending capture is never expired: its own timer
    /// resolves it well inside the horizon.
    mutating func expire(at now: Date) {
        owed.removeAll { $0.token != pending && now.timeIntervalSince($0.requestedAt) >= Self.owedHorizon }
    }
}
