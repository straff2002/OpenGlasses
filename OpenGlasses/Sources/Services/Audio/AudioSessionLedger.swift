import Foundation

/// A subsystem that can hold the shared `AVAudioSession`.
///
/// The app has several mic/audio subsystems that each activate the one shared session; the
/// coordinator built on this ledger arbitrates them so only one is the recognised owner at a time.
/// (Adoption is incremental — the realtime managers route through the coordinator first; the
/// always-on wake-word path and the gentler coexisting services follow.)
enum AudioSessionOwner: String, Sendable, CaseIterable {
    case wakeWord
    case transcription
    case liveTranslation
    case geminiLive
    case openAIRealtime
    case expertCall
    case textToSpeech
    /// Temple-tap media trigger's silent Now Playing claim (Plan CH) — only ever a coexisting
    /// rider under the wake-word listener's session, never an exclusive holder.
    case mediaTrigger
    /// The standalone capture tap (Plan CZ) — mic for a stream or recording while the always-on
    /// listener is off. Same category and options as the listener, so a handover between the two
    /// leaves the route alone.
    case captureAudio
}

/// A claim on the shared session: who holds it, an opaque token identifying this exact claim, and a
/// monotonically increasing generation so a later claim always sorts after an earlier one.
struct AudioSessionLease: Equatable, Sendable {
    let owner: AudioSessionOwner
    let token: UUID
    let generation: UInt64
}

/// What the holder of a lease should do when it releases.
enum AudioSessionReleaseDecision: Equatable {
    /// This lease is still the active one — actually deactivate the shared session.
    case deactivate
    /// A different owner has since acquired the session — do nothing (a stale release must not
    /// tear the session out from under whoever holds it now). Carries the current owner.
    case superseded(by: AudioSessionOwner)
    /// Nobody holds the session — nothing to deactivate.
    case alreadyReleased
}

/// The deterministic "single owner" guarantee for the shared `AVAudioSession`, as a pure value type.
///
/// Last-acquire-wins: acquiring supersedes any prior holder and bumps the generation. The crucial
/// invariant is on **release** — a lease only deactivates the session if it is *still the current
/// lease*. That is what stops a preempted owner's late, asynchronous teardown (an interruption
/// reset, a delayed `stopCapture`) from deactivating the session a newer owner just acquired — the
/// exact race that leaves the shared session dead mid-conversation when subsystems each manage it
/// independently.
///
/// Pure and single-threaded by construction; the live `AudioSessionCoordinator` wraps it behind a
/// serial queue and performs the actual activation/deactivation.
struct AudioSessionLedger {
    /// The lease currently recognised as owning the session, or `nil` when it's free.
    private(set) var current: AudioSessionLease?
    private var generation: UInt64 = 0

    /// Non-exclusive coexisting holds (live translation listening, TTS output) keyed by an opaque
    /// token. These run *under* the current exclusive owner — they never preempt it, and ending one
    /// never deactivates the session. Pure bookkeeping so `audioActivity` is a complete picture of
    /// who's using audio; it deliberately does not change the exclusive owner's activation.
    private(set) var coexisting: [UUID: AudioSessionOwner] = [:]

    init() {}

    /// Make `owner` the current holder, superseding any previous lease.
    /// - Parameter token: an opaque identity for this claim (the coordinator passes a fresh `UUID`;
    ///   tests pass a fixed one).
    /// - Returns: the new lease, and the lease it preempted (`nil` if the session was free).
    @discardableResult
    mutating func acquire(_ owner: AudioSessionOwner, token: UUID) -> (lease: AudioSessionLease, preempted: AudioSessionLease?) {
        let preempted = current
        generation &+= 1
        let lease = AudioSessionLease(owner: owner, token: token, generation: generation)
        current = lease
        return (lease, preempted)
    }

    /// Decide what releasing `lease` should do, clearing ownership only if `lease` is still current.
    mutating func release(_ lease: AudioSessionLease) -> AudioSessionReleaseDecision {
        guard let active = current else { return .alreadyReleased }
        if active == lease {
            current = nil
            return .deactivate
        }
        return .superseded(by: active.owner)
    }

    /// Register a non-exclusive coexisting hold (does not touch the exclusive owner).
    mutating func beginCoexisting(_ owner: AudioSessionOwner, token: UUID) {
        coexisting[token] = owner
    }

    /// End a coexisting hold. No effect on the exclusive owner — never deactivates.
    mutating func endCoexisting(token: UUID) {
        coexisting[token] = nil
    }

    /// The owners of the currently active coexisting holds, deduplicated and ordered.
    var coexistingOwners: [AudioSessionOwner] {
        var seen = Set<AudioSessionOwner>()
        return AudioSessionOwner.allCases.filter { owner in
            coexisting.values.contains(owner) && seen.insert(owner).inserted
        }
    }
}
