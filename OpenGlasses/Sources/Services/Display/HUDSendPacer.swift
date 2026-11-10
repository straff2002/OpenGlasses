import Foundation

/// Plan KX §2.4: how the render queue spaces its sends to the glasses.
///
/// A send is not free on the Display's Bluetooth link (a developer measured ~47 ms for text and
/// ~155 ms for a 552 × 220 image), and the apps that reached hardware all pace theirs: hermes-glasses
/// sends a transcript at most every 0.4 s, MultiSet an image at most once a second. The queue is
/// already latest-wins with one send in flight; the pacer adds the gap, so a stream of caption or
/// transcript updates collapses into fewer, newer frames rather than queueing behind the link.
/// Pure: the queue asks it how long to wait before the next send.
struct HUDSendPacer: Equatable {
    /// The least time between the end of one send and the start of the next, after a text frame.
    static let textGap: TimeInterval = 0.4
    /// After a frame that carried a picture: the link is still busy with it for longer.
    static let pictureGap: TimeInterval = 1.0

    /// When the last send ended, and whether it carried a picture. Nil before the first send.
    private(set) var lastEnd: Date?
    private(set) var lastHadPicture = false

    /// How long to wait at `now` before the next send may start. Zero when it may go at once.
    func delay(at now: Date) -> TimeInterval {
        guard let lastEnd else { return 0 }
        let gap = lastHadPicture ? Self.pictureGap : Self.textGap
        return max(0, gap - now.timeIntervalSince(lastEnd))
    }

    /// A send ended at `end` (whatever its outcome: a failed send still used the link).
    mutating func sent(endingAt end: Date, hadPicture: Bool) {
        lastEnd = end
        lastHadPicture = hadPicture
    }

    /// Forget the last send: the transport was rebuilt, or the lens was handed back.
    mutating func reset() {
        lastEnd = nil
        lastHadPicture = false
    }
}

/// Plan KX §2.4: the last send the render queue made, for the support report and the Developer
/// panel. Case names and a duration only, never what the frame said.
struct HUDSendRecord: Equatable {
    enum Kind: String { case text, screen, picture, clear }
    enum Outcome: String { case sent, failed, timedOut = "timed-out", retriedWithoutPicture = "retried-without-picture" }

    let kind: Kind
    let milliseconds: Int
    let outcome: Outcome

    var reportLine: String {
        "Last display send: \(kind.rawValue), \(milliseconds) ms, \(outcome.rawValue)"
    }
}

/// Plan KX §2.4: a send that has not come back within its deadline is a failed send. `send()`
/// returning is no proof the frame rendered (Display Recording blanks third-party content while
/// `send()` still succeeds), but a send that never returns is certainly not one; without a deadline
/// the queue's single in-flight slot would hold every later frame behind it.
enum HUDSendDeadline {
    /// The longest a single send may take.
    static let seconds: TimeInterval = 4

    /// Run `operation`, or throw `GlassesDisplayError.sendTimedOut` once `seconds` pass first. The
    /// operation is cancelled on timeout and its late result ignored. It runs unstructured so a
    /// send that ignores cancellation cannot hold the caller past the deadline.
    static func run(seconds: TimeInterval = HUDSendDeadline.seconds,
                    _ operation: @escaping @Sendable () async throws -> Void) async throws {
        let gate = OnceGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let work = Task {
                do {
                    try await operation()
                    gate.fire { continuation.resume() }
                } catch {
                    gate.fire { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                gate.fire {
                    work.cancel()
                    continuation.resume(throwing: GlassesDisplayError.sendTimedOut)
                }
            }
        }
    }

    /// Lets exactly one of the two racing tasks resume the continuation.
    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func fire(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !fired else { return }
            fired = true
            body()
        }
    }
}
