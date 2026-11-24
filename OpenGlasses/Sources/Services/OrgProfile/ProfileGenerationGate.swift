import Foundation

/// Plan ND — whether a verified copy of the profile in force is newer than the one applied.
///
/// A signature says who wrote a copy, not when: before ND a renewal accepted any verified copy of
/// the same `profileId`, so a stale edge cache, or a copy replayed on purpose, renewed the lease and
/// put back settings (or a phone missing from `revokedEnrolmentIds`) that a newer copy had changed.
/// The signer now raises `profileGeneration` with every re-sign, and the phone keeps the highest it
/// has applied.
enum ProfileGenerationGate {

    enum Verdict: Equatable, Sendable {
        /// Neither the phone nor the copy knows a generation: a profile from before ND. It applies as
        /// a renewal always did.
        case unversioned
        /// A higher generation than any applied here: the company changed something.
        case newer
        /// The generation already applied: a renewal with nothing new in it.
        case same
        /// Lower than one already applied, or no generation after one was seen. Nothing in it is
        /// used — not its settings and not its lease.
        case stale
    }

    static func judge(incoming: Int?, highWater: Int?) -> Verdict {
        switch (incoming, highWater) {
        case (nil, nil): return .unversioned
        case (.some, nil): return .newer
        case (nil, .some): return .stale
        case let (.some(new), .some(applied)):
            if new > applied { return .newer }
            return new == applied ? .same : .stale
        }
    }

    /// The high-water mark after applying a copy: never lowered.
    static func raised(_ highWater: Int?, by incoming: Int?) -> Int? {
        guard let incoming else { return highWater }
        return max(highWater ?? incoming, incoming)
    }
}
