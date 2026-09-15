import Foundation

/// Serialises the device-side transitions that create or destroy the glasses camera capability, so
/// that two of them can never overlap.
///
/// # Why a lock and not a flag
///
/// The camera capability is **process-wide**, and the SDK frees it only once the `Camera` finishes
/// stopping: re-adding one before then throws `capabilityAlreadyActive`. The backend has four
/// callers that create or destroy it — a start's warm-up, a photo capture's session acquisition,
/// the stall-recovery ladder and the reconnect ladder — and they were kept apart by booleans
/// (`isWarmingUp`, `isRecoveringFromStall`, `isCaptureInProgress`). A boolean can only *refuse*;
/// it cannot make the second caller wait, so the choice was between racing for the capability and
/// dropping the work. Both were observable: a capture that landed mid-stream skipped, a reconnect
/// that found the flag set gave its rung away.
///
/// # Shape
///
/// FIFO, main-actor, non-reentrant, and deliberately tiny. Acquire order is preserved so a queued
/// transition cannot be starved by a later one.
///
/// **Non-reentrant is a rule, not an accident**: a locked region must never call another locked
/// region, or it waits for itself forever. Only the three leaf transitions take it — building the
/// session and camera, tearing down the camera, and resetting the session — and none of those
/// calls another. Everything above them composes those three.
///
/// **A stop never takes the lock.** Stopping is not a transition that can be made to wait: it has
/// to land the moment it is issued, which is what `StreamStartGeneration` then makes stick by
/// invalidating whatever the locked region was in the middle of.
@MainActor
final class CameraTransitionLock {

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many callers are queued behind the holder. Test-visible: "the second transition waited
    /// rather than racing" is otherwise only observable as the absence of a crash on hardware.
    var waitingCount: Int { waiters.count }

    /// Whether a transition is in progress. Part of the "nothing is left running after a stop"
    /// accounting.
    var isBusy: Bool { isHeld }

    init() {}

    /// Run `body` with no other camera transition in flight.
    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // Handed the lock directly by `release()`; `isHeld` was never cleared, so no other caller
        // can slip in between the two.
    }

    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
